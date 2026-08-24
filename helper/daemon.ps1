#requires -Version 5.1
<#
.SYNOPSIS
  Long-lived background worker that speaks newline-delimited JSON over stdin/stdout
  to the Node MCP server, and does the actual ConPTY (Windows pseudo console) work.

.DESCRIPTION
  Protocol (one JSON object per line, both directions):
    Request:  {"id": 1, "action": "open_session", "params": {...}}
    Response: {"id": 1, "ok": true,  "result": {...}}
           or {"id": 1, "ok": false, "error": "human readable message"}

  Nothing except protocol response lines is ever written to stdout. Diagnostics
  go to stderr so they show up in the Node server's logs without corrupting the
  protocol stream.

  This process is started once by the Node server and stays alive for the whole
  MCP server lifetime. Each session is a real child shell process attached to its
  own ConPTY, held alive in $script:Sessions for the lifetime of the daemon.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ModulePath
)
if (-not $ModulePath) { $ModulePath = Join-Path $PSScriptRoot 'PtySession.psm1' }

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
    Initialize-PtyControl
} catch {
    # Report the failure as a single framed line the Node side can parse even
    # though we never received a request, then exit non-zero.
    Write-JsonResponse -Id 'startup' -Ok $false -ErrorMessage "Daemon failed to initialize: $($_.Exception.Message)"
    exit 1
}

# name -> @{ shell; cwd; pid; createdAt; Session (live WinTermMcp.Pty.PtySession object) }
$script:Sessions = @{}

function Invoke-Action {
    param([string]$Action, $Params)

    switch ($Action) {
        'ping' {
            return [pscustomobject]@{
                pong          = $true
                psVersion     = $PSVersionTable.PSVersion.ToString()
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
                $out += [pscustomobject]@{
                    name      = $name
                    shell     = $s.shell
                    cwd       = $s.cwd
                    createdAt = $s.createdAt
                    alive     = (Test-PtySessionAlive -SessionState $s)
                }
            }
            return , $out
        }

        'open_session' {
            $name = [string]$Params.name
            if ($script:Sessions.ContainsKey($name)) {
                if (Test-PtySessionAlive -SessionState $script:Sessions[$name]) {
                    throw "A session named '$name' is already open. Close it first, or pick a different name."
                } else {
                    $script:Sessions.Remove($name) | Out-Null
                }
            }
            $cwdValue = if ($Params.PSObject.Properties['cwd']) { $Params.cwd } else { $null }
            $shellArgs = @()
            if ($Params.PSObject.Properties['shellArgs'] -and $Params.shellArgs) { $shellArgs = @($Params.shellArgs) }

            $info = New-PtySession -Name $name -ShellExe $Params.shellExe -ShellArgs $shellArgs -Cwd $cwdValue
            $script:Sessions[$name] = $info
            return [pscustomobject]@{
                name      = $info.name
                shell     = $info.shell
                cwd       = $info.cwd
                pid       = $info.pid
                createdAt = $info.createdAt
            }
        }

        'write_to_terminal' {
            $s = Get-RequiredSession -Params $Params
            $pressEnter = if ($Params.PSObject.Properties['pressEnter'] -and $null -ne $Params.pressEnter) { [bool]$Params.pressEnter } else { $true }
            Write-PtySessionInput -SessionState $s -Text ([string]$Params.text) -PressEnter $pressEnter
            return [pscustomobject]@{ sent = $true }
        }

        'read_terminal_output' {
            $s = Get-RequiredSession -Params $Params
            $lines = if ($Params.PSObject.Properties['lines'] -and $Params.lines) { [int]$Params.lines } else { 0 }
            $text = Read-PtySessionOutput -SessionState $s -Lines $lines
            return [pscustomobject]@{ text = $text }
        }

        'send_control_character' {
            $s = Get-RequiredSession -Params $Params
            Send-PtySessionControlChar -SessionState $s -Key ([string]$Params.key)
            return [pscustomobject]@{ sent = $true }
        }

        'close_session' {
            $name = [string]$Params.name
            if (-not $script:Sessions.ContainsKey($name)) {
                throw "No open session named '$name'."
            }
            $s = $script:Sessions[$name]
            try { Close-PtySession -SessionState $s } catch { Write-Stderr "close_session: $($_.Exception.Message)" }
            $script:Sessions.Remove($name) | Out-Null
            return [pscustomobject]@{ closed = $true }
        }

        'debug_inspect_sessions' {
            $out = @()
            foreach ($name in $script:Sessions.Keys) {
                $s = $script:Sessions[$name]
                $out += [pscustomobject]@{
                    name           = $name
                    shell          = $s.shell
                    cwd            = $s.cwd
                    pid            = $s.pid
                    createdAt      = $s.createdAt
                    alive          = (Test-PtySessionAlive -SessionState $s)
                    bufferedChars  = ($s.Session.ReadOutput()).Length
                }
            }
            return [pscustomobject]@{ sessionCount = $script:Sessions.Count; sessions = $out }
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
