<#
.SYNOPSIS
Deploys CargoTools wrapper scripts to ~/.local/bin/ and ~/bin/.

.DESCRIPTION
Copies wrapper .ps1 files and generates .cmd shims for command-line invocation.
Validates that ~/.local/bin and ~/bin are on the user PATH.

.PARAMETER Force
Overwrite files even if they are unchanged.

.PARAMETER DryRun
Show what would be done without modifying files.

.PARAMETER Uninstall
Remove deployed wrappers.

.EXAMPLE
.\Install-Wrappers.ps1 -DryRun
Shows deployment plan without making changes.

.EXAMPLE
.\Install-Wrappers.ps1
Deploys all wrappers and .cmd shims.

.EXAMPLE
.\Install-Wrappers.ps1 -Uninstall
Removes all deployed wrappers.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force,
    [switch]$DryRun,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# --- Configuration ---

$localBin = Join-Path $env:USERPROFILE '.local\bin'
$userBin  = Join-Path $env:USERPROFILE 'bin'

# Module root (parent of tools/)
$moduleRoot = Split-Path -Parent $PSScriptRoot

# Wrapper definitions: TargetDir, FileName, SourceType (module|file), Source
# module = generate from template; file = copy from existing location
$wrappers = @(
    @{ Dir = $localBin; Name = 'cargo.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\cargo.ps1" },
    @{ Dir = $localBin; Name = 'cargo-route.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\cargo-route.ps1" },
    @{ Dir = $localBin; Name = 'cargo-wrapper.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\cargo-wrapper.ps1" },
    @{ Dir = $localBin; Name = 'cargo-wsl.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\cargo-wsl.ps1" },
    @{ Dir = $localBin; Name = 'cargo-docker.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\cargo-docker.ps1" },
    @{ Dir = $localBin; Name = 'cargo-macos.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\cargo-macos.ps1" },
    @{ Dir = $localBin; Name = 'maturin.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\maturin.ps1" },
    @{ Dir = $localBin; Name = 'rust-analyzer.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\rust-analyzer.ps1" },
    @{ Dir = $localBin; Name = 'rust-analyzer-wrapper.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\rust-analyzer-wrapper.ps1" },
    @{ Dir = $userBin;  Name = 'cargo-wrapper.ps1'; Type = 'file'; Source = "$moduleRoot\wrappers\cargo-wrapper.ps1" }
)

# .cmd shims to generate (for each .ps1 in ~/.local/bin)
$cmdShims = @(
    @{ Dir = $localBin; Name = 'cargo.cmd'; Ps1 = 'cargo.ps1' },
    @{ Dir = $localBin; Name = 'cargo-route.cmd'; Ps1 = 'cargo-route.ps1' },
    @{ Dir = $localBin; Name = 'cargo-wrapper.cmd'; Ps1 = 'cargo-wrapper.ps1' },
    @{ Dir = $localBin; Name = 'cargo-wsl.cmd'; Ps1 = 'cargo-wsl.ps1' },
    @{ Dir = $localBin; Name = 'cargo-docker.cmd'; Ps1 = 'cargo-docker.ps1' },
    @{ Dir = $localBin; Name = 'cargo-macos.cmd'; Ps1 = 'cargo-macos.ps1' },
    @{ Dir = $localBin; Name = 'rust-analyzer.cmd'; Ps1 = 'rust-analyzer.ps1' },
    @{ Dir = $localBin; Name = 'rust-analyzer-wrapper.cmd'; Ps1 = 'rust-analyzer-wrapper.ps1' }
)

# --- Helper Functions ---

function Test-PathIncludes {
    param([string]$Directory)
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $parts = $userPath -split ';' | Where-Object { $_ -and $_.Trim() }
    foreach ($part in $parts) {
        if ($part.TrimEnd('\') -eq $Directory.TrimEnd('\')) { return $true }
    }
    return $false
}

function Add-PathIfMissing {
    param([string]$Directory)
    if (Test-PathIncludes $Directory) { return $false }
    if ($DryRun) {
        Write-Host "  [DryRun] Would add to User PATH: $Directory" -ForegroundColor Yellow
        return $true
    }
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $newPath = if ($userPath) { "$userPath;$Directory" } else { $Directory }
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Host "  Added to User PATH: $Directory" -ForegroundColor Green
    return $true
}

function Install-WrapperScript {
    param(
        [string]$SourcePath,
        [string]$DestPath,
        [switch]$ForceOverwrite
    )

    if (-not (Test-Path $SourcePath)) {
        Write-Warning "Source not found: $SourcePath"
        return 'error'
    }

    # Ensure destination directory exists
    $destDir = Split-Path -Parent $DestPath
    if (-not (Test-Path $destDir)) {
        if ($DryRun) {
            Write-Host "  [DryRun] Would create directory: $destDir" -ForegroundColor Yellow
        } else {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
    }

    if (Test-Path $DestPath) {
        if (-not $ForceOverwrite) {
            # Compare content
            $sourceContent = Get-Content -Path $SourcePath -Raw -ErrorAction SilentlyContinue
            $destContent = Get-Content -Path $DestPath -Raw -ErrorAction SilentlyContinue
            if ($sourceContent -eq $destContent) {
                return 'skipped'
            }
        }
        if ($DryRun) {
            Write-Host "  [DryRun] Would update: $DestPath" -ForegroundColor Yellow
            return 'updated'
        }
        Copy-Item -Path $SourcePath -Destination $DestPath -Force
        return 'updated'
    }

    if ($DryRun) {
        Write-Host "  [DryRun] Would install: $DestPath" -ForegroundColor Yellow
        return 'installed'
    }
    Copy-Item -Path $SourcePath -Destination $DestPath -Force
    return 'installed'
}

function Install-CmdShim {
    param(
        [string]$CmdPath,
        [string]$Ps1Name
    )

    $content = @"
@echo off
setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%$Ps1Name" %*
exit /b !ERRORLEVEL!
"@

    $destDir = Split-Path -Parent $CmdPath
    if (-not (Test-Path $destDir)) {
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
    }

    if (Test-Path $CmdPath) {
        if (-not $Force) {
            $existing = Get-Content -Path $CmdPath -Raw -ErrorAction SilentlyContinue
            if ($existing.TrimEnd() -eq $content.TrimEnd()) {
                return 'skipped'
            }
        }
        if ($DryRun) {
            Write-Host "  [DryRun] Would update shim: $CmdPath" -ForegroundColor Yellow
            return 'updated'
        }
        Set-Content -Path $CmdPath -Value $content -NoNewline -Encoding ASCII
        return 'updated'
    }

    if ($DryRun) {
        Write-Host "  [DryRun] Would create shim: $CmdPath" -ForegroundColor Yellow
        return 'installed'
    }
    Set-Content -Path $CmdPath -Value $content -NoNewline -Encoding ASCII
    return 'installed'
}

function Remove-WrapperFiles {
    $removed = 0
    $allFiles = @()

    foreach ($w in $wrappers) {
        $allFiles += Join-Path $w.Dir $w.Name
    }
    foreach ($s in $cmdShims) {
        $allFiles += Join-Path $s.Dir $s.Name
    }

    foreach ($file in $allFiles) {
        if (Test-Path $file) {
            if ($DryRun) {
                Write-Host "  [DryRun] Would remove: $file" -ForegroundColor Yellow
                $removed++
            } else {
                Remove-Item -Path $file -Force
                Write-Host "  Removed: $file" -ForegroundColor Red
                $removed++
            }
        }
    }
    return $removed
}

function Show-InstallSummary {
    param(
        [int]$Installed,
        [int]$Updated,
        [int]$Skipped,
        [int]$Errors
    )

    Write-Host ''
    Write-Host '--- Install Summary ---' -ForegroundColor Cyan
    if ($Installed -gt 0) { Write-Host "  Installed: $Installed" -ForegroundColor Green }
    if ($Updated -gt 0)   { Write-Host "  Updated:   $Updated" -ForegroundColor Yellow }
    if ($Skipped -gt 0)   { Write-Host "  Skipped:   $Skipped (unchanged)" -ForegroundColor DarkGray }
    if ($Errors -gt 0)    { Write-Host "  Errors:    $Errors" -ForegroundColor Red }

    $total = $Installed + $Updated + $Skipped + $Errors
    Write-Host "  Total:     $total files" -ForegroundColor Cyan
}

# --- Main ---

Write-Host "CargoTools Wrapper Installer v0.6.0" -ForegroundColor Cyan
Write-Host "Module: $moduleRoot" -ForegroundColor DarkGray

# Check that wrappers/ source directory exists
$wrappersDir = Join-Path $moduleRoot 'wrappers'
if (-not (Test-Path $wrappersDir)) {
    Write-Error "Wrappers source directory not found: $wrappersDir. Run this script from the CargoTools module directory."
    exit 1
}

if ($Uninstall) {
    Write-Host ''
    Write-Host 'Removing deployed wrappers...' -ForegroundColor Yellow
    $removed = Remove-WrapperFiles
    if ($DryRun) {
        Write-Host "Would remove $removed file(s)." -ForegroundColor Yellow
    } else {
        Write-Host "Removed $removed file(s)." -ForegroundColor Green
    }
    exit 0
}

Write-Host ''

$installed = 0
$updated = 0
$skipped = 0
$errors = 0

# Deploy .ps1 wrapper scripts
Write-Host 'Deploying wrapper scripts...' -ForegroundColor White
foreach ($w in $wrappers) {
    $destPath = Join-Path $w.Dir $w.Name
    $result = Install-WrapperScript -SourcePath $w.Source -DestPath $destPath -ForceOverwrite:$Force
    switch ($result) {
        'installed' { $installed++; if (-not $DryRun) { Write-Host "  Installed: $destPath" -ForegroundColor Green } }
        'updated'   { $updated++;   if (-not $DryRun) { Write-Host "  Updated:   $destPath" -ForegroundColor Yellow } }
        'skipped'   { $skipped++ }
        'error'     { $errors++ }
    }
}

# Deploy .cmd shims
Write-Host 'Deploying .cmd shims...' -ForegroundColor White
foreach ($s in $cmdShims) {
    $cmdPath = Join-Path $s.Dir $s.Name
    $result = Install-CmdShim -CmdPath $cmdPath -Ps1Name $s.Ps1
    switch ($result) {
        'installed' { $installed++; if (-not $DryRun) { Write-Host "  Installed: $cmdPath" -ForegroundColor Green } }
        'updated'   { $updated++;   if (-not $DryRun) { Write-Host "  Updated:   $cmdPath" -ForegroundColor Yellow } }
        'skipped'   { $skipped++ }
    }
}

# Validate PATH
Write-Host ''
Write-Host 'Checking PATH...' -ForegroundColor White
$pathChanged = $false
foreach ($dir in @($localBin, $userBin)) {
    if (Test-PathIncludes $dir) {
        Write-Host "  OK: $dir" -ForegroundColor DarkGreen
    } else {
        $added = Add-PathIfMissing $dir
        if ($added) { $pathChanged = $true }
    }
}
if ($pathChanged -and -not $DryRun) {
    Write-Host '  NOTE: Restart your terminal for PATH changes to take effect.' -ForegroundColor Yellow
}

Show-InstallSummary -Installed $installed -Updated $updated -Skipped $skipped -Errors $errors
