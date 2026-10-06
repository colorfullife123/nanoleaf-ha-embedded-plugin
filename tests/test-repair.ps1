$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$TempDir = Join-Path $env:TEMP ('nha-auto-repair-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir | Out-Null
$Asar = Join-Path $TempDir 'fake.asar'
$Commands = Join-Path $TempDir 'commands.txt'
$Actions = Join-Path $TempDir 'actions.txt'
$StatePath = Join-Path $TempDir 'repair-state.json'
$Node = (Get-Command node.exe).Source
$EnvNames = @('NHA_TEST_DIR', 'NHA_TEST_REPAIR', 'NHA_TEST_EXE', 'NHA_TEST_ASAR', 'NHA_TEST_RUNNING', 'NHA_TEST_UPDATER', 'NHA_TEST_ACTIONS')
$PreviousEnvironment = @{}
foreach ($Name in $EnvNames) { $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name) }

function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Read-Trace([string]$FilePath) {
    if (Test-Path $FilePath) { return [IO.File]::ReadAllText($FilePath) }
    return ''
}
function Run-Repair {
    $Output = & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $TempDir 'run.ps1') 2>&1
    Assert-Test ($LASTEXITCODE -eq 0) "Repair failed: $Output"
}
function Age-PendingState {
    $State = Get-Content $StatePath -Raw | ConvertFrom-Json
    $State.observedAtUtc = [DateTime]::UtcNow.AddSeconds(-90).ToString('o')
    $State | ConvertTo-Json | Set-Content $StatePath -Encoding UTF8
}

