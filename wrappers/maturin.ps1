#Requires -Version 5.1
# maturin.ps1 - CargoTools v0.9.0 maturin wrapper
# Preserves venv detection. Adds wrapper flags + sccache integration.
$ErrorActionPreference = 'Stop'
[string[]]$ArgumentList = @($args)

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'maturin'
$passThroughArgs = [string[]]@($ctx.PassThrough)

function Resolve-MaturinExe {
    # Locate maturin.exe alongside this wrapper script.
    $scriptDir  = $PSScriptRoot
    $candidate = Join-Path $scriptDir 'maturin.exe'
    if (Test-Path $candidate) { return $candidate }

    # Fallback to maturin.exe on PATH. Use the executable name to avoid
    # recursively resolving this PowerShell wrapper for native help/version.
    $maturinCmd = Get-Command maturin.exe -ErrorAction SilentlyContinue
    if ($maturinCmd) { return $maturinCmd.Source }

    Write-LlmEvent -Phase diagnostic -Level error -Code MATURIN_NOT_FOUND `
        -Detail 'maturin.exe not found alongside wrapper or on PATH' `
        -Recovery 'Install maturin: pip install maturin' -EmitLlm:$ctx.LlmMode
    Write-Host '[ERROR] maturin.exe not found.' -ForegroundColor Red
    exit 3
}

$wrapperHelpRequested = $ArgumentList -contains '--wrapper-help'
if ($wrapperHelpRequested) { Show-WrapperHelp -WrapperName 'maturin' -RemainingArgs $passThroughArgs; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'maturin' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

$maturinExe = Resolve-MaturinExe

if ($ctx.HelpRequested -or $ctx.VersionRequested) {
    $nativeArgs = [System.Collections.Generic.List[string]]::new()
    foreach ($a in $ArgumentList) {
        if ($a -eq '--llm' -or $a -eq '--json-output') { continue }
        $nativeArgs.Add($a)
    }
    & $maturinExe @($nativeArgs.ToArray())
    exit $LASTEXITCODE
}

# Parse --no-sccache from the pass-through args
$noSccache  = $false
$finalArgs  = [System.Collections.Generic.List[string]]::new()
foreach ($a in $passThroughArgs) {
    if ($a -eq '--no-sccache') { $noSccache = $true } else { $finalArgs.Add($a) }
}

# Detect and activate Python venv
$venvPath = $null
if ($env:VIRTUAL_ENV) {
    $venvPath = $env:VIRTUAL_ENV
} else {
    foreach ($dir in @('.venv', 'venv', '.env')) {
        $candidate = Join-Path (Get-Location).Path $dir
        if (Test-Path (Join-Path $candidate 'Scripts\python.exe')) { $venvPath = $candidate; break }
        if (Test-Path (Join-Path $candidate 'bin/python'))         { $venvPath = $candidate; break }
    }
}
if ($venvPath -and -not $env:VIRTUAL_ENV) {
    $activateScript = Join-Path $venvPath 'Scripts\Activate.ps1'
    if (Test-Path $activateScript) { . $activateScript }
}

# sccache setup
$savedRustcWrapper = $env:RUSTC_WRAPPER
if ($noSccache) {
    if (Test-Path Env:RUSTC_WRAPPER) { Remove-Item Env:RUSTC_WRAPPER }
} else {
    if (-not (Import-CargoToolsResilient -EmitLlm:$ctx.LlmMode)) {
        # Non-fatal for maturin; proceed without sccache.
    } else {
        try {
            Start-SccacheServer | Out-Null
        } catch {
            Write-Verbose "Unable to start sccache for maturin: $($_.Exception.Message)"
        }
    }
    if (-not $env:RUSTC_WRAPPER) {
        $sccacheCmd = Get-Command sccache -ErrorAction SilentlyContinue
        if ($sccacheCmd) { $env:RUSTC_WRAPPER = 'sccache' }
    }
}

$finalMaturinArgs = [string[]]$finalArgs.ToArray()
Write-LlmEvent -Phase start -Wrapper maturin -Args $finalMaturinArgs -EmitLlm:$ctx.LlmMode
$start = Get-Date

try {
    & $maturinExe @finalMaturinArgs
    $code = $LASTEXITCODE
} finally {
    if ($null -ne $savedRustcWrapper) {
        $env:RUSTC_WRAPPER = $savedRustcWrapper
    } elseif ($noSccache -and (Test-Path Env:RUSTC_WRAPPER)) {
        Remove-Item Env:RUSTC_WRAPPER -ErrorAction SilentlyContinue
    }
}

Write-LlmEvent -Phase end -Wrapper maturin -ExitCode $code `
    -DurationMs ([int]((Get-Date) - $start).TotalMilliseconds) -EmitLlm:$ctx.LlmMode
exit $code
