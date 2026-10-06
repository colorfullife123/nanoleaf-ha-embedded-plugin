[CmdletBinding()]
param(
    [switch]$Hidden,
    [string]$InstallDir = $PSScriptRoot,
    [string]$NanoleafExe = 'C:\Program Files\Nanoleaf Desktop\Nanoleaf Desktop.exe',
    [string]$TaskName = 'Nanoleaf HA Plugin Repair',
    [ValidateRange(1, 180)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'startup-runtime.ps1')
$Mutex = New-Object Threading.Mutex($false, 'Local\NanoleafHAStartup')
$Acquired = $false
try {
    try { $Acquired = $Mutex.WaitOne($TimeoutSeconds * 1000) }
    catch [Threading.AbandonedMutexException] { $Acquired = $true }
    if (-not $Acquired) { throw 'Another startup check is still running.' }
    if (-not (Test-Path -LiteralPath $NanoleafExe -PathType Leaf)) { throw 'Nanoleaf Desktop executable was not found.' }

    $Running = @(Get-Process 'Nanoleaf Desktop' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $NanoleafExe })
    if (-not $Running.Count) {
        # Only this explicit launch request runs the elevated check. There are
        # no time/logon triggers and the repair task never launches Desktop.
        $ExitCode = Invoke-NhaStartupCheck -TaskName $TaskName -TimeoutSeconds $TimeoutSeconds
        if ($ExitCode -eq 3) { throw 'Nanoleaf is updating; try launching again after the update finishes.' }
        if ($ExitCode -ne 0) { throw "Startup repair failed with exit code $ExitCode. See repair.log." }
    }

    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = $NanoleafExe
    $Info.WorkingDirectory = Split-Path -Parent $NanoleafExe
    $Info.UseShellExecute = $false
    $Info.CreateNoWindow = $true
    if ($Hidden) { $Info.Arguments = '--hidden' }
    # The app stays under the launcher's normal user token; only the repair
    # task runs elevated. Never inherit the patcher helper's Node mode.
    $Info.EnvironmentVariables.Remove('ELECTRON_RUN_AS_NODE')
    $Desktop = [Diagnostics.Process]::Start($Info)
    if ($Desktop) { $Desktop.Dispose() }
}
catch {
    Add-Content -LiteralPath (Join-Path $InstallDir 'launch.log') `
        -Value "$(Get-Date -Format o) ERROR: $($_.Exception.Message)" -Encoding UTF8
    exit 1
}
finally {
    if ($Acquired) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
}