try {
    $env:NHA_TEST_DIR = $TempDir
    $env:NHA_TEST_REPAIR = Join-Path $Root 'repair.ps1'
    $env:NHA_TEST_EXE = $Node
    $env:NHA_TEST_ASAR = $Asar
    $env:NHA_TEST_RUNNING = '1'
    $env:NHA_TEST_UPDATER = '0'
    $env:NHA_TEST_ACTIONS = $Actions
    Copy-Item (Join-Path $Root 'VERSION') $TempDir
    Set-Content (Join-Path $TempDir 'config.json') '{"token":"TEST_ONLY_SECRET"}' -Encoding ASCII
    $OriginalConfig = [IO.File]::ReadAllBytes((Join-Path $TempDir 'config.json'))

    # Mock the desktop/update processes so tests never close or launch an app.
    @'
function Get-CimInstance {
    [CmdletBinding()]param([string]$ClassName)
    if ($env:NHA_TEST_UPDATER -eq '1') { [pscustomobject]@{ CommandLine = 'nanoleaf-updater --install' } }
}
function Get-Process {
    [CmdletBinding()]param([string]$Name)
    if ($env:NHA_TEST_RUNNING -eq '1') { [pscustomobject]@{ Id = 999999; Path = $env:NHA_TEST_EXE } }
}
function Stop-Process {
    [CmdletBinding()]param([int]$Id, [switch]$Force)
    [IO.File]::AppendAllText($env:NHA_TEST_ACTIONS, "stop`n")
}
function Start-Process {
    [CmdletBinding()]param([string]$FilePath, $ArgumentList)
    [IO.File]::AppendAllText($env:NHA_TEST_ACTIONS, "start:$ArgumentList`n")
}
. $env:NHA_TEST_REPAIR -InstallDir $env:NHA_TEST_DIR -NanoleafExe $env:NHA_TEST_EXE -AsarPath $env:NHA_TEST_ASAR
'@ | Set-Content (Join-Path $TempDir 'run.ps1') -Encoding ASCII

    @'
const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
const [command, asar] = process.argv.slice(2);
fs.appendFileSync(path.join(__dirname, "commands.txt"), command + "\n");
const value = fs.readFileSync(asar, "utf8").trim();
if (command === "check") process.exit(value === "patched" ? 0 : value === "official" ? 2 : 3);
if (command !== "patch" || value !== "official") process.exit(1);
fs.writeFileSync(asar, "patched");
fs.writeFileSync(path.join(__dirname, "patch-state.json"), JSON.stringify({active:true, afterHash:crypto.createHash("sha256").update("patched").digest("hex")}));
console.log("mock patch complete");
'@ | Set-Content (Join-Path $TempDir 'asar-patch.cjs') -Encoding ASCII

    Set-Content $Asar 'official' -Encoding ASCII
    Run-Repair
    Assert-Test (-not (Test-Path $Commands)) 'Unstable archive was checked prematurely'
    Assert-Test ((Get-Content $StatePath -Raw | ConvertFrom-Json).status -eq 'pending') 'Missing pending state'
    Age-PendingState
    Run-Repair
    Assert-Test ((Read-Trace $Commands) -eq "check`npatch`n") 'Stable official build was not repaired'
    Assert-Test ((Read-Trace $Actions) -eq "stop`nstart:--hidden`n") 'Running app was not restarted exactly once hidden'
    Assert-Test ((Get-Content $StatePath -Raw | ConvertFrom-Json).status -eq 'active') 'Missing active state'

    $KnownCommands = Read-Trace $Commands
    $KnownActions = Read-Trace $Actions
    Run-Repair
    $env:NHA_TEST_RUNNING = '0'
    Run-Repair
    Assert-Test ((Read-Trace $Commands) -eq $KnownCommands) 'Unchanged archive spawned another helper'
    Assert-Test ((Read-Trace $Actions) -eq $KnownActions) 'Normal tray exit resurrected the app'

    Set-Content $Asar 'official' -Encoding ASCII
    $env:NHA_TEST_UPDATER = '1'
    Run-Repair
    Assert-Test ((Read-Trace $Commands) -eq $KnownCommands) 'Active updater was interrupted'
    $env:NHA_TEST_UPDATER = '0'
    Age-PendingState
    Run-Repair
    Assert-Test ((Read-Trace $Commands) -eq ($KnownCommands + "check`npatch`n")) 'Closed app archive was not repaired'
    Assert-Test ((Read-Trace $Actions) -eq $KnownActions) 'Repair launched an app that was already closed'
    $KnownCommands = Read-Trace $Commands

    Set-Content $Asar 'unknown-build' -Encoding ASCII
    Run-Repair
    Age-PendingState
    Run-Repair
    Assert-Test ((Get-Content $StatePath -Raw | ConvertFrom-Json).status -eq 'unsupported') 'Unknown build was not recorded'
    Assert-Test ((Read-Trace $Commands) -eq ($KnownCommands + "check`n")) 'Unknown build was patched'
    Assert-Test ((Read-Trace $Actions) -eq $KnownActions) 'Unknown build caused a restart'
    $KnownCommands = Read-Trace $Commands
    Run-Repair
    Assert-Test ((Read-Trace $Commands) -eq $KnownCommands) 'Unknown unchanged build was checked repeatedly'
    Set-Content (Join-Path $TempDir 'VERSION') 'new-test-version' -Encoding ASCII
    Run-Repair
    Age-PendingState
    Run-Repair
    Assert-Test ((Read-Trace $Commands) -eq ($KnownCommands + "check`n")) 'New plugin version did not invalidate incompatible cache'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $TempDir 'config.json'))) -eq [Convert]::ToBase64String($OriginalConfig)) 'Repair changed configuration'

    $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)
    Assert-Test ([Xml.XmlConvert]::ToTimeSpan($Trigger.Repetition.Interval).TotalSeconds -eq 60) 'Incorrect interval'
    Assert-Test (-not $Trigger.Repetition.Duration) 'Repetition has a duration limit'
    Write-Host 'Auto-repair stability, updater, restart, user exit, unknown version, cache, config and trigger tests passed.'
}
finally {
    foreach ($Name in $EnvNames) { [Environment]::SetEnvironmentVariable($Name, $PreviousEnvironment[$Name]) }
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
