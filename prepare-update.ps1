[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$NanoleafExe = "C:\Program Files\Nanoleaf Desktop\Nanoleaf Desktop.exe"
$AsarPath = "C:\Program Files\Nanoleaf Desktop\resources\app.asar"
$InstallDir = "C:\ProgramData\NHA"
$Patcher = Join-Path $InstallDir "asar-patch.cjs"
$TaskName = "Nanoleaf HA Plugin Repair"

$Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
if (-not $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $Process = Start-Process powershell.exe -Verb RunAs -ArgumentList $Arguments -Wait -PassThru
    exit $Process.ExitCode
}

Disable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
Get-Process "Nanoleaf Desktop" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

try {
    $PreviousRunAsNode = $env:ELECTRON_RUN_AS_NODE
    $env:ELECTRON_RUN_AS_NODE = "1"
    & $NanoleafExe $Patcher restore $AsarPath
    if ($LASTEXITCODE -ne 0) { throw "还原官方 app.asar 失败，退出码 $LASTEXITCODE" }
}
finally {
    if ($null -eq $PreviousRunAsNode) {
        Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
    else {
        $env:ELECTRON_RUN_AS_NODE = $PreviousRunAsNode
    }
}

Start-Process $NanoleafExe
Write-Host "已还原官方 Nanoleaf 文件并暂停插件自动修复。" -ForegroundColor Green
Write-Host "现在可以在 Nanoleaf Desktop 中执行官方更新。"
Write-Host "更新完成后，以管理员身份运行：C:\ProgramData\NHA\resume-after-update.ps1"
