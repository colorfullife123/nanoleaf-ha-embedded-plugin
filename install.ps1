[CmdletBinding()]
param(
    [string]$HaIp = "",
    [string]$PcIp = "",
    [ValidateRange(1024, 65535)]
    [int]$Port = 17654,
    [string]$DeviceJId = "",
    [string]$DeviceKId = "",
    [string]$DeviceJName = "",
    [string]$DeviceKName = "",
    [string]$DeviceModel = "NL82K1"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 2.0

function Test-Administrator {
    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $Principal = New-Object Security.Principal.WindowsPrincipal($Identity)
    return $Principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-PowerShellLiteral([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Test-Ipv4([string]$Value) {
    $Address = $null
    return [Net.IPAddress]::TryParse($Value, [ref]$Address) -and
        $Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork
}

function Get-PreferredIpv4 {
    $Addresses = @(
        Get-NetIPConfiguration -ErrorAction SilentlyContinue |
            Where-Object {
                $_.NetAdapter.Status -eq "Up" -and $_.IPv4DefaultGateway
            } |
            ForEach-Object { $_.IPv4Address.IPAddress } |
            Where-Object {
                $_ -and $_ -ne "127.0.0.1" -and -not $_.StartsWith("169.254.")
            }
    )
    $Preferred = $Addresses |
        Where-Object {
            $_.StartsWith("192.168.") -or
            $_.StartsWith("10.") -or
            ($_ -match '^172\.(1[6-9]|2[0-9]|3[01])\.')
        } |
        Select-Object -First 1
    if (-not $Preferred) {
        $Preferred = $Addresses | Select-Object -First 1
    }
    return [string]$Preferred
}

function Get-PegboardSerials {
    try {
        return @(
            Get-PnpDevice -PresentOnly -ErrorAction Stop |
                Where-Object {
                    $_.InstanceId -match '^USB\\VID_37FA&PID_8201\\(.+)$'
                } |
                ForEach-Object { ($_.InstanceId -split '\\')[-1] } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )
    }
    catch {
        Write-Warning "无法自动读取 Pegboard USB 设备：$($_.Exception.Message)"
        return @()
    }
}

if (-not (Test-Administrator)) {
    $Parts = @(
        "& $(ConvertTo-PowerShellLiteral $PSCommandPath)",
        "-HaIp $(ConvertTo-PowerShellLiteral $HaIp)",
        "-PcIp $(ConvertTo-PowerShellLiteral $PcIp)",
        "-Port $Port",
        "-DeviceJId $(ConvertTo-PowerShellLiteral $DeviceJId)",
        "-DeviceKId $(ConvertTo-PowerShellLiteral $DeviceKId)",
        "-DeviceJName $(ConvertTo-PowerShellLiteral $DeviceJName)",
        "-DeviceKName $(ConvertTo-PowerShellLiteral $DeviceKName)",
        "-DeviceModel $(ConvertTo-PowerShellLiteral $DeviceModel)"
    )
    $Command = $Parts -join " "
    $EncodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
    $Process = Start-Process powershell.exe -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $EncodedCommand" `
        -Wait -PassThru
    exit $Process.ExitCode
}

$InstallDir = "C:\ProgramData\NHA"
$NanoleafExe = "C:\Program Files\Nanoleaf Desktop\Nanoleaf Desktop.exe"
$AsarPath = "C:\Program Files\Nanoleaf Desktop\resources\app.asar"
$RepairTask = "Nanoleaf HA Plugin Repair"
$LegacyExitCleanupTask = "Nanoleaf HA Exit Cleanup"
$FirewallRule = "Nanoleaf HA Embedded Plugin"
$OldTask = "Nanoleaf HA Gateway"
. (Join-Path $PSScriptRoot "runtime.ps1")

if (-not (Test-Path $NanoleafExe) -or -not (Test-Path $AsarPath)) {
    throw "未找到 Nanoleaf Desktop 3.x，请先安装官方桌面端。"
}

Write-Host "正在安装 Nanoleaf HA 嵌入式插件..." -ForegroundColor Cyan

# Validate the new official build before changing the installed plugin/config.
$CheckResult = Invoke-NhaPatcher -Exe $NanoleafExe `
    -Patcher (Join-Path $PSScriptRoot "asar-patch.cjs") -Command check -Asar $AsarPath
if ($CheckResult.ExitCode -notin @(0, 2, 4)) {
    throw "当前 Nanoleaf 版本不兼容，退出码 $($CheckResult.ExitCode)。 $($CheckResult.Stderr)"
}
if ($CheckResult.Stdout) { Write-Host $CheckResult.Stdout.TrimEnd() }

# Reuse settings and the token during an upgrade so existing HA entities keep working.
$ExistingConfig = $null
$CandidateConfigs = @(
    (Join-Path $InstallDir "config.json"),
    "C:\ProgramData\NanoleafHA\config.json"
)
foreach ($Candidate in $CandidateConfigs) {
    if ($ExistingConfig -or -not (Test-Path $Candidate)) { continue }
    try {
        $ExistingConfig = Get-Content $Candidate -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "无法读取旧配置：$Candidate"
    }
}

$Token = ""
if ($ExistingConfig -and
    $ExistingConfig.PSObject.Properties.Name -contains "token" -and
    $ExistingConfig.token) {
    $Token = [string]$ExistingConfig.token
}
if (-not $Token) {
    $Bytes = New-Object byte[] 32
    $Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $Generator.GetBytes($Bytes) }
    finally { $Generator.Dispose() }
    $Token = -join ($Bytes | ForEach-Object { $_.ToString("x2") })
}

$HaIp = $HaIp.Trim()
if (-not $HaIp -and $ExistingConfig -and
    $ExistingConfig.PSObject.Properties.Name -contains "haIp") {
    $HaIp = [string]$ExistingConfig.haIp
}
if (-not (Test-Ipv4 $HaIp)) {
    throw "请使用 -HaIp 指定 HAOS 的 IPv4 地址，例如：.\install.ps1 -HaIp 192.168.1.50"
}

$PcIp = $PcIp.Trim()
if (-not $PcIp -and $ExistingConfig -and
    $ExistingConfig.PSObject.Properties.Name -contains "pcIp") {
    $PcIp = [string]$ExistingConfig.pcIp
}
if (-not $PcIp) {
    $PcIp = Get-PreferredIpv4
}
if (-not (Test-Ipv4 $PcIp)) {
    throw "无法自动确定 Windows IPv4 地址，请使用 -PcIp 手动指定。"
}

$ExistingDevices = $null
if ($ExistingConfig -and
    $ExistingConfig.PSObject.Properties.Name -contains "devices") {
    $ExistingDevices = $ExistingConfig.devices
}
if (-not $DeviceJId -and $ExistingDevices -and
    $ExistingDevices.PSObject.Properties.Name -contains "j") {
    $DeviceJId = [string]$ExistingDevices.j.id
    if (-not $DeviceJName) { $DeviceJName = [string]$ExistingDevices.j.name }
}
if (-not $DeviceKId -and $ExistingDevices -and
    $ExistingDevices.PSObject.Properties.Name -contains "k") {
    $DeviceKId = [string]$ExistingDevices.k.id
    if (-not $DeviceKName) { $DeviceKName = [string]$ExistingDevices.k.name }
}

$DetectedIds = @(Get-PegboardSerials)
$AvailableIds = @($DetectedIds | Where-Object { $_ -notin @($DeviceJId, $DeviceKId) })
if (-not $DeviceJId) {
    $JChoices = @(
        @($AvailableIds | Where-Object { $_.EndsWith("J", [StringComparison]::OrdinalIgnoreCase) }) +
        @($AvailableIds)
    )
    if ($JChoices.Count -gt 0) { $DeviceJId = [string]$JChoices[0] }
    $AvailableIds = @($AvailableIds | Where-Object { $_ -ne $DeviceJId })
}
if (-not $DeviceKId -and $AvailableIds.Count -gt 0) {
    $KChoices = @(
        @($AvailableIds | Where-Object { $_.EndsWith("K", [StringComparison]::OrdinalIgnoreCase) }) +
        @($AvailableIds)
    )
    $DeviceKId = [string]$KChoices[0]
}

$DeviceJId = $DeviceJId.Trim()
$DeviceKId = $DeviceKId.Trim()
if (-not $DeviceJId) {
    throw "未检测到 Pegboard Desk Dock。请连接设备，或使用 -DeviceJId 手动指定设备 ID。"
}
if ($DeviceKId -and $DeviceKId -eq $DeviceJId) {
    throw "J 与 K 不能使用同一个设备 ID。"
}
if (-not $DeviceJName) { $DeviceJName = "桌面灯板 J" }
if (-not $DeviceKName) { $DeviceKName = "桌面灯板 K" }
if (-not $DeviceModel) { $DeviceModel = "NL82K1" }

# Retire the previous CDP/9222 supervisor before replacing it.
Stop-ScheduledTask -TaskName $OldTask -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $OldTask -Confirm:$false -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName $RepairTask -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName $LegacyExitCleanupTask -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $LegacyExitCleanupTask -Confirm:$false -ErrorAction SilentlyContinue

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessId -ne $PID -and $_.CommandLine -and
        ($_.CommandLine -match "nanoleaf-ha-gateway" -or $_.CommandLine -match "ProgramData\\NanoleafHA")
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Get-Process "Nanoleaf Desktop" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
Remove-Item `
    (Join-Path $InstallDir "exit-cleanup.ps1") `
    -Force `
    -ErrorAction SilentlyContinue
$Files = @(
    "m.mjs",
    "ha-preload.cjs",
    "ha-window.html",
    "ha-window.css",
    "ha-window.js",
    "asar-patch.cjs",
    "runtime.ps1",
    "repair.ps1",
    "prepare-update.ps1",
    "resume-after-update.ps1",
    "uninstall.ps1",
    "status.ps1",
    "README.md",
    "LICENSE",
    "VERSION"
)
foreach ($File in $Files) {
    $Source = Join-Path $PSScriptRoot $File
    if (-not (Test-Path $Source)) { throw "安装包缺少文件：$File" }
    $Destination = Join-Path $InstallDir $File
    if ([IO.Path]::GetFullPath($Source) -ne [IO.Path]::GetFullPath($Destination)) {
        Copy-Item $Source $Destination -Force
    }
}

$Devices = [ordered]@{
    j = [ordered]@{
        id = $DeviceJId
        model = $DeviceModel
        name = $DeviceJName
        port = 0
    }
}
if ($DeviceKId) {
    $Devices.k = [ordered]@{
        id = $DeviceKId
        model = $DeviceModel
        name = $DeviceKName
        port = 0
    }
}
$Config = [ordered]@{
    version = 2
    enabled = $true
    host = "0.0.0.0"
    port = $Port
    token = $Token
    haIp = $HaIp
    pcIp = $PcIp
    autoStart = $true
    devices = $Devices
}
$Config | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $InstallDir "config.json") -Encoding UTF8

# Allow the signed-in user to change settings and write the plugin log.
$UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& icacls.exe $InstallDir /inheritance:r /grant:r `
    "*S-1-5-18:(OI)(CI)F" `
    "*S-1-5-32-544:(OI)(CI)F" `
    "*$UserSid`:(OI)(CI)M" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "设置插件目录权限失败。" }

Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayName "Nanoleaf HA Gateway" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
New-NetFirewallRule `
    -DisplayName $FirewallRule `
    -Direction Inbound `
    -Action Allow `
    -Protocol TCP `
    -LocalPort $Port `
    -RemoteAddress $HaIp `
    -Profile Any | Out-Null

$Result = Invoke-NhaPatcher -Exe $NanoleafExe `
    -Patcher (Join-Path $InstallDir "asar-patch.cjs") -Command patch -Asar $AsarPath
if ($Result.Stdout) { Write-Host $Result.Stdout.TrimEnd() }
if ($Result.Stderr) { Write-Host $Result.Stderr.TrimEnd() }
if ($Result.ExitCode -ne 0) { throw "app.asar 补丁失败，退出码 $($Result.ExitCode)" }

$CurrentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$Action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallDir\repair.ps1`""
$Trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$Trigger.Delay = "PT45S"
$UpdateTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1)
$Principal = New-ScheduledTaskPrincipal `
    -UserId $CurrentUser `
    -LogonType Interactive `
    -RunLevel Highest
$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask `
    -TaskName $RepairTask `
    -Action $Action `
    -Trigger @($Trigger, $UpdateTrigger) `
    -Principal $Principal `
    -Settings $Settings `
    -Force | Out-Null

Start-Process $NanoleafExe

$HealthOk = $false
$Headers = @{ Authorization = "Bearer $Token" }
for ($Attempt = 0; $Attempt -lt 45; $Attempt++) {
    Start-Sleep -Seconds 2
    try {
        $Health = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$Port/health" `
            -Headers $Headers `
            -TimeoutSec 3
        if ($Health.ok) { $HealthOk = $true; break }
    }
    catch { }
}

Write-Host ""
Write-Host "Nanoleaf HA 嵌入式插件安装完成。" -ForegroundColor Green
Write-Host "Windows IP : $PcIp"
Write-Host "HAOS IP    : $HaIp"
Write-Host "设备 J     : $DeviceJId"
if ($DeviceKId) { Write-Host "设备 K     : $DeviceKId" }
Write-Host "网关地址   : http://${PcIp}:$Port"
Write-Host "应用入口   : Nanoleaf 主窗口左下角的 HA 按钮"
Write-Host "登录启动   : 已启用 --hidden（只进入托盘）"
Write-Host "自动更新   : 每分钟检查，文件稳定后自动恢复已兼容版本"
Write-Host "退出方式   : 兼容清理后由 Nanoleaf 主进程自终止（无外部强制任务）"
Write-Host "网关健康   : $HealthOk"
if (-not $HealthOk) {
    Write-Warning "插件入口已安装，但网关尚未就绪。请打开 Nanoleaf 后运行 C:\ProgramData\NHA\status.ps1。"
}
