[CmdletBinding()]
param(
    [string]$InstallDir = 'C:\ProgramData\NHA',
    [string]$NanoleafExe = 'C:\Program Files\Nanoleaf Desktop\Nanoleaf Desktop.exe',
    [string]$AsarPath = 'C:\Program Files\Nanoleaf Desktop\resources\app.asar'
)

$ErrorActionPreference = 'Stop'
$LogPath = Join-Path $InstallDir 'repair.log'
$StatePath = Join-Path $InstallDir 'repair-state.json'
$Patcher = Join-Path $InstallDir 'asar-patch.cjs'
. (Join-Path $PSScriptRoot 'runtime.ps1')
$RestartNeeded = $false

function Write-RepairLog([string]$Message) {
    if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 1048576) {
        Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.1') -Force
    }
    Add-Content -LiteralPath $LogPath -Value "$(Get-Date -Format o) $Message" -Encoding UTF8
}

function Get-ArchiveStamp {
    $Item = Get-Item -LiteralPath $AsarPath
    return "$($Item.Length):$($Item.LastWriteTimeUtc.Ticks)"
}

function Save-RepairState([string]$Status, [string]$Stamp, [bool]$UpdaterActive = $false) {
    $Next = [ordered]@{
        pluginVersion = $PluginVersion
        status = $Status
        fingerprint = $Stamp
        observedAtUtc = [DateTime]::UtcNow.ToString('o')
        updaterActive = $UpdaterActive
    }
    $Next | ConvertTo-Json | Set-Content -LiteralPath ($StatePath + '.tmp') -Encoding UTF8
    Move-Item -LiteralPath ($StatePath + '.tmp') -Destination $StatePath -Force
}

function Get-NanoleafUpdater {
    return Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object {
            $_.CommandLine -and
            ($_.CommandLine -match 'nanoleaf-updater' -or $_.CommandLine -match 'Nanoleaf.*Update')
        } | Select-Object -First 1
}

try {
    foreach ($FilePath in @($NanoleafExe, $AsarPath, $Patcher, (Join-Path $InstallDir 'VERSION'))) {
        if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
            Write-RepairLog 'Required files are missing; skipped.'
            exit 0
        }
    }
    $PluginVersion = (Get-Content -LiteralPath (Join-Path $InstallDir 'VERSION') -Raw).Trim()
    $Stamp = Get-ArchiveStamp
    $State = $null
    if (Test-Path -LiteralPath $StatePath) {
        try { $State = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } catch { }
    }
    $SameArchive = $State -and $State.pluginVersion -eq $PluginVersion -and $State.fingerprint -eq $Stamp
    if ($SameArchive -and $State.status -in @('active', 'unsupported')) {
        # No node helper, restart, or repeated log message for an unchanged file.
        exit 0
    }

    if (Get-NanoleafUpdater) {
        if (-not $SameArchive -or -not $State.updaterActive) {
            Write-RepairLog 'Nanoleaf updater is active; waiting.'
        }
        Save-RepairState 'pending' $Stamp $true
        exit 0
    }

    # An installed, verified patch can be cached immediately after installation.
    $PatchStatePath = Join-Path $InstallDir 'patch-state.json'
    if (Test-Path -LiteralPath $PatchStatePath) {
        $PatchState = $null
        try { $PatchState = Get-Content -LiteralPath $PatchStatePath -Raw | ConvertFrom-Json } catch { }
        if ($PatchState -and $PatchState.active -and $PatchState.afterHash -and
            (Get-FileHash -LiteralPath $AsarPath -Algorithm SHA256).Hash -eq $PatchState.afterHash) {
            Save-RepairState 'active' $Stamp
            exit 0
        }
    }

    # Two observations separate by at least 30 seconds keep us out of the
    # updater's file replacement window. The task's interval is one minute.
    if (-not $SameArchive -or $State.status -ne 'pending') {
        Save-RepairState 'pending' $Stamp
        Write-RepairLog 'Archive change detected; waiting for a stable update.'
        exit 0
    }
    $Observed = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$State.observedAtUtc, [ref]$Observed)) {
        Save-RepairState 'pending' $Stamp
        exit 0
    }
    if (([DateTime]::UtcNow - $Observed.ToUniversalTime()).TotalSeconds -lt 30) { exit 0 }

    $Result = Invoke-NhaPatcher -Exe $NanoleafExe -Patcher $Patcher -Command check -Asar $AsarPath
    if ($Result.ExitCode -eq 0) {
        Save-RepairState 'active' $Stamp
        exit 0
    }
    if ($Result.ExitCode -notin @(2, 4)) {
        Save-RepairState 'unsupported' $Stamp
        Write-RepairLog "Current Nanoleaf build needs a compatible plugin; official app left unchanged. $($Result.Stderr.TrimEnd())"
        exit 0
    }
    if ((Get-ArchiveStamp) -ne $Stamp -or (Get-NanoleafUpdater)) {
        Save-RepairState 'pending' (Get-ArchiveStamp)
        exit 0
    }

    $Running = @(Get-Process 'Nanoleaf Desktop' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $NanoleafExe })
    $RestartNeeded = $Running.Count -gt 0
    foreach ($DesktopProcess in $Running) {
        Stop-Process -Id $DesktopProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($RestartNeeded) { Start-Sleep -Seconds 2 }
    if ((Get-ArchiveStamp) -ne $Stamp) { throw 'Archive changed again; repair postponed.' }

    $Result = Invoke-NhaPatcher -Exe $NanoleafExe -Patcher $Patcher -Command patch -Asar $AsarPath
    if ($Result.Stdout) { Write-RepairLog $Result.Stdout.TrimEnd() }
    if ($Result.Stderr) { Write-RepairLog $Result.Stderr.TrimEnd() }
    if ($Result.ExitCode -ne 0) { throw "Patch command failed with exit code $($Result.ExitCode)" }
    Save-RepairState 'active' (Get-ArchiveStamp)
    if ($RestartNeeded) {
        Start-Process $NanoleafExe -ArgumentList '--hidden'
        $RestartNeeded = $false
        Write-RepairLog 'Automatic update repair completed; Nanoleaf restarted hidden.'
    }
    else {
        Write-RepairLog 'Automatic update repair completed; Nanoleaf was closed and remains closed.'
    }
}
catch {
    Write-RepairLog "ERROR: $($_.Exception.Message)"
    if ($RestartNeeded -and (Test-Path -LiteralPath $NanoleafExe)) {
        Start-Process $NanoleafExe -ArgumentList '--hidden'
        Write-RepairLog 'Nanoleaf restarted after an unsuccessful repair attempt.'
    }
    exit 1
}
