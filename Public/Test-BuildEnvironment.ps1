function Test-BuildEnvironment {
    <#
    .SYNOPSIS
    Diagnoses the Rust build environment and reports optimization opportunities.
    .DESCRIPTION
    Checks for Dev Drive (ReFS), Windows Defender exclusions, tool availability,
    cache health, and configuration issues that affect build performance.
    .EXAMPLE
    Test-BuildEnvironment
    .EXAMPLE
    Test-BuildEnvironment -Detailed
    #>
    [CmdletBinding()]
    param(
        [switch]$Detailed
    )

    $results = [ordered]@{}
    $issues = @()
    $optimizations = @()

    # --- Toolchain ---
    $rustupPath = Get-RustupPath
    $hasRustup = Test-Path $rustupPath
    $results['Rustup'] = if ($hasRustup) {
        $ver = & $rustupPath --version 2>$null
        if ($ver) { $ver.Trim() } else { 'installed' }
    } else { 'NOT FOUND' }

    if ($hasRustup) {
        $toolchain = & $rustupPath show active-toolchain 2>$null
        $activeToolchain = if ($toolchain) { ($toolchain -split '\s')[0] } else { 'unknown' }
        $results['ActiveToolchain'] = $activeToolchain
        $selectedToolchain = Resolve-CargoToolchain -RustupPath $rustupPath
        $selectedHealth = Test-RustToolchainHealth -Toolchain $selectedToolchain -RustupPath $rustupPath
        $results['SelectedToolchain'] = if ($selectedHealth.Healthy) {
            "$selectedToolchain (healthy)"
        } else {
            "$selectedToolchain (unhealthy)"
        }
        if (-not $selectedHealth.Healthy) {
            $issues += "Selected Rust toolchain '$selectedToolchain' failed health probe: $($selectedHealth.Error)"
        } elseif ($activeToolchain -ne 'unknown' -and $selectedToolchain -ne $activeToolchain) {
            $activeHealth = Test-RustToolchainHealth -Toolchain $activeToolchain -RustupPath $rustupPath
            if (-not $activeHealth.Healthy) {
                $issues += "Active Rust toolchain '$activeToolchain' is unhealthy; CargoTools will use '$selectedToolchain'"
            }
        }
    }

    # --- MSVC / Visual Studio ---
    $msvcInfo = Get-MsvcInfo
    if ($msvcInfo) {
        $vsText = if ($msvcInfo.VsDisplayName) { $msvcInfo.VsDisplayName } else { Split-Path $msvcInfo.VsPath -Leaf }
        $results['VisualStudio'] = "$vsText ($($msvcInfo.VsPath))"
        $results['MSVC'] = "$($msvcInfo.MsvcVersion) ($($msvcInfo.LinkExePath))"
    } else {
        $results['VisualStudio'] = 'NOT FOUND'
        $issues += 'Visual Studio C++ Build Tools not found'
    }

    # --- Linker ---
    $lldPath = Resolve-LldLinker
    if ($lldPath) {
        $lldType = if ($lldPath -match '[/\\]rust-lld') { 'bundled rust-lld' } else { 'external lld-link' }
        $results['Linker'] = "$lldType ($lldPath)"
    } else {
        $results['Linker'] = 'link.exe (default — consider installing LLVM lld for faster linking)'
        $optimizations += 'Install LLVM (lld-link.exe) or use bundled rust-lld for 2-5x faster linking'
    }

    # --- sccache ---
    $sccacheCmd = Resolve-Sccache
    $results['Sccache'] = if ($sccacheCmd) {
        $sccHealth = Test-SccacheHealth
        if ($sccHealth.Healthy) {
            "healthy (${sccacheCmd}, $($sccHealth.MemoryMB)MB)"
        } elseif ($sccHealth.Running) {
            "running but unhealthy: $($sccHealth.Error)"
        } else {
            'installed but not running'
        }
    } else {
        'NOT FOUND'
        $issues += 'sccache not installed — builds will not be cached'
    }

    # --- nextest ---
    $nextestPath = Find-CargoCommandPath -Name 'cargo-nextest'
    $results['Nextest'] = if ($nextestPath) { "installed ($nextestPath)" } else { 'not installed' }

    # --- Ninja (for CMake deps) ---
    $ninjaPath = Find-CargoCommandPath -Name 'ninja'
    $results['Ninja'] = if ($ninjaPath) { "installed ($ninjaPath)" } else {
        'not installed'
        $optimizations += 'Install Ninja for faster CMake-based native dependency builds'
    }

    # --- Cache directory: Dev Drive / ReFS check ---
    $cacheRoot = Resolve-CacheRoot
    $results['CacheRoot'] = $cacheRoot
    $results['TargetMode'] = Get-CargoTargetMode
    if ($cacheRoot -match '^([A-Z]):') {
        $driveLetter = $Matches[1]
        try {
            $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
            if ($vol) {
                $results['CacheFileSystem'] = $vol.FileSystemType
                if ($vol.FileSystemType -eq 'ReFS') {
                    $results['DevDrive'] = 'Yes (ReFS detected)'
                } else {
                    $results['DevDrive'] = 'No (NTFS)'
                    $optimizations += ("Cache drive {0}: is NTFS - consider a Dev Drive (ReFS) for 10-25% faster builds" -f $driveLetter)
                }
            }
        } catch {}
    }

    # --- Windows Defender exclusions ---
    if (Test-IsWindows) {
        try {
            $prefs = Get-MpPreference -ErrorAction SilentlyContinue
            if ($prefs) {
                $exclusions = @($prefs.ExclusionPath)
                $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $cacheRoot 'cargo-home' }
                $targetDir = $env:CARGO_TARGET_DIR

                $cacheExcluded = $exclusions | Where-Object { $_ -eq $cacheRoot -or $_ -like "$cacheRoot*" }
                $cargoExcluded = $exclusions | Where-Object { $_ -eq $cargoHome -or $_ -like "$cargoHome*" }
                $targetExcluded = if ($targetDir) { $exclusions | Where-Object { $_ -eq $targetDir -or $_ -like "$targetDir*" } } else { @() }

                $defenderStatus = @()
                if ($cacheExcluded) { $defenderStatus += 'cache' }
                if ($cargoExcluded) { $defenderStatus += 'cargo-home' }
                if ($targetExcluded) { $defenderStatus += 'target' }

                if ($targetDir -and $defenderStatus.Count -eq 3) {
                    $results['DefenderExclusions'] = 'All key dirs excluded'
                } elseif ($defenderStatus.Count -gt 0) {
                    $excludedText = ($defenderStatus -join ', ')
                    $results['DefenderExclusions'] = "Partial ($excludedText excluded)"
                    $optimizations += 'Add Defender exclusions for all Rust build directories to reduce I/O overhead'
                } else {
                    $results['DefenderExclusions'] = if ($targetDir) { 'None — significant I/O overhead on builds' } else { 'Cache dirs not excluded; project-local target dirs vary by repo' }
                    if ($targetDir) {
                        $issues += "No Defender exclusions for Rust directories. Add exclusions: $cacheRoot, $cargoHome, $targetDir"
                    } else {
                        $issues += "No Defender exclusions for shared Rust cache directories. Add exclusions: $cacheRoot, $cargoHome"
                    }
                }
            }
        } catch {
            $results['DefenderExclusions'] = 'Unable to check (requires admin)'
        }
    }

    # --- CARGO_INCREMENTAL check ---
    if ($env:CARGO_INCREMENTAL -eq '1' -and $env:RUSTC_WRAPPER -eq 'sccache') {
        $issues += 'CARGO_INCREMENTAL=1 with sccache destroys cache hit rates'
    }
    $results['CARGO_INCREMENTAL'] = if ($env:CARGO_INCREMENTAL) { $env:CARGO_INCREMENTAL } else { 'not set' }

    # --- PATH conflicts ---
    $pathConflicts = @()
    $pathParts = $env:PATH -split ';'
    foreach ($p in $pathParts) {
        if ($p -like '*\Strawberry\c\bin*') { $pathConflicts += "Strawberry Perl: $p" }
        if ($p -like '*\Git\mingw64\bin*') { $pathConflicts += "Git mingw64: $p" }
    }
    $results['PATHConflicts'] = if ($pathConflicts.Count -gt 0) {
        "$($pathConflicts.Count) conflict(s) found (auto-sanitized during builds)"
    } else { 'None' }

    # --- Global config files ---
    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
    $cargoConfigPath = Join-Path $cargoHome 'config.toml'
    if (Test-Path $cargoConfigPath) {
        $cargoConfig = Read-TomlSections -Path $cargoConfigPath
        $hasSparse = $cargoConfig.Contains('registries.crates-io') -and $cargoConfig['registries.crates-io'].Contains('protocol')
        $results['CargoConfig'] = if ($hasSparse) { "present (sparse registry)" } else { "present (no sparse registry)" }
        if (-not $hasSparse) {
            $optimizations += 'Add sparse registry protocol to cargo config: Initialize-RustDefaults -Scope Cargo'
        }
    } else {
        $results['CargoConfig'] = 'NOT FOUND'
        $optimizations += 'Generate cargo config: Initialize-RustDefaults -Scope Cargo'
    }

    $managedEnv = Get-ManagedCargoEnvDefaults
    $cargoConfigPaths = @(
        (Join-Path $HOME '.cargo\config.toml'),
        (Join-Path $cacheRoot 'cargo-home\config.toml')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $envTypeConflicts = @()
    foreach ($envKey in $managedEnv.Keys) {
        $types = @{}
        foreach ($configPath in $cargoConfigPaths) {
            $config = Read-TomlSections -Path $configPath
            if ($config.Contains('env') -and $config['env'].Contains($envKey)) {
                $raw = [string]$config['env'][$envKey]
                $typeName = if ($raw.TrimStart().StartsWith('{')) { 'inline-table' } else { 'scalar' }
                $types[$typeName] = $true
            }
        }
        if ($types.Keys.Count -gt 1) {
            $envTypeConflicts += $envKey
        }
    }

    if ($envTypeConflicts.Count -gt 0) {
        $results['CargoConfigMerge'] = "conflicting [env] value types: $($envTypeConflicts -join ', ')"
        $issues += 'Cargo config [env] values use mixed scalar/table forms; run Initialize-RustDefaults -Scope Cargo'
    } elseif ($cargoConfigPaths.Count -gt 0) {
        $results['CargoConfigMerge'] = 'compatible [env] value types'
    } else {
        $results['CargoConfigMerge'] = 'no cargo config files found'
    }

    $rustfmtPath = Join-Path $HOME 'rustfmt.toml'
    $results['RustfmtConfig'] = if (Test-Path $rustfmtPath) { 'present' } else {
        'NOT FOUND'
        $optimizations += 'Generate global rustfmt.toml: Initialize-RustDefaults -Scope Rustfmt'
    }

    # --- Build job count ---
    $results['BuildJobs'] = if ($env:CARGO_BUILD_JOBS) { $env:CARGO_BUILD_JOBS } else { (Get-OptimalBuildJobs) }

    # --- Machine dependency gate ---
    if ($null -ne (Get-Item -Path 'Function:Test-CargoMachineDependencies' -ErrorAction SilentlyContinue)) {
        $depCheck = Test-CargoMachineDependencies -Quiet -Detailed
        $results['MachineDeps'] = if ($depCheck.Passed) {
            'pass'
        } else {
            "fail ($($depCheck.MissingMandatory -join ', '))"
        }
    }

    # --- Output ---
    Write-Host ''
    Write-Host '=== Rust Build Environment ===' -ForegroundColor Cyan
    foreach ($key in $results.Keys) {
        $value = $results[$key]
        $color = if ($value -match 'NOT FOUND|not running|not installed|None —|NTFS|No \(') { 'Yellow' }
                 elseif ($value -match 'healthy|excluded|installed|ReFS|Yes') { 'Green' }
                 else { 'Gray' }
        Write-Host "  $($key.PadRight(22)) $value" -ForegroundColor $color
    }

    if ($issues.Count -gt 0) {
        Write-Host ''
        Write-Host '=== Issues ===' -ForegroundColor Red
        foreach ($issue in $issues) {
            Write-Host "  ! $issue" -ForegroundColor Red
        }
    }

    if ($optimizations.Count -gt 0) {
        Write-Host ''
        Write-Host '=== Optimization Opportunities ===' -ForegroundColor Yellow
        foreach ($opt in $optimizations) {
            Write-Host "  > $opt" -ForegroundColor Yellow
        }
    }

    if ($issues.Count -eq 0 -and $optimizations.Count -eq 0) {
        Write-Host ''
        Write-Host '  Build environment is fully optimized.' -ForegroundColor Green
    }
    Write-Host ''

    if ($Detailed) {
        return [PSCustomObject]@{
            Results       = $results
            Issues        = $issues
            Optimizations = $optimizations
        }
    }
}
