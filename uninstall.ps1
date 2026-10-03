[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$NanoleafExe = "C:\Program Files\Nanoleaf Desktop\Nanoleaf Desktop.exe"
$AsarPath = "C:\Program Files\Nanoleaf Desktop\resources\app.asar"
$InstallDir = "C:\ProgramData\NHA"
$Patcher = Join-Path $InstallDir "asar-patch.cjs"
$TaskName = "Nanoleaf HA Plugin Repair"
$ExitCleanupTask = "Nanoleaf HA Exit Cleanup"
$FirewallRule = "Nanoleaf HA Embedded Plugin"

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $Process = Start-Process powershell.exe -Verb RunAs -ArgumentList $Arguments -Wait -PassThru
    exit $Process.ExitCode
}

Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName $ExitCleanupTask -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $ExitCleanupTask -Confirm:$false -ErrorAction SilentlyContinue
Get-Process "Nanoleaf Desktop" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

if (Test-Path $Patcher) {
    try {
        $PreviousRunAsNode = $env:ELECTRON_RUN_AS_NODE
        $env:ELECTRON_RUN_AS_NODE = "1"
        & $NanoleafExe $Patcher restore $AsarPath
        if ($LASTEXITCODE -ne 0) { throw "还原失败，退出码 $LASTEXITCODE" }
    }
    finally {
        if ($null -eq $PreviousRunAsNode) {
            Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
        }
        else {
            $env:ELECTRON_RUN_AS_NODE = $PreviousRunAsNode
        }
    }
}

Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
Start-Process $NanoleafExe
Write-Host "插件已卸载，Nanoleaf Desktop 已恢复为官方文件。" -ForegroundColor Green
Write-Host "为便于恢复，配置与备份保留在 C:\ProgramData\NHA。"
