#requires -Version 5.1
<#
.SYNOPSIS
  Core automation logic for driving the real Windows Terminal application (wt.exe)
  via UI Automation (UIA) and simulated keyboard input.

.DESCRIPTION
  This module never touches any code from the winterm-mcp project it was inspired by.
  It is a clean-room implementation: it opens real wt.exe tabs, finds them again with
  UI Automation, reads what is on screen through the accessibility Text Pattern, and
  sends keystrokes exactly like a human at the keyboard would - including Ctrl+<key>,
  which lands only on the pane that is focused when it is sent (never a machine-wide
  "kill everything named X" like the reference project's Ctrl+C did).

  Every session is a single wt.exe tab, tagged at creation time with a unique,
  invisible-to-the-user marker title (e.g. "MCP::build::a1b2c3d4") so it can be found
  again on later calls. We re-resolve the tab/window/content element fresh on every
  operation rather than caching AutomationElement references, because Windows Terminal
  can recreate parts of its UI tree when tabs are switched, and stale COM references
  throw ElementNotAvailableException.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# One-time initialization: load the Windows Desktop assemblies we need and
# define the small set of Win32 calls that UIA does not cover (SendKeys only
# reaches whatever window currently has OS input focus, so we still need
# SetForegroundWindow + keybd_event for control-character chords).
# ---------------------------------------------------------------------------
function Initialize-WtControl {
    [CmdletBinding()]
    param()

    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not ('WinTermMcp.Win32' -as [type])) {
        Add-Type -Namespace WinTermMcp -Name Win32 -MemberDefinition @'
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll")]
public static extern bool IsIconic(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern bool IsWindow(IntPtr hWnd);

[DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@
    }

    if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
        throw "wt.exe (Windows Terminal) was not found on PATH. Install/update it from the Microsoft Store, or add it to PATH, then retry."
    }
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$script:WT_WINDOW_CLASS = 'CASCADIA_HOSTING_WINDOW_CLASS'
$script:SW_RESTORE = 9
$script:KEYEVENTF_KEYUP = 0x0002
$script:VK_CONTROL = 0x11
$script:VK_SHIFT = 0x10
$script:VK_CANCEL = 0x03  # OS-level "Ctrl+Break" signal

function Format-ArgumentForCommandLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Arg)
    if ($Arg.Length -gt 0 -and $Arg -notmatch '[\s"]') { return $Arg }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    for ($i = 0; $i -lt $Arg.Length; $i++) {
        $backslashCount = 0
        while ($i -lt $Arg.Length -and $Arg[$i] -eq '\') { $backslashCount++; $i++ }
        if ($i -eq $Arg.Length) {
            [void]$sb.Append('\' * ($backslashCount * 2))
        } elseif ($Arg[$i] -eq '"') {
            [void]$sb.Append('\' * ($backslashCount * 2 + 1))
            [void]$sb.Append('"')
        } else {
            [void]$sb.Append('\' * $backslashCount)
            [void]$sb.Append($Arg[$i])
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Protect-WtLiteralSemicolon {
    # A standalone ";" argument tells wt.exe's own command-line parser "end this
    # subcommand, start a new one" (see Format-ArgumentForCommandLine above for
    # the general Windows argv-quoting problem this is different from: a value
    # that is just ";" has no space/quote, so normal quoting leaves it untouched
    # and it still reaches wt.exe as that exact reserved token). Per Microsoft's
    # docs, a literal ";" must be escaped as "\;" so wt.exe treats it as content,
    # not a separator.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Arg)
    return $Arg -replace ';', '\;'
}

function New-SessionMarker {
    param([Parameter(Mandatory)][string]$Name)
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "MCP::${Name}::${suffix}"
}

# ---------------------------------------------------------------------------
# UIA discovery helpers
# ---------------------------------------------------------------------------
function Get-WtWindowElements {
    [OutputType([System.Windows.Automation.AutomationElement[]])]
    param()
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ClassNameProperty, $script:WT_WINDOW_CLASS)
    $root = [System.Windows.Automation.AutomationElement]::RootElement
    $found = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($w in $found) { $list.Add($w) }
    return , $list.ToArray()
}

function Find-WtTabByMarker {
    # ExpectedRuntimeId is the UIA RuntimeId captured for this session's tab when
    # it was created (Open-WtSession). A tab title is just visible text - any
    # other tab on the machine can be renamed to the same marker string (e.g. via
    # an OSC-2 escape sequence from its own shell). Normally there is exactly one
    # tab with a given marker, since the marker's suffix is a fresh random GUID,
    # so that single match is returned with no further check. If more than one
    # tab currently shares the title, that is abnormal - only the one whose
    # RuntimeId matches what we recorded at creation is trusted; RuntimeId is
    # assigned by the UIA provider, not user-controllable content, so it cannot
    # be spoofed by renaming a different tab.
    param(
        [Parameter(Mandatory)][string]$Marker,
        [int[]]$ExpectedRuntimeId
    )

    $tabCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem)

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($windowEl in (Get-WtWindowElements)) {
        try {
            $tabs = $windowEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)
        } catch {
            continue
        }
        foreach ($tab in $tabs) {
            try {
                if ($tab.Current.Name -eq $Marker) {
                    $candidates.Add([pscustomobject]@{ Window = $windowEl; Tab = $tab })
                }
            } catch { continue }
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    if ($ExpectedRuntimeId) {
        foreach ($c in $candidates) {
            try {
                if ([System.Windows.Automation.Automation]::Compare($c.Tab.GetRuntimeId(), $ExpectedRuntimeId)) {
                    return $c
                }
            } catch { continue }
        }
    }
    throw "Found $($candidates.Count) Windows Terminal tabs titled '$Marker', and none of them matched this session's original tab identity. Another tab may have been renamed to spoof this session; refusing to guess which one is real."
}

function Select-WtTab {
    param([Parameter(Mandatory)]$TabElement)
    $pattern = $null
    if ($TabElement.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
        $pattern.Select()
    } else {
        # Fallback: click-equivalent via Invoke, if the tab exposes it.
        $invoke = $null
        if ($TabElement.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) {
            $invoke.Invoke()
        }
    }
}

function Find-TerminalContentElement {
    param([Parameter(Mandatory)]$WindowElement)

    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty, $true)
    $candidates = $WindowElement.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)

    $best = $null
    $bestArea = -1
    foreach ($c in $candidates) {
        try {
            $r = $c.Current.BoundingRectangle
            if ($r.IsEmpty) { continue }
            $area = $r.Width * $r.Height
            if ($area -gt $bestArea) {
                $bestArea = $area
                $best = $c
            }
        } catch { continue }
    }
    return $best
}

function Bring-WtWindowToForeground {
    param([Parameter(Mandatory)]$WindowElement, [int]$SettleMs = 150)

    $hwnd = [IntPtr]$WindowElement.Current.NativeWindowHandle
    if ($hwnd -eq [IntPtr]::Zero) { throw "Could not resolve a native window handle for this session's Windows Terminal window." }
    if ([WinTermMcp.Win32]::IsIconic($hwnd)) {
        [WinTermMcp.Win32]::ShowWindow($hwnd, $script:SW_RESTORE) | Out-Null
    }
    $ok = [WinTermMcp.Win32]::SetForegroundWindow($hwnd)
    if (-not $ok) {
        throw "Windows refused to give this session's Windows Terminal window keyboard focus (SetForegroundWindow returned false). Refusing to send keystrokes, since they could land on whatever window the user actually has focused."
    }
    Start-Sleep -Milliseconds $SettleMs
    $actual = [WinTermMcp.Win32]::GetForegroundWindow()
    if ($actual -ne $hwnd) {
        throw "This session's Windows Terminal window did not actually end up focused (expected handle $hwnd, got $actual). Refusing to send keystrokes, since they could land on whatever window the user actually has focused."
    }
    return $hwnd
}

# ---------------------------------------------------------------------------
# Session lifecycle
# ---------------------------------------------------------------------------
function Open-WtSession {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ShellExe,
        [string[]]$ShellArgs = @(),
        [string]$Cwd,
        [bool]$NewWindow = $false,
        [int]$TimeoutMs = 6000
    )

    $marker = New-SessionMarker -Name $Name

    $wtArgs = New-Object System.Collections.Generic.List[string]
    $wtArgs.Add('-w'); $wtArgs.Add($(if ($NewWindow) { 'new' } else { '0' }))
    $wtArgs.Add('new-tab')
    $wtArgs.Add('--title'); $wtArgs.Add($marker)
    if ($Cwd) { $wtArgs.Add('--startingDirectory'); $wtArgs.Add((Protect-WtLiteralSemicolon $Cwd)) }
    $wtArgs.Add('--')
    $wtArgs.Add($ShellExe)
    foreach ($a in $ShellArgs) { $wtArgs.Add($a) }

    $cmdLine = ($wtArgs | ForEach-Object { Format-ArgumentForCommandLine $_ }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wt.exe'
    $psi.Arguments = $cmdLine
    $psi.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null

    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    $found = $null
    while ((Get-Date) -lt $deadline) {
        $found = Find-WtTabByMarker -Marker $marker
        if ($found) { break }
        Start-Sleep -Milliseconds 150
    }
    if (-not $found) {
        throw "Timed out after ${TimeoutMs}ms waiting for Windows Terminal to open a tab titled '$marker'. Is wt.exe actually launching? Try running 'wt.exe' by hand once to accept any first-run prompts, then retry."
    }

    Select-WtTab -TabElement $found.Tab
    Start-Sleep -Milliseconds 200
    $hwnd = $found.Window.Current.NativeWindowHandle
    $runtimeId = $found.Tab.GetRuntimeId()

    return [pscustomobject]@{
        name      = $Name
        marker    = $marker
        shell     = $ShellExe
        cwd       = $Cwd
        hwnd      = [int64]$hwnd
        runtimeId = $runtimeId
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
    }
}

function Resolve-WtSession {
    # Re-finds a session's tab/window fresh. Throws a descriptive error if the
    # user closed the tab/window manually since it was opened.
    param([Parameter(Mandatory)][string]$Marker, [int[]]$ExpectedRuntimeId)

    $found = Find-WtTabByMarker -Marker $Marker -ExpectedRuntimeId $ExpectedRuntimeId
    if (-not $found) {
        throw "This session's Windows Terminal tab could not be found anymore. It was probably closed by hand (or Windows Terminal was restarted). Close/reopen the session from the MCP side to get a fresh one."
    }
    return $found
}

function Focus-WtSession {
    param([Parameter(Mandatory)][string]$Marker, [int]$SettleMs = 150, [int[]]$ExpectedRuntimeId)
    $found = Resolve-WtSession -Marker $Marker -ExpectedRuntimeId $ExpectedRuntimeId
    Select-WtTab -TabElement $found.Tab
    Bring-WtWindowToForeground -WindowElement $found.Window -SettleMs $SettleMs | Out-Null
    $content = Find-TerminalContentElement -WindowElement $found.Window
    if (-not $content) {
        throw "Found the Windows Terminal tab but could not locate its text/content control via UI Automation. Windows Terminal's accessibility tree may have changed - try the debug_inspect_windows tool to see what UIA can see on this machine."
    }
    try { $content.SetFocus() } catch { }
    return [pscustomobject]@{ Window = $found.Window; Tab = $found.Tab; Content = $content }
}

function ConvertTo-SendKeysLiteral {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '{' { [void]$sb.Append('{{}'); continue }
            '}' { [void]$sb.Append('{}}'); continue }
            '+' { [void]$sb.Append('{+}'); continue }
            '^' { [void]$sb.Append('{^}'); continue }
            '%' { [void]$sb.Append('{%}'); continue }
            '~' { [void]$sb.Append('{~}'); continue }
            '(' { [void]$sb.Append('{(}'); continue }
            ')' { [void]$sb.Append('{)}'); continue }
            '[' { [void]$sb.Append('{[}'); continue }
            ']' { [void]$sb.Append('{]}'); continue }
            default { [void]$sb.Append($ch) }
        }
    }
    return $sb.ToString()
}

function Write-WtSessionInput {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$PressEnter = $true,
        [int]$SettleMs = 150,
        [int[]]$ExpectedRuntimeId
    )
    Focus-WtSession -Marker $Marker -SettleMs $SettleMs -ExpectedRuntimeId $ExpectedRuntimeId | Out-Null
    $escaped = ConvertTo-SendKeysLiteral -Text $Text
    [System.Windows.Forms.SendKeys]::SendWait($escaped)
    if ($PressEnter) {
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    }
}

function Read-WtSessionOutput {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [int]$Lines = 0,  # 0 = all visible text
        [int[]]$ExpectedRuntimeId
    )
    $found = Resolve-WtSession -Marker $Marker -ExpectedRuntimeId $ExpectedRuntimeId
    $content = Find-TerminalContentElement -WindowElement $found.Window
    if (-not $content) {
        throw "Located the session's tab but not its content element (see debug_inspect_windows)."
    }
    $textPattern = $null
    if (-not $content.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern, [ref]$textPattern)) {
        throw "The terminal content element does not support the Text control pattern on this system."
    }
    $full = $textPattern.DocumentRange.GetText(-1)
    $normalized = $full -replace "`r`n", "`n" -replace "`r", "`n"
    if ($Lines -gt 0) {
        $allLines = $normalized -split "`n"
        $take = [Math]::Min($Lines, $allLines.Length)
        $normalized = ($allLines[($allLines.Length - $take)..($allLines.Length - 1)]) -join "`n"
    }
    return $normalized
}

