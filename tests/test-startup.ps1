$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $Root 'startup-runtime.ps1')
$TempDir = Join-Path $env:TEMP ('nha startup test ' + [Guid]::NewGuid().ToString('N'))
$TaskName = 'NHA Startup Test ' + [Guid]::NewGuid().ToString('N')
$TaskRegistered = $false
$PreviousNodeMode = $env:ELECTRON_RUN_AS_NODE
$PreviousTestDir = $env:NHA_TEST_DIR
New-Item -ItemType Directory -Path $TempDir | Out-Null
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Run-ScriptHost([string]$Argument, [int]$ExpectedExit = 0) {
    $Info = New-Object Diagnostics.ProcessStartInfo
    $Info.FileName = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $Info.Arguments = '//B //Nologo "{0}" {1}' -f (Join-Path $TempDir 'startup.vbs'), $Argument
    $Info.UseShellExecute = $false
    $Process = [Diagnostics.Process]::Start($Info)
    try {
        Assert-Test ($Process.WaitForExit(30000)) 'Script host did not finish'
        Assert-Test ($Process.ExitCode -eq $ExpectedExit) "Script host exit code $($Process.ExitCode)"
    }
    finally { $Process.Dispose() }
}
function Run-Launch([switch]$Hidden, [int]$ExpectedExit = 0, [switch]$Existing) {
    $ArgsList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $TempDir 'run-launch.ps1'))
    if ($Hidden) { $ArgsList += '-Hidden' }
    if ($Existing) { $ArgsList += '-Existing' }
    $Output = & "$PSHOME\powershell.exe" @ArgsList 2>&1
    Assert-Test ($LASTEXITCODE -eq $ExpectedExit) "Launcher failed (exit $LASTEXITCODE): $Output"
}
function Wait-AppTrace([int]$Count) {
    $Deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $Deadline) {
        if ((Test-Path (Join-Path $TempDir 'app.txt')) -and @(Get-Content (Join-Path $TempDir 'app.txt')).Count -ge $Count) { return }
        Start-Sleep -Milliseconds 100
    }
    throw 'Desktop test helper was not launched'
}
try {
    Copy-Item (Join-Path $Root 'startup.vbs') $TempDir
    # Inspect the actual STARTUPINFO of the child created by WScript.Run.
    @'
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class NhaStartupInfo {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct Info {
        public uint cb; public IntPtr reserved, desktop, title;
        public uint x, y, xSize, ySize, xChars, yChars, fill, flags;
        public ushort show, reservedSize;
        public IntPtr reservedBytes, stdin, stdout, stderr;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    public static extern void GetStartupInfo(out Info info);
    public static Info Read() { Info info; GetStartupInfo(out info); return info; }
}
"@
$StartupInfo = [NhaStartupInfo]::Read()
[ordered]@{hidden=$Hidden.IsPresent; flags=$StartupInfo.flags; show=$StartupInfo.show} |
    ConvertTo-Json | Set-Content (Join-Path $PSScriptRoot 'window.json') -Encoding ASCII
'@ | Set-Content (Join-Path $TempDir 'report.ps1') -Encoding ASCII
    @'
param([switch]$Hidden)
. (Join-Path $PSScriptRoot 'report.ps1')
'@ | Set-Content (Join-Path $TempDir 'launch.ps1') -Encoding ASCII
    @'
param([switch]$Hidden)
. (Join-Path $PSScriptRoot 'report.ps1')
exit 4
'@ | Set-Content (Join-Path $TempDir 'repair.ps1') -Encoding ASCII
    foreach ($Argument in @('', '--hidden', '--repair')) {
        if ($Argument -eq '--repair') { Run-ScriptHost $Argument 4 } else { Run-ScriptHost $Argument }
        $Report = Get-Content (Join-Path $TempDir 'window.json') -Raw | ConvertFrom-Json
        Assert-Test (($Report.flags -band 1) -eq 1 -and $Report.show -eq 0) 'PowerShell was not created with SW_HIDE'
        Assert-Test ($Report.hidden -eq ($Argument -eq '--hidden')) 'Hidden argument forwarding failed'
    }
    Run-ScriptHost '--invalid' 2

    # A real on-demand scheduled task verifies COM waiting and returned errors.
    $Action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\wscript.exe') `
        -Argument (('//B //Nologo "{0}" --repair') -f (Join-Path $TempDir 'startup.vbs'))
    $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $Principal = New-ScheduledTaskPrincipal -UserId $User -LogonType S4U -RunLevel Highest
    # Replacing a 1.1.6 task must remove its old triggers, not just add a new
    # action while keeping the minute timer.
    $OldTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddHours(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $OldTrigger -Principal $Principal -Force | Out-Null
    $TaskRegistered = $true
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal -Force | Out-Null
    $TaskRegistered = $true
    Assert-Test (@((Get-ScheduledTask -TaskName $TaskName).Triggers).Count -eq 0) 'Task still has scheduled triggers'
    Assert-Test ((Invoke-NhaStartupCheck -TaskName $TaskName -TimeoutSeconds 30) -eq 4) 'Task exit code was not propagated'

    @'
[IO.File]::AppendAllText((Join-Path $PSScriptRoot 'checks.txt'), "check`n")
exit 0
'@ | Set-Content (Join-Path $TempDir 'repair.ps1') -Encoding ASCII
    $Exe = Join-Path $TempDir 'desktop-test.exe'
    Add-Type -TypeDefinition @'
using System;
using System.IO;
public static class NhaDesktopTest {
    public static int Main(string[] args) {
        var folder = Environment.GetEnvironmentVariable("NHA_TEST_DIR");
        var mode = Environment.GetEnvironmentVariable("ELECTRON_RUN_AS_NODE") ?? "app";
        File.AppendAllText(Path.Combine(folder, "app.txt"), mode + ":" + string.Join(" ", args) + "\n");
        return 0;
    }
}
'@ -OutputAssembly $Exe -OutputType WindowsApplication
    Copy-Item (Join-Path $Root 'launch.ps1') $TempDir -Force
    Copy-Item (Join-Path $Root 'startup-runtime.ps1') $TempDir
    $env:NHA_TEST_DIR = $TempDir
    $env:NHA_TEST_TASK = $TaskName
    $env:ELECTRON_RUN_AS_NODE = '1'
    @'
param([switch]$Hidden, [switch]$Existing)
if ($Existing) {
    function Get-Process {
        [CmdletBinding()]param([string]$Name)
        [pscustomobject]@{ Path = (Join-Path $env:NHA_TEST_DIR 'desktop-test.exe') }
    }
}
. (Join-Path $PSScriptRoot 'launch.ps1') -Hidden:$Hidden -InstallDir $env:NHA_TEST_DIR `
    -NanoleafExe (Join-Path $env:NHA_TEST_DIR 'desktop-test.exe') -TaskName $env:NHA_TEST_TASK
'@ | Set-Content (Join-Path $TempDir 'run-launch.ps1') -Encoding ASCII
    Run-Launch
    Wait-AppTrace 1
    Run-Launch -Hidden
    Wait-AppTrace 2
    $Trace = [IO.File]::ReadAllText((Join-Path $TempDir 'app.txt'))
    Assert-Test ($Trace -eq "app:`napp:--hidden`n") 'Manual/tray launch or Node-mode removal failed'
    Assert-Test (@(Get-Content (Join-Path $TempDir 'checks.txt')).Count -eq 2) 'Checks were not run once per startup'
    Run-Launch -Existing
    Wait-AppTrace 3
    Assert-Test (@(Get-Content (Join-Path $TempDir 'checks.txt')).Count -eq 2) 'Existing app was checked again'

    Set-Content (Join-Path $TempDir 'repair.ps1') 'exit 3' -Encoding ASCII
    Run-Launch -ExpectedExit 1
    Assert-Test (@(Get-Content (Join-Path $TempDir 'app.txt')).Count -eq 3) 'App launched while updating'
    Set-Content (Join-Path $TempDir 'repair.ps1') 'Start-Sleep -Seconds 4' -Encoding ASCII
    $TimedOut = $false
    try { Invoke-NhaStartupCheck -TaskName $TaskName -TimeoutSeconds 1 | Out-Null }
    catch { $TimedOut = $_.Exception.Message -like '*timed out*' }
    Assert-Test $TimedOut 'Task timeout did not run'
    Write-Host 'Hidden creation flags, arguments, on-demand task, normal/tray startup, existing app, update deferral and timeout tests passed.'
}
finally {
    $env:ELECTRON_RUN_AS_NODE = $PreviousNodeMode
    $env:NHA_TEST_DIR = $PreviousTestDir
    Remove-Item Env:NHA_TEST_TASK -ErrorAction SilentlyContinue
    if ($TaskRegistered) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
