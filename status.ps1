[CmdletBinding()]
param()

$InstallDir = "C:\ProgramData\NHA"
$NanoleafExe = "C:\Program Files\Nanoleaf Desktop\Nanoleaf Desktop.exe"
$AsarPath = "C:\Program Files\Nanoleaf Desktop\resources\app.asar"
$Patcher = Join-Path $InstallDir "asar-patch.cjs"
$ConfigPath = Join-Path $InstallDir "config.json"
$BridgePort = 17654
. (Join-Path $PSScriptRoot "runtime.ps1")

Write-Host "===== Nanoleaf HA Embedded Plugin =====" -ForegroundColor Cyan
if (Test-Path $ConfigPath) {
    $Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Write-Host "Endpoint : http://$($Config.pcIp):$($Config.port)"
    Write-Host "HAOS IP  : $($Config.haIp)"
    Write-Host "Enabled  : $($Config.enabled)"
    $BridgePort = [int]$Config.port
    if ($Config.PSObject.Properties.Name -contains "devices") {
        foreach ($Key in @("j", "k")) {
            if ($Config.devices.PSObject.Properties.Name -contains $Key) {
                $Device = $Config.devices.$Key
                Write-Host "Device $($Key.ToUpper()) : $($Device.name) [$($Device.id)]"
            }
        }
    }
}

if ((Test-Path $NanoleafExe) -and (Test-Path $Patcher) -and (Test-Path $AsarPath)) {
    $Result = Invoke-NhaPatcher -Exe $NanoleafExe -Patcher $Patcher -Command check -Asar $AsarPath
    if ($Result.Stdout) { Write-Host $Result.Stdout.TrimEnd() }
    if ($Result.Stderr) { Write-Host $Result.Stderr.TrimEnd() }
    Write-Host "PatchExit: $($Result.ExitCode)"
}

Write-Host ""
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -in @(15765, 15766, $BridgePort) } |
    Select-Object LocalAddress, LocalPort, OwningProcess |
    Format-Table -AutoSize

if (Test-Path (Join-Path $InstallDir "repair-state.json")) {
    Write-Host "===== Automatic update repair ====="
    $RepairState = Get-Content (Join-Path $InstallDir "repair-state.json") -Raw | ConvertFrom-Json
    Write-Host "Status   : $($RepairState.status)"
    Write-Host "Observed : $($RepairState.observedAtUtc)"
}
if (Test-Path (Join-Path $InstallDir "repair.log")) {
    Get-Content (Join-Path $InstallDir "repair.log") -Tail 10
}

Write-Host "===== Scheduled tasks ====="
Get-ScheduledTask -ErrorAction SilentlyContinue |
    Where-Object { $_.TaskName -eq "Nanoleaf HA Plugin Repair" } |
    Select-Object TaskName, State |
    Format-Table -AutoSize

if (Test-Path (Join-Path $InstallDir "plugin.log")) {
    Write-Host "===== plugin.log (last 15 lines) ====="
    Get-Content (Join-Path $InstallDir "plugin.log") -Tail 15
}
