# Use a retained .NET process handle for Electron's GUI executable. Windows
# PowerShell's direct invocation / Start-Process may return a null exit code.
function Invoke-NhaPatcher {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [Parameter(Mandatory = $true)][string]$Patcher,
        [Parameter(Mandatory = $true)][ValidateSet('check', 'patch', 'restore')][string]$Command,
        [Parameter(Mandatory = $true)][string]$Asar,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 45
    )

    foreach ($FilePath in @($Exe, $Patcher, $Asar)) {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            throw "Required file not found: $FilePath"
        }
        if ($FilePath.Contains('"')) { throw 'A file path contains an invalid quote.' }
    }

    $StartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $StartInfo.FileName = $Exe
    $StartInfo.Arguments = '"{0}" {1} "{2}"' -f $Patcher, $Command, $Asar
    $StartInfo.WorkingDirectory = Split-Path -Parent $Patcher
    $StartInfo.UseShellExecute = $false
    $StartInfo.CreateNoWindow = $true
    $StartInfo.RedirectStandardOutput = $true
    $StartInfo.RedirectStandardError = $true
    $StartInfo.EnvironmentVariables['ELECTRON_RUN_AS_NODE'] = '1'

    $Process = New-Object System.Diagnostics.Process
    $Process.StartInfo = $StartInfo
    try {
        if (-not $Process.Start()) { throw 'Could not start the patcher.' }
        $StdoutTask = $Process.StandardOutput.ReadToEndAsync()
        $StderrTask = $Process.StandardError.ReadToEndAsync()
        if (-not $Process.WaitForExit($TimeoutSeconds * 1000)) {
            # This is only the short-lived patcher helper, not the desktop app.
            try { $Process.Kill() } catch { }
            throw "Patcher timed out after $TimeoutSeconds seconds."
        }
        return [pscustomobject]@{
            ExitCode = [int]$Process.ExitCode
            Stdout = $StdoutTask.GetAwaiter().GetResult()
            Stderr = $StderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $Process.Dispose() }
}
