<#
.SYNOPSIS
Maturin wrapper with automatic venv detection and sccache support.
.DESCRIPTION
Transparently handles Python venv activation, sccache compatibility, and
delegates to maturin.exe. All arguments pass through unchanged.
.NOTES
Place alongside maturin.exe in PATH. Requires CargoTools module for sccache management.
#>
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

# Locate maturin.exe in the same directory as this script
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$maturinExe = Join-Path $scriptDir 'maturin.exe'
if (-not (Test-Path $maturinExe)) {
    Write-Error "maturin.exe not found in $scriptDir"
    exit 1
}

$args = if ($Arguments) { @($Arguments) } else { @() }
$noSccache = $false

# Parse wrapper-only flags
$passThrough = @()
foreach ($arg in $args) {
    if ($arg -eq '--no-sccache') {
        $noSccache = $true
    } else {
        $passThrough += $arg
    }
}

# Detect and activate Python venv
$venvPath = $null
if ($env:VIRTUAL_ENV) {
    $venvPath = $env:VIRTUAL_ENV
} else {
    $candidates = @('.venv', 'venv', '.env')
    foreach ($dir in $candidates) {
        $candidate = Join-Path (Get-Location).Path $dir
        if (Test-Path (Join-Path $candidate 'Scripts\python.exe')) {
            $venvPath = $candidate
            break
        }
        if (Test-Path (Join-Path $candidate 'bin/python')) {
            $venvPath = $candidate
            break
        }
    }
}

$activatedVenv = $false
if ($venvPath -and -not $env:VIRTUAL_ENV) {
    $activateScript = Join-Path $venvPath 'Scripts\Activate.ps1'
    if (Test-Path $activateScript) {
        . $activateScript
        $activatedVenv = $true
    }
}

# sccache setup (maturin respects RUSTC_WRAPPER)
$savedRustcWrapper = $env:RUSTC_WRAPPER
if ($noSccache) {
    if (Test-Path Env:RUSTC_WRAPPER) { Remove-Item Env:RUSTC_WRAPPER }
} else {
    # Ensure sccache is set up if CargoTools is available
    $cargoTools = Get-Module CargoTools -ErrorAction SilentlyContinue
    if (-not $cargoTools) {
        $moduleCandidates = @(
            $env:CARGOTOOLS_MANIFEST,
            (Join-Path $env:LOCALAPPDATA 'PowerShell\Modules\CargoTools\CargoTools.psd1'),
            (Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\Modules\CargoTools\CargoTools.psd1')
        ) | Where-Object { $_ } | Select-Object -Unique

        foreach ($modulePath in $moduleCandidates) {
            if (-not (Test-Path $modulePath)) { continue }
            $cargoTools = Import-Module $modulePath -PassThru -ErrorAction SilentlyContinue
            if ($cargoTools) { break }
        }

        if (-not $cargoTools) {
            $cargoTools = Import-Module CargoTools -PassThru -ErrorAction SilentlyContinue
        }
    }
    if ($cargoTools) {
        try { Start-SccacheServer | Out-Null } catch {}
    }
    if (-not $env:RUSTC_WRAPPER) {
        $sccacheCmd = Get-Command sccache -ErrorAction SilentlyContinue
        if ($sccacheCmd) { $env:RUSTC_WRAPPER = 'sccache' }
    }
}

try {
    & $maturinExe @passThrough
    exit $LASTEXITCODE
} finally {
    # Restore RUSTC_WRAPPER
    if ($null -ne $savedRustcWrapper) {
        $env:RUSTC_WRAPPER = $savedRustcWrapper
    } elseif ($noSccache -and (Test-Path Env:RUSTC_WRAPPER)) {
        Remove-Item Env:RUSTC_WRAPPER -ErrorAction SilentlyContinue
    }
}
