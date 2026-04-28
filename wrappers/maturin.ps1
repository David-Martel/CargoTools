#Requires -Version 5.1
# maturin.ps1 — CargoTools v0.9.0 maturin wrapper
# Preserves venv detection. Adds wrapper flags + sccache integration.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$ArgumentList
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'maturin'

if ($ctx.HelpRequested)    { Show-WrapperHelp -WrapperName 'maturin' -RemainingArgs $ctx.PassThrough; exit 0 }
if ($ctx.VersionRequested) { Show-WrapperVersion -WrapperName 'maturin'; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'maturin' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

# Locate maturin.exe alongside this wrapper script
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$maturinExe = Join-Path $scriptDir 'maturin.exe'
if (-not (Test-Path $maturinExe)) {
    # Fallback: maturin on PATH
    $maturinCmd = Get-Command maturin.exe -ErrorAction SilentlyContinue
    if ($maturinCmd) {
        $maturinExe = $maturinCmd.Source
    } else {
        Write-LlmEvent -Phase diagnostic -Level error -Code RUSTUP_NOT_FOUND `
            -Detail 'maturin.exe not found alongside wrapper or on PATH' `
            -Recovery 'Install maturin: pip install maturin' -EmitLlm:$ctx.LlmMode
        Write-Host '[ERROR] maturin.exe not found.' -ForegroundColor Red
        exit 3
    }
}

# Parse --no-sccache from the pass-through args
$noSccache  = $false
$finalArgs  = [System.Collections.Generic.List[string]]::new()
foreach ($a in $ctx.PassThrough) {
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
        # Non-fatal for maturin — proceed without sccache
    } else {
        try { Start-SccacheServer | Out-Null } catch {}
    }
    if (-not $env:RUSTC_WRAPPER) {
        $sccacheCmd = Get-Command sccache -ErrorAction SilentlyContinue
        if ($sccacheCmd) { $env:RUSTC_WRAPPER = 'sccache' }
    }
}

Write-LlmEvent -Phase start -Wrapper maturin -Args $finalArgs.ToArray() -EmitLlm:$ctx.LlmMode
$start = Get-Date

try {
    & $maturinExe @($finalArgs.ToArray())
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