function Send-WtSessionControlChar {
    param(
        [Parameter(Mandatory)][string]$Marker,
        [Parameter(Mandatory)][string]$Key,
        [int]$SettleMs = 150,
        [int[]]$ExpectedRuntimeId
    )
    Focus-WtSession -Marker $Marker -SettleMs $SettleMs -ExpectedRuntimeId $ExpectedRuntimeId | Out-Null

    $upper = $Key.ToUpperInvariant()
    if ($upper -eq 'BREAK' -or $upper -eq 'PAUSE') {
        [WinTermMcp.Win32]::keybd_event([byte]$script:VK_CANCEL, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 30
        [WinTermMcp.Win32]::keybd_event([byte]$script:VK_CANCEL, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
        return
    }

    if ($upper.Length -ne 1 -or $upper -notmatch '[A-Z0-9]') {
        throw "Unsupported control key '$Key'. Use a single letter/digit (e.g. 'C' for Ctrl+C) or 'BREAK'."
    }
    $vk = [byte][char]$upper

    [WinTermMcp.Win32]::keybd_event([byte]$script:VK_CONTROL, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [WinTermMcp.Win32]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [WinTermMcp.Win32]::keybd_event($vk, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [WinTermMcp.Win32]::keybd_event([byte]$script:VK_CONTROL, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Close-WtSession {
    param([Parameter(Mandatory)][string]$Marker, [int]$SettleMs = 150, [int[]]$ExpectedRuntimeId)
    Focus-WtSession -Marker $Marker -SettleMs $SettleMs -ExpectedRuntimeId $ExpectedRuntimeId | Out-Null

    # Windows Terminal's default keybinding for "close pane" is Ctrl+Shift+W.
    # This closes only the active pane/tab; if it is the last one, the window closes too.
    [WinTermMcp.Win32]::keybd_event([byte]$script:VK_CONTROL, 0, 0, [UIntPtr]::Zero)
    [WinTermMcp.Win32]::keybd_event([byte]$script:VK_SHIFT, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [WinTermMcp.Win32]::keybd_event([byte][char]'W', 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 20
    [WinTermMcp.Win32]::keybd_event([byte][char]'W', 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    [WinTermMcp.Win32]::keybd_event([byte]$script:VK_SHIFT, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
    [WinTermMcp.Win32]::keybd_event([byte]$script:VK_CONTROL, 0, $script:KEYEVENTF_KEYUP, [UIntPtr]::Zero)
}

function Test-WtSessionAlive {
    param([Parameter(Mandatory)][string]$Marker, [int[]]$ExpectedRuntimeId)
    try {
        $found = Find-WtTabByMarker -Marker $Marker -ExpectedRuntimeId $ExpectedRuntimeId
        return [bool]$found
    } catch {
        return $false
    }
}

function Get-WtDebugSnapshot {
    # Dumps everything UIA can currently see about Windows Terminal windows/tabs,
    # so a human can diagnose why a session lookup is failing on their machine.
    param()
    $windows = @()
    foreach ($w in (Get-WtWindowElements)) {
        $tabCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::TabItem)
        $tabs = @()
        try {
            foreach ($t in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $tabCond)) {
                $tabs += $t.Current.Name
            }
        } catch { }

        $textCond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::IsTextPatternAvailableProperty, $true)
        $textCandidates = @()
        try {
            foreach ($c in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)) {
                $r = $c.Current.BoundingRectangle
                $textCandidates += [pscustomobject]@{
                    name           = $c.Current.Name
                    controlType    = $c.Current.ControlType.ProgrammaticName
                    className      = $c.Current.ClassName
                    boundingWidth  = $r.Width
                    boundingHeight = $r.Height
                }
            }
        } catch { }

        $windows += [pscustomobject]@{
            hwnd            = [int64]$w.Current.NativeWindowHandle
            name            = $w.Current.Name
            tabTitles       = $tabs
            textCandidates  = $textCandidates
        }
    }
    return [pscustomobject]@{
        wtWindowCount = $windows.Count
        windows       = $windows
    }
}

Export-ModuleMember -Function *-*
