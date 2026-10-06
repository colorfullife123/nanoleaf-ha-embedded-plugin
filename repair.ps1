[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$InstallDir = "C:\ProgramData\NHA"
$LogPath = Join-Path $InstallDir "repair.log"
$NanoleafExe = "C:\Program Files\Nanoleaf Desktop\Nanoleaf Desktop.exe"
$AsarPath = "C:\Program Files\Nanoleaf Desktop\resources\app.asar"
$Patcher = Join-Path $InstallDir "asar-patch.cjs"
. (Join-Path $PSScriptRoot "runtime.ps1")

function Write-RepairLog([string]$Message) {
    Add-Content $LogPath "$(Get-Date -Format o) $Message" -Encoding UTF8
}

try {
    if (-not (Test-Path $NanoleafExe) -or -not (Test-Path $AsarPath) -or -not (Test-Path $Patcher)) {
        Write-RepairLog "Required files are missing; skipped."
        exit 1
    }

    $Updater = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -match "nanoleaf-updater" -or $_.CommandLine -match "Nanoleaf.*Update")
        } |
        Select-Object -First 1
    if ($Updater) {
        Write-RepairLog "Nanoleaf updater is active; skipped."
        exit 0
    }

    $Result = Invoke-NhaPatcher -Exe $NanoleafExe -Patcher $Patcher -Command check -Asar $AsarPath
    $CheckCode = $Result.ExitCode

    if ($CheckCode -eq 0) {
        Write-RepairLog "Plugin patch is already active."
        exit 0
    }
    if ($CheckCode -notin @(2, 4)) {
        Write-RepairLog "Current Nanoleaf version is incompatible; check exit code $CheckCode."
        exit $CheckCode
    }

    Get-Process "Nanoleaf Desktop" -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $Result = Invoke-NhaPatcher -Exe $NanoleafExe -Patcher $Patcher -Command patch -Asar $AsarPath
    if ($Result.Stdout) { Write-RepairLog $Result.Stdout.TrimEnd() }
    if ($Result.Stderr) { Write-RepairLog $Result.Stderr.TrimEnd() }
    if ($Result.ExitCode -ne 0) { throw "Patch command failed with exit code $($Result.ExitCode)" }

    Start-Process $NanoleafExe -ArgumentList "--hidden"
    Write-RepairLog "Plugin patch restored after an app update; Nanoleaf started hidden."
}
catch {
    Write-RepairLog "ERROR: $($_.Exception.Message)"
    exit 1
}
