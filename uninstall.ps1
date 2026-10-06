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
. (Join-Path $PSScriptRoot "runtime.ps1")

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
    $Result = Invoke-NhaPatcher -Exe $NanoleafExe -Patcher $Patcher -Command restore -Asar $AsarPath
    if ($Result.Stdout) { Write-Host $Result.Stdout.TrimEnd() }
    if ($Result.Stderr) { Write-Host $Result.Stderr.TrimEnd() }
    if ($Result.ExitCode -ne 0) { throw "还原失败，退出码 $($Result.ExitCode)" }
}

Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

$Shell = New-Object -ComObject WScript.Shell
foreach ($Folder in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
    $ShortcutPath = Join-Path $Folder 'Nanoleaf Desktop (HA).lnk'
    if (Test-Path -LiteralPath $ShortcutPath) {
        $Shortcut = $Shell.CreateShortcut($ShortcutPath)
        if ($Shortcut.Arguments.Contains((Join-Path $InstallDir 'startup.vbs'))) {
            Remove-Item -LiteralPath $ShortcutPath -Force
        }
    }
}
# Restore only the login entry that points to our launcher, keeping its name.
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if (Test-Path $RunKey) {
    foreach ($Property in (Get-ItemProperty $RunKey).PSObject.Properties) {
        if ($Property.Value -is [string] -and $Property.Value.Contains((Join-Path $InstallDir 'startup.vbs'))) {
            Set-ItemProperty -LiteralPath $RunKey -Name $Property.Name -Value "`"$NanoleafExe`" --hidden"
        }
    }
}
Start-Process $NanoleafExe
Write-Host "插件已卸载，Nanoleaf Desktop 已恢复为官方文件。" -ForegroundColor Green
Write-Host "为便于恢复，配置与备份保留在 C:\ProgramData\NHA。"
