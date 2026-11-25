$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\runtime.ps1')
$TempDir = Join-Path $env:TEMP ('nha official 303 ' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir | Out-Null
$PreviousProgress = $ProgressPreference
try {
    $ProgressPreference = 'SilentlyContinue'
    $Installer = Join-Path $TempDir 'desktop-3.0.3.exe'
    # URL is the redirect target of Nanoleaf's official Windows download link.
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -OutFile $Installer `
        -Uri 'https://desktop-app-prod-3.s3.us-west-2.amazonaws.com/Nanoleaf%20Desktop%20Setup%203.0.3.exe'
    $ExpectedHash = '3e6f2133869acd7c0a35c93fc4db69553c55b0882b6648b4dd3817b0d8546dcc'
    if ((Get-FileHash $Installer -Algorithm SHA256).Hash -ne $ExpectedHash) { throw 'Official installer hash changed.' }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Installer
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch 'Nanoleaf') {
        throw "Unexpected official installer signature: $($Signature.Status)"
    }

    $AppDir = Join-Path $TempDir 'desktop'
    $SevenZip = (Get-Command 7z.exe -ErrorAction Stop).Source
    & $SevenZip x '-t7z' '-y' '-bso0' '-bsp0' "-o$AppDir" $Installer | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Installer extraction failed: $LASTEXITCODE" }
    $Exe = Join-Path $AppDir 'Nanoleaf Desktop.exe'
    $Asar = Join-Path $AppDir 'resources\app.asar'
    $Patcher = Join-Path $TempDir 'asar-patch.cjs'
    Copy-Item (Join-Path $PSScriptRoot '..\asar-patch.cjs') $Patcher
    $OriginalHash = (Get-FileHash $Asar -Algorithm SHA256).Hash
    if ($OriginalHash -ne 'ecf561d75677c858a2a5736a476ee5a1459aa9aee72a3fff4f5ac055740d2119') {
        throw 'Unexpected Desktop 3.0.3 archive.'
    }
    foreach ($Command in @(@('check', 2), @('patch', 0), @('check', 0), @('patch', 0), @('restore', 0))) {
        # Execute the real Desktop Electron binary in Node mode, using the
        # same helper and archive paths as installation. No UI is started.
        $Result = Invoke-NhaPatcher -Exe $Exe -Patcher $Patcher -Command $Command[0] -Asar $Asar
        if ($Result.ExitCode -ne $Command[1]) {
            throw "Official Electron helper failed ($($Command[0])): $($Result.Stdout) $($Result.Stderr)"
        }
    }
    $State = Get-Content (Join-Path $TempDir 'patch-state.json') -Raw | ConvertFrom-Json
    if ($State.desktopVersion -ne '3.0.3') { throw 'Patch state version mismatch.' }
    if ((Get-FileHash $Asar -Algorithm SHA256).Hash -ne $OriginalHash) { throw 'Restore was not byte-exact.' }
    Write-Host 'Signed official Desktop 3.0.3: real Electron helper check/patch/idempotence/restore passed.'
}
finally {
    $ProgressPreference = $PreviousProgress
    Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}
$global:LASTEXITCODE = 0
