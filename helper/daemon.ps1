#requires -Version 5.1
<#
.SYNOPSIS
  Long-lived background worker that speaks newline-delimited JSON over stdin/stdout
  to the Node MCP server, and does the actual Windows Terminal UI Automation work.

.DESCRIPTION
  Protocol (one JSON object per line, both directions):
    Request:  {"id": 1, "action": "open_session", "params": {...}}
    Response: {"id": 1, "ok": true,  "result": {...}}
           or {"id": 1, "ok": false, "error": "human readable message"}

  Nothing except protocol response lines is ever written to stdout. Diagnostics
  go to stderr so they show up in the Node server's logs without corrupting the
  protocol stream.

  This process is started once by the Node server and stays alive for the whole
  MCP server lifetime, which lets it keep re-resolving UIA elements cheaply
  instead of paying PowerShell's ~200-500ms cold-start cost on every tool call.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ModulePath
)
if (-not $ModulePath) { $ModulePath = Join-Path $PSScriptRoot 'WtControl.psm1' }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Write-Stderr {
    param([string]$Message)
    [Console]::Error.WriteLine("[wt-daemon] $Message")
}

function Write-JsonResponse {
    param($Id, [bool]$Ok, $Result = $null, [string]$ErrorMessage = $null)
    $payload = [ordered]@{ id = $Id; ok = $Ok }
    if ($Ok) { $payload.result = $Result } else { $payload.error = $ErrorMessage }
    $json = $payload | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

try {
    Import-Module $ModulePath -Force -WarningAction SilentlyContinue
    Initialize-WtControl
} catch {
    # Report the failure as a single framed line the Node side can parse even
    # though we never received a request, then exit non-zero.
    Write-JsonResponse -Id 'startup' -Ok $false -ErrorMessage "Daemon failed to initialize: $($_.Exception.Message)"
    exit 1
}

# name -> @{ marker; shell; cwd; hwnd; createdAt }
$script:Sessions = @{}

function Invoke-Action {
    param([string]$Action, $Params)

    switch ($Action) {
        'ping' {
            return [pscustomobject]@{
                pong          = $true
                psVersion     = $PSVersionTable.PSVersion.ToString()
                wtFound       = [bool](Get-Command wt.exe -ErrorAction SilentlyContinue)
                sessionCount  = $script:Sessions.Count
            }
        }

        'check_exe' {
            $exe = [string]$Params.exe
            $cmd = Get-Command $exe -ErrorAction SilentlyContinue
            return [pscustomobject]@{ exe = $exe; found = [bool]$cmd }
        }

        'list_sessions' {
            $out = @()
            foreach ($name in $script:Sessions.Keys) {
                $s = $script:Sessions[$name]
                $alive = Test-WtSessionAlive -Marker $s.marker -ExpectedRuntimeId $s.runtimeId
                $out += [pscustomobject]@{
                    name      = $name
                    shell     = $s.shell
                    cwd       = $s.cwd
                    createdAt = $s.createdAt
                    alive     = $alive
                }
            }
            return , $out
        }

        'open_session' {
            $name = [string]$Params.name
            if ($script:Sessions.ContainsKey($name)) {
                if (Test-WtSessionAlive -Marker $script:Sessions[$name].marker) {
                    throw "A session named '$name' is already open. Close it first, or pick a different name."
                } else {
                    $script:Sessions.Remove($name) | Out-Null
                }
            }
            $newWindow = [bool]$Params.newWindow
            $timeoutMs = if ($Params.PSObject.Properties['timeoutMs']) { [int]$Params.timeoutMs } else { 6000 }
            $cwdValue = if ($Params.PSObject.Properties['cwd']) { $Params.cwd } else { $null }
            $shellArgs = @()
            if ($Params.shellArgs) { $shellArgs = @($Params.shellArgs) }

            $info = Open-WtSession -Name $name -ShellExe $Params.shellExe -ShellArgs $shellArgs `
                -Cwd $cwdValue -NewWindow $newWindow -TimeoutMs $timeoutMs

            $script:Sessions[$name] = @{
                marker    = $info.marker
                shell     = $info.shell
                cwd       = $info.cwd
                hwnd      = $info.hwnd
                runtimeId = $info.runtimeId
                createdAt = $info.createdAt
            }
            return $info
        }

        'write_to_terminal' {
            $s = Get-RequiredSession -Params $Params
            $pressEnter = if ($null -ne $Params.pressEnter) { [bool]$Params.pressEnter } else { $true }
            Write-WtSessionInput -Marker $s.marker -Text ([string]$Params.text) -PressEnter $pressEnter -ExpectedRuntimeId $s.runtimeId
            return [pscustomobject]@{ sent = $true }
        }

        'read_terminal_output' {
            $s = Get-RequiredSession -Params $Params
            $lines = if ($Params.lines) { [int]$Params.lines } else { 0 }
            $text = Read-WtSessionOutput -Marker $s.marker -Lines $lines -ExpectedRuntimeId $s.runtimeId
            return [pscustomobject]@{ text = $text }
        }

        'send_control_character' {
            $s = Get-RequiredSession -Params $Params
            Send-WtSessionControlChar -Marker $s.marker -Key ([string]$Params.key) -ExpectedRuntimeId $s.runtimeId
            return [pscustomobject]@{ sent = $true }
        }

        'close_session' {
            $name = [string]$Params.name
            if (-not $script:Sessions.ContainsKey($name)) {
                throw "No open session named '$name'."
            }
            $s = $script:Sessions[$name]
            try { Close-WtSession -Marker $s.marker -ExpectedRuntimeId $s.runtimeId } catch { Write-Stderr "close_session: $($_.Exception.Message)" }
            $script:Sessions.Remove($name) | Out-Null
            return [pscustomobject]@{ closed = $true }
        }

        'debug_inspect_windows' {
            return Get-WtDebugSnapshot
        }

        default {
            throw "Unknown action '$Action'."
        }
    }
}

function Get-RequiredSession {
    param($Params)
    $name = [string]$Params.name
    if (-not $script:Sessions.ContainsKey($name)) {
        $known = ($script:Sessions.Keys -join ', ')
        throw "No open session named '$name'. Open sessions: $(if ($known) { $known } else { '(none)' })."
    }
    return $script:Sessions[$name]
}

Write-Stderr "ready"

$stdin = [Console]::In
while ($true) {
    $line = $stdin.ReadLine()
    if ($null -eq $line) { break }
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    $id = $null
    try {
        $req = $line | ConvertFrom-Json -ErrorAction Stop
        $id = $req.id
        $result = Invoke-Action -Action $req.action -Params $req.params
        Write-JsonResponse -Id $id -Ok $true -Result $result
    } catch {
        Write-JsonResponse -Id $id -Ok $false -ErrorMessage $_.Exception.Message
    }
}

Write-Stderr "stdin closed, exiting"
