$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\runtime.ps1')
$TempDir = Join-Path $env:TEMP ('nha-runtime-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $TempDir | Out-Null
try {
    # A GUI executable exercises the exact class of process that caused null
    # exit codes when launched through Windows PowerShell's native invocation.
    $Exe = Join-Path $TempDir 'gui-helper.exe'
    Add-Type -TypeDefinition @'
using System;
public static class NhaGuiHelper {
    public static int Main(string[] args) {
        Console.WriteLine("output-" + args[1]);
        Console.Error.WriteLine("stderr-" + args[1]);
        if (Environment.GetEnvironmentVariable("ELECTRON_RUN_AS_NODE") != "1") return 99;
        if (args[0].Contains("timeout")) System.Threading.Thread.Sleep(5000);
        return args[1] == "check" ? 2 : args[1] == "restore" ? 4 : 0;
    }
}
'@ -OutputAssembly $Exe -OutputType WindowsApplication
    $Patcher = Join-Path $TempDir 'helper with spaces.cjs'
    $Asar = Join-Path $TempDir 'archive with spaces.asar'
    Set-Content -LiteralPath $Patcher -Value 'test helper'
    Set-Content -LiteralPath $Asar -Value 'test archive'
    $Previous = $env:ELECTRON_RUN_AS_NODE
    foreach ($Item in @(@('check', 2), @('patch', 0), @('restore', 4))) {
        $Result = Invoke-NhaPatcher -Exe $Exe -Patcher $Patcher -Command $Item[0] -Asar $Asar
        if ($Result.ExitCode -ne $Item[1]) { throw "Unexpected exit code: $($Result.ExitCode)" }
        if (-not $Result.Stdout.Contains('output-' + $Item[0])) { throw 'stdout was lost' }
        if (-not $Result.Stderr.Contains('stderr-' + $Item[0])) { throw 'stderr was lost' }
    }
    if ($env:ELECTRON_RUN_AS_NODE -ne $Previous) { throw 'Parent environment was changed' }
    $TimeoutPatcher = Join-Path $TempDir 'timeout.cjs'
    Set-Content -LiteralPath $TimeoutPatcher -Value 'timeout'
    $TimedOut = $false
    try {
        Invoke-NhaPatcher -Exe $Exe -Patcher $TimeoutPatcher -Command patch -Asar $Asar -TimeoutSeconds 1 | Out-Null
    }
    catch {
        if ($_.Exception.Message -notlike '*timed out*') { throw }
        $TimedOut = $true
    }
    if (-not $TimedOut) { throw 'Timeout guard did not run' }
    Write-Host 'GUI helper exit codes, output, quoting, environment and timeout tests passed.'
}
finally { Remove-Item -LiteralPath $TempDir -Recurse -Force -ErrorAction SilentlyContinue }
