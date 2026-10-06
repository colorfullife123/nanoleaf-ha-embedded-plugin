$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$TempDir = Join-Path $env:TEMP ('nha-startup-repair-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir | Out-Null
$Asar = Join-Path $TempDir 'fake.asar'
$Commands = Join-Path $TempDir 'commands.txt'
$StatePath = Join-Path $TempDir 'repair-state.json'
$EnvNames = @('NHA_TEST_DIR', 'NHA_TEST_REPAIR', 'NHA_TEST_EXE', 'NHA_TEST_ASAR', 'NHA_TEST_RUNNING', 'NHA_TEST_UPDATER', 'NHA_TEST_CHANGE')
$PreviousEnvironment = @{}
foreach ($Name in $EnvNames) { $PreviousEnvironment[$Name] = [Environment]::GetEnvironmentVariable($Name) }
function Assert-Test([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Read-Trace {
    if (Test-Path $Commands) { return [IO.File]::ReadAllText($Commands) }
    return ''
}
function Run-Repair([int]$ExpectedExit = 0) {
    $Output = & "$PSHOME\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $TempDir 'run.ps1') 2>&1
    Assert-Test ($LASTEXITCODE -eq $ExpectedExit) "Repair failed: $Output (exit $LASTEXITCODE)"
}
try {
    $env:NHA_TEST_DIR = $TempDir
    $env:NHA_TEST_REPAIR = Join-Path $Root 'repair.ps1'
    $env:NHA_TEST_EXE = (Get-Command node.exe).Source
    $env:NHA_TEST_ASAR = $Asar
    $env:NHA_TEST_RUNNING = '0'
    $env:NHA_TEST_UPDATER = '0'
    $env:NHA_TEST_CHANGE = '0'
    Copy-Item (Join-Path $Root 'VERSION') $TempDir
    Set-Content (Join-Path $TempDir 'config.json') '{"token":"TEST_ONLY_SECRET"}' -Encoding ASCII
    $OriginalConfig = [IO.File]::ReadAllBytes((Join-Path $TempDir 'config.json'))
    @'
function Get-CimInstance {
    [CmdletBinding()]param([string]$ClassName)
    if ($env:NHA_TEST_UPDATER -eq '1') { [pscustomobject]@{ CommandLine = 'nanoleaf-updater --install' } }
}
function Get-Process {
    [CmdletBinding()]param([string]$Name)
    if ($env:NHA_TEST_RUNNING -eq '1') { [pscustomobject]@{ Id = 999999; Path = $env:NHA_TEST_EXE } }
}
function Stop-Process { throw 'Startup repair must not stop the app' }
function Start-Process { throw 'Startup repair must not launch the app' }
function Start-Sleep {
    param([int]$Seconds)
    if ($env:NHA_TEST_CHANGE -eq '1') { Set-Content $env:NHA_TEST_ASAR 'changing' -Encoding ASCII }
}
. $env:NHA_TEST_REPAIR -InstallDir $env:NHA_TEST_DIR -NanoleafExe $env:NHA_TEST_EXE -AsarPath $env:NHA_TEST_ASAR -UpdaterWaitSeconds 0
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
'@ | Set-Content (Join-Path $TempDir 'asar-patch.cjs') -Encoding ASCII

    Set-Content $Asar 'official' -Encoding ASCII
    Run-Repair
    Assert-Test ((Read-Trace) -eq "check`npatch`n") 'First startup did not restore a supported update'
    Run-Repair
    Assert-Test ((Read-Trace) -eq "check`npatch`n") 'Unchanged app spawned another helper'

    $env:NHA_TEST_UPDATER = '1'
    Run-Repair 3
    Assert-Test ((Read-Trace) -eq "check`npatch`n") 'Active updater was interrupted'
    $env:NHA_TEST_UPDATER = '0'
    Run-Repair
    Assert-Test ((Get-Content $StatePath -Raw | ConvertFrom-Json).status -eq 'active') 'Patched hash was not recognized after deferral'

    Set-Content $Asar 'official' -Encoding ASCII
    $env:NHA_TEST_CHANGE = '1'
    Run-Repair 3
    Assert-Test ((Read-Trace) -eq "check`npatch`n") 'Changing file was patched'
    $env:NHA_TEST_CHANGE = '0'

    Set-Content $Asar 'official' -Encoding ASCII
    $env:NHA_TEST_RUNNING = '1'
    Run-Repair
    Assert-Test ((Read-Trace) -eq "check`npatch`ncheck`n") 'Running app was patched or restarted'
    Assert-Test ((Get-Content $Asar -Raw).Trim() -eq 'official') 'Running app archive changed'
    $env:NHA_TEST_RUNNING = '0'
    Run-Repair
    Assert-Test ((Read-Trace) -eq "check`npatch`ncheck`ncheck`npatch`n") 'Closed app was not patched on next startup'

    Set-Content $Asar 'unknown-build' -Encoding ASCII
    $Known = Read-Trace
    Run-Repair
    Assert-Test ((Read-Trace) -eq ($Known + "check`n")) 'Unknown build was patched'
    Assert-Test ((Get-Content $StatePath -Raw | ConvertFrom-Json).status -eq 'unsupported') 'Unknown build was not recorded'
    $Known = Read-Trace
    Run-Repair
    Assert-Test ((Read-Trace) -eq $Known) 'Unchanged unknown build spawned another helper'
    Set-Content (Join-Path $TempDir 'VERSION') 'new-test-version' -Encoding ASCII
    Run-Repair
    Assert-Test ((Read-Trace) -eq ($Known + "check`n")) 'New plugin did not invalidate cache'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $TempDir 'config.json'))) -eq [Convert]::ToBase64String($OriginalConfig)) 'Configuration changed'
    Write-Host 'Startup repair, updater, changing files, cache, config and no stop/restart tests passed.'
}
finally {
    foreach ($Name in $EnvNames) { [Environment]::SetEnvironmentVariable($Name, $PreviousEnvironment[$Name]) }
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
