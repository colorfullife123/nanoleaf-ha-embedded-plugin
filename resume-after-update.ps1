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

Get-Process "Nanoleaf Desktop" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

try {
    $PreviousRunAsNode = $env:ELECTRON_RUN_AS_NODE
    $env:ELECTRON_RUN_AS_NODE = "1"
    & $NanoleafExe $Patcher patch $AsarPath
    if ($LASTEXITCODE -ne 0) { throw "补丁不兼容当前版本，退出码 $LASTEXITCODE" }
}
finally {
    if ($null -eq $PreviousRunAsNode) {
        Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
    }
    else {
        $env:ELECTRON_RUN_AS_NODE = $PreviousRunAsNode
    }
}

Enable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
Start-Process $NanoleafExe
Write-Host "插件已恢复，Nanoleaf Desktop 已启动。" -ForegroundColor Green
