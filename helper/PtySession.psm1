#requires -Version 5.1
<#
.SYNOPSIS
  Core automation logic for driving a real, persistent shell process through
  the Windows Pseudo Console API (ConPTY).

.DESCRIPTION
  This module never touches any code from the winterm-mcp project it was inspired by.
  It is a clean-room implementation: it spawns a real shell (cmd.exe/pwsh.exe/powershell.exe)
  attached to a Windows pseudo console (ConPTY), writes bytes to its input pipe exactly
  like a terminal would, and reads its output pipe in the background into an in-memory
  buffer.

  The P/Invoke signatures and pseudo-console lifecycle (pipe creation, attribute list,
  CreateProcess with EXTENDED_STARTUPINFO_PRESENT) are ported from Microsoft's own
  official sample at https://github.com/microsoft/terminal/tree/main/samples/ConPTY/MiniTerm
  (see CLAUDE.md's Security policy: security-relevant code here is sourced only from
  official vendor documentation/samples, never from third-party or offensive-security tools).

  Each "session" is one real child process attached to its own ConPTY. Unlike the previous
  UI-Automation design, there is no window to re-find later - this module holds the live
  pipe/process handles for the lifetime of the session, inside the returned session object.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Fixed pseudo console size. This only affects how the shell wraps output and
# whether pagers/progress bars think they have room - there is no visible
# window to resize. 40 rows keeps most "does this need a pager" heuristics
# (e.g. git log) from deciding to invoke one.
$script:PTY_COLS = 120
$script:PTY_ROWS = 40

function Initialize-PtyControl {
    [CmdletBinding()]
    param()

    if (-not ('WinTermMcp.Pty.PtySession' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using N = WinTermMcp.Pty.Native;

namespace WinTermMcp.Pty
{
    internal static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct COORD
        {
            public short X;
            public short Y;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFO
        {
            public Int32 cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public Int32 dwX;
            public Int32 dwY;
            public Int32 dwXSize;
            public Int32 dwYSize;
            public Int32 dwXCountChars;
            public Int32 dwYCountChars;
            public Int32 dwFillAttribute;
            public Int32 dwFlags;
            public Int16 wShowWindow;
            public Int16 cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct STARTUPINFOEX
        {
            public STARTUPINFO StartupInfo;
            public IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public int dwProcessId;
            public int dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            public int bInheritHandle;
        }

        public const uint PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016;
        public const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        public const uint STILL_ACTIVE = 259;

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern int ClosePseudoConsole(IntPtr hPC);

        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        public static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool CreateProcess(string lpApplicationName, string lpCommandLine, ref SECURITY_ATTRIBUTES lpProcessAttributes, ref SECURITY_ATTRIBUTES lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, [In] ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DeleteProcThreadAttributeList(IntPtr lpAttributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool ReadFile(SafeFileHandle hFile, byte[] lpBuffer, uint nNumberOfBytesToRead, out uint lpNumberOfBytesRead, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool WriteFile(SafeFileHandle hFile, byte[] lpBuffer, uint nNumberOfBytesToWrite, out uint lpNumberOfBytesWritten, IntPtr lpOverlapped);
    }

    public sealed class PtySession : IDisposable
    {
        private SafeFileHandle _inputReadSide;
        private SafeFileHandle _inputWriteSide;
        private SafeFileHandle _outputReadSide;
        private SafeFileHandle _outputWriteSide;
        private IntPtr _pseudoConsoleHandle;
        private IntPtr _attributeListHandle;
        private N.PROCESS_INFORMATION _processInfo;
        private readonly List<byte> _outputBuffer = new List<byte>();
        private readonly object _bufferLock = new object();
        private Thread _readerThread;
        private volatile bool _closed;

        public int ProcessId { get { return _processInfo.dwProcessId; } }

        public static PtySession Start(string commandLine, string currentDirectory, short cols, short rows)
        {
            SafeFileHandle inputReadSide, inputWriteSide, outputReadSide, outputWriteSide;
            if (!N.CreatePipe(out inputReadSide, out inputWriteSide, IntPtr.Zero, 0))
                throw new InvalidOperationException("Could not create input pipe. Win32 error " + Marshal.GetLastWin32Error());
            if (!N.CreatePipe(out outputReadSide, out outputWriteSide, IntPtr.Zero, 0))
                throw new InvalidOperationException("Could not create output pipe. Win32 error " + Marshal.GetLastWin32Error());

            IntPtr hPC;
            int hr = N.CreatePseudoConsole(new N.COORD { X = cols, Y = rows }, inputReadSide, outputWriteSide, 0, out hPC);
            if (hr != 0)
                throw new InvalidOperationException("CreatePseudoConsole failed with HRESULT 0x" + hr.ToString("X8"));

            IntPtr lpSize = IntPtr.Zero;
            N.InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref lpSize);
            if (lpSize == IntPtr.Zero)
                throw new InvalidOperationException("Could not size the process attribute list. Win32 error " + Marshal.GetLastWin32Error());

            // STARTF_USESTDHANDLES (0x100) with the std handles left null. Without this, when the
            // calling process's own stdio is redirected/piped (true for a daemon with no real
            // console of its own), Windows duplicates those redirected handles into the child
            // regardless of PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, so the child's output leaks to
            // wherever the parent's redirected stdout points instead of this pseudo console.
            // Source: microsoft/terminal maintainer, https://github.com/microsoft/terminal/discussions/15814
            const int STARTF_USESTDHANDLES = 0x00000100;
            var startupInfo = new N.STARTUPINFOEX();
            startupInfo.StartupInfo.cb = Marshal.SizeOf(typeof(N.STARTUPINFOEX));
            startupInfo.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
            startupInfo.lpAttributeList = Marshal.AllocHGlobal(lpSize);

            if (!N.InitializeProcThreadAttributeList(startupInfo.lpAttributeList, 1, 0, ref lpSize))
            {
                Marshal.FreeHGlobal(startupInfo.lpAttributeList);
                throw new InvalidOperationException("InitializeProcThreadAttributeList failed. Win32 error " + Marshal.GetLastWin32Error());
            }

            if (!N.UpdateProcThreadAttribute(startupInfo.lpAttributeList, 0, (IntPtr)N.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, hPC, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
            {
                N.DeleteProcThreadAttributeList(startupInfo.lpAttributeList);
                Marshal.FreeHGlobal(startupInfo.lpAttributeList);
                throw new InvalidOperationException("UpdateProcThreadAttribute failed. Win32 error " + Marshal.GetLastWin32Error());
            }

            var pSec = new N.SECURITY_ATTRIBUTES();
            pSec.nLength = Marshal.SizeOf(typeof(N.SECURITY_ATTRIBUTES));
            var tSec = new N.SECURITY_ATTRIBUTES();
            tSec.nLength = Marshal.SizeOf(typeof(N.SECURITY_ATTRIBUTES));

            N.PROCESS_INFORMATION processInfo;
            bool created = N.CreateProcess(
                null, commandLine, ref pSec, ref tSec, false,
                N.EXTENDED_STARTUPINFO_PRESENT, IntPtr.Zero,
                string.IsNullOrEmpty(currentDirectory) ? null : currentDirectory,
                ref startupInfo, out processInfo);

            if (!created)
            {
                int err = Marshal.GetLastWin32Error();
                N.DeleteProcThreadAttributeList(startupInfo.lpAttributeList);
                Marshal.FreeHGlobal(startupInfo.lpAttributeList);
                N.ClosePseudoConsole(hPC);
                throw new InvalidOperationException("CreateProcess failed for '" + commandLine + "'. Win32 error " + err);
            }

            var session = new PtySession();
            session._inputReadSide = inputReadSide;
            session._inputWriteSide = inputWriteSide;
            session._outputReadSide = outputReadSide;
            session._outputWriteSide = outputWriteSide;
            session._pseudoConsoleHandle = hPC;
            session._attributeListHandle = startupInfo.lpAttributeList;
            session._processInfo = processInfo;
            session.StartReaderThread();
            return session;
        }

        private void StartReaderThread()
        {
            _readerThread = new Thread(ReaderLoop);
            _readerThread.IsBackground = true;
            _readerThread.Start();
        }

        private void ReaderLoop()
        {
            byte[] chunk = new byte[4096];
            while (!_closed)
            {
                uint bytesRead;
                bool ok = N.ReadFile(_outputReadSide, chunk, (uint)chunk.Length, out bytesRead, IntPtr.Zero);
                if (!ok || bytesRead == 0) break;
                lock (_bufferLock)
                {
                    for (int i = 0; i < bytesRead; i++) _outputBuffer.Add(chunk[i]);
                    // Cap the transcript so a long-lived session cannot grow this without bound.
                    const int maxBytes = 4 * 1024 * 1024;
                    if (_outputBuffer.Count > maxBytes)
                    {
                        _outputBuffer.RemoveRange(0, _outputBuffer.Count - maxBytes);
                    }
                }
            }
        }

        public void Write(string text)
        {
            if (_closed) throw new InvalidOperationException("This session's process has already been closed.");
            byte[] bytes = Encoding.UTF8.GetBytes(text);
            uint written;
            if (!N.WriteFile(_inputWriteSide, bytes, (uint)bytes.Length, out written, IntPtr.Zero))
                throw new InvalidOperationException("WriteFile to session input pipe failed. Win32 error " + Marshal.GetLastWin32Error());
        }

        public string ReadOutput()
        {
            lock (_bufferLock)
            {
                return Encoding.UTF8.GetString(_outputBuffer.ToArray());
            }
        }

        public bool IsAlive
        {
            get
            {
                if (_closed) return false;
                uint exitCode;
                if (!N.GetExitCodeProcess(_processInfo.hProcess, out exitCode)) return false;
                return exitCode == N.STILL_ACTIVE;
            }
        }

        public void Close()
        {
            if (_closed) return;
            _closed = true;
            try { N.TerminateProcess(_processInfo.hProcess, 0); } catch { }
            try { N.ClosePseudoConsole(_pseudoConsoleHandle); } catch { }
            try { _inputReadSide.Dispose(); } catch { }
            try { _inputWriteSide.Dispose(); } catch { }
            try { _outputReadSide.Dispose(); } catch { }
            try { _outputWriteSide.Dispose(); } catch { }
            try { N.DeleteProcThreadAttributeList(_attributeListHandle); Marshal.FreeHGlobal(_attributeListHandle); } catch { }
            try { N.CloseHandle(_processInfo.hThread); } catch { }
            try { N.CloseHandle(_processInfo.hProcess); } catch { }
        }

        public void Dispose() { Close(); }
    }
}
"@ -ErrorAction Stop
    }
}

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

function New-PtySession {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$ShellExe,
        [string[]]$ShellArgs = @(),
        [string]$Cwd
    )

    if ($Cwd) {
        $trimmed = $Cwd.Trim()
        # A UNC path here reaches CreateProcess's lpCurrentDirectory directly, which makes
        # this process attempt real SMB/NetBIOS negotiation against whatever host is named -
        # the same forced-authentication mechanism used to capture NetNTLM hashes for
        # relay/cracking. It also blocks synchronously for the OS network timeout (tens of
        # seconds against an unreachable host) since the daemon dispatches one request at a
        # time, freezing every other open session for that long. Reject it outright.
        if ($trimmed.StartsWith('\\') -or $trimmed.StartsWith('//')) {
            throw "cwd must be a local path, not a UNC/network path ('$Cwd'). Network paths risk forced authentication to an attacker-controlled host and can block this daemon for other sessions."
        }
        if (-not (Test-Path -LiteralPath $trimmed -PathType Container)) {
            throw "cwd '$Cwd' does not exist or is not a directory."
        }
    }

    $argv = New-Object System.Collections.Generic.List[string]
    $argv.Add($ShellExe)
    foreach ($a in $ShellArgs) { $argv.Add($a) }
    $commandLine = ($argv | ForEach-Object { Format-ArgumentForCommandLine $_ }) -join ' '

    $session = [WinTermMcp.Pty.PtySession]::Start($commandLine, $Cwd, [int16]$script:PTY_COLS, [int16]$script:PTY_ROWS)

    return [pscustomobject]@{
        name      = $Name
        shell     = $ShellExe
        cwd       = $Cwd
        pid       = $session.ProcessId
        createdAt = (Get-Date).ToUniversalTime().ToString('o')
        Session   = $session
    }
}

function Write-PtySessionInput {
    param(
        [Parameter(Mandatory)]$SessionState,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [bool]$PressEnter = $true
    )
    $payload = if ($PressEnter) { $Text + "`r`n" } else { $Text }
    $SessionState.Session.Write($payload)
}

function ConvertTo-PlainTerminalText {
    # Strips VT/ANSI escape sequences (CSI, OSC, single-char) and collapses
    # carriage-return-only line rewrites (progress bars, spinners) down to
    # their final state, so the result reads like a plain scrollback log
    # instead of a raw byte-for-byte terminal capture.
    # ponytail: not a full screen-buffer emulator (no cursor-position tracking,
    # so a full-screen TUI app's redraws won't render as a single clean frame).
    # upgrade to a real VT parser only if reading a TUI app's screen is needed.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $noEscapes = [regex]::Replace(
        $Text,
        "(\x1B\[[0-9;?]*[a-zA-Z])|(\x1B\][^\x07\x1B]*(\x07|\x1B\\))|(\x1B[PX^_][\s\S]*?\x1B\\)|(\x1B[@-Z\\\]^_])",
        ''
    )
    $normalized = $noEscapes -replace "`r`n", "`n"
    $lines = $normalized -split "`n" | ForEach-Object {
        $segments = $_ -split "`r"
        $segments[$segments.Length - 1]
    }
    return ($lines -join "`n")
}

function Read-PtySessionOutput {
    param(
        [Parameter(Mandatory)]$SessionState,
        [int]$Lines = 0
    )
    $raw = $SessionState.Session.ReadOutput()
    $clean = ConvertTo-PlainTerminalText -Text $raw
    if ($Lines -gt 0) {
        $allLines = $clean -split "`n"
        $take = [Math]::Min($Lines, $allLines.Length)
        $clean = ($allLines[($allLines.Length - $take)..($allLines.Length - 1)]) -join "`n"
    }
    return $clean
}

function Send-PtySessionControlChar {
    param(
        [Parameter(Mandatory)]$SessionState,
        [Parameter(Mandatory)][string]$Key
    )
    $upper = $Key.ToUpperInvariant()
    if ($upper -eq 'BREAK' -or $upper -eq 'PAUSE') {
        throw "Ctrl+Break is not supported over a ConPTY input stream (there is no ASCII control byte for it). Use 'C' (Ctrl+C) to interrupt the running command instead."
    }
    if ($upper.Length -ne 1 -or $upper -notmatch '[A-Z]') {
        throw "Unsupported control key '$Key'. Use a single letter (e.g. 'C' for Ctrl+C)."
    }
    # Ctrl+<letter> is the ASCII control byte (letter's position in the alphabet, 1-26).
    $byte = [byte]([byte][char]$upper - [byte][char]'A' + 1)
    $controlChar = [string][char]$byte
    $SessionState.Session.Write($controlChar)
}

function Close-PtySession {
    param([Parameter(Mandatory)]$SessionState)
    $SessionState.Session.Close()
}

function Test-PtySessionAlive {
    param([Parameter(Mandatory)]$SessionState)
    try {
        return [bool]$SessionState.Session.IsAlive
    } catch {
        return $false
    }
}

Export-ModuleMember -Function *-*
