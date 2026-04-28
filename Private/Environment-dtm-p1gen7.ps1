function Get-RustupPath {
    return "$env:USERPROFILE\.cargo\bin\rustup.exe"
}

function Resolve-RustAnalyzerPath {
    <#
    .SYNOPSIS
    Resolves the canonical rust-analyzer executable path.
    .DESCRIPTION
    Finds rust-analyzer in priority order:
    1. RUST_ANALYZER_PATH environment variable
    2. Active rustup toolchain
    3. Known installation locations
    Avoids Get-Command which may find broken shims or wrong versions.
    #>
    [CmdletBinding()]
    param()

    # Priority 1: Explicit environment variable (validate it's a real executable, not empty shim)
    if ($env:RUST_ANALYZER_PATH -and (Test-Path $env:RUST_ANALYZER_PATH)) {
        $fileInfo = Get-Item $env:RUST_ANALYZER_PATH -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt 1000) {
            return $env:RUST_ANALYZER_PATH
        }
        Write-Verbose "RUST_ANALYZER_PATH points to invalid file (size: $($fileInfo.Length) bytes), skipping"
    }

    # Priority 2: Query rustup for active toolchain
    $rustupPath = Get-RustupPath
    if (Test-Path $rustupPath) {
        try {
            $toolchainOutput = & $rustupPath show active-toolchain 2>$null
            if ($toolchainOutput -match '^([^\s]+)') {
                $toolchain = $Matches[1]
                # Dynamic RUSTUP_HOME resolution
                $rustupHome = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME }
                              elseif (Test-Path 'T:\RustCache\rustup') { 'T:\RustCache\rustup' }
                              else { Join-Path $env:USERPROFILE '.rustup' }
                $raPath = Join-Path $rustupHome "toolchains\$toolchain\bin\rust-analyzer.exe"
                if (Test-Path $raPath) {
                    return $raPath
                }
            }
        } catch {
            Write-Verbose "Rustup query failed: $_"
        }
    }

    # Priority 3: Known locations (dynamically resolved)
    $cacheRoot = Resolve-CacheRoot
    $defaultRustup = Join-Path $env:USERPROFILE '.rustup'
    $knownPaths = @(
        (Join-Path $cacheRoot 'rustup\toolchains\stable-x86_64-pc-windows-msvc\bin\rust-analyzer.exe'),
        (Join-Path $cacheRoot 'rustup\toolchains\nightly-x86_64-pc-windows-msvc\bin\rust-analyzer.exe'),
        (Join-Path $defaultRustup 'toolchains\stable-x86_64-pc-windows-msvc\bin\rust-analyzer.exe')
    )

    foreach ($path in $knownPaths) {
        if (Test-Path $path) {
            $fileInfo = Get-Item $path
            # Verify it's not a 0-byte empty file
            if ($fileInfo.Length -gt 1000) {
                return $path
            }
        }
    }

    # Priority 4: Fallback to Get-Command but validate the result
    $raCmd = Get-Command rust-analyzer -ErrorAction SilentlyContinue
    if ($raCmd -and $raCmd.Source) {
        $fileInfo = Get-Item $raCmd.Source -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt 1000) {
            return $raCmd.Source
        }
    }

    return $null
}

function Get-RustAnalyzerMemoryMB {
    <#
    .SYNOPSIS
    Gets total memory usage of all rust-analyzer processes in MB.
    #>
    $procs = @(Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $total = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum
        return [math]::Round($total / 1MB, 0)
    }
    return 0
}

function Test-RustAnalyzerSingleton {
    <#
    .SYNOPSIS
    Tests if rust-analyzer singleton is properly enforced.
    .OUTPUTS
    PSCustomObject with Status, ProcessCount, MemoryMB, LockFileExists, Issues
    #>
    [CmdletBinding()]
    param(
        [int]$WarnThresholdMB = 1500
    )

    $result = [PSCustomObject]@{
        Status = 'Unknown'
        ProcessCount = 0
        MemoryMB = 0
        LockFileExists = $false
        LockFilePID = $null
        Issues = @()
    }

    # Check processes
    $procs = @(Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue |
               Where-Object { $_.ProcessName -eq 'rust-analyzer' })
    $result.ProcessCount = $procs.Count
    $result.MemoryMB = Get-RustAnalyzerMemoryMB

    # Check lock file (dynamically resolved)
    $cacheRoot = Resolve-CacheRoot
    $lockFile = Join-Path $cacheRoot 'rust-analyzer\ra.lock'
    $result.LockFileExists = Test-Path $lockFile
    if ($result.LockFileExists) {
        $content = Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($content -match '^\d+$') {
            $result.LockFilePID = [int]$content
        }
    }

    # Analyze issues
    if ($result.ProcessCount -eq 0) {
        $result.Status = 'NotRunning'
    } elseif ($result.ProcessCount -eq 1) {
        if ($result.MemoryMB -gt $WarnThresholdMB) {
            $result.Status = 'HighMemory'
            $result.Issues += "Memory usage ($($result.MemoryMB)MB) exceeds threshold (${WarnThresholdMB}MB)"
        } else {
            $result.Status = 'Healthy'
        }
    } else {
        $result.Status = 'MultipleInstances'
        $result.Issues += "Multiple rust-analyzer processes detected ($($result.ProcessCount))"
    }

    # Check lock file consistency
    if ($result.ProcessCount -gt 0 -and -not $result.LockFileExists) {
        $result.Issues += 'No lock file - wrapper may not be in use'
    }
    if ($result.LockFileExists -and $result.LockFilePID) {
        $lockProc = Get-Process -Id $result.LockFilePID -ErrorAction SilentlyContinue
        if (-not $lockProc) {
            $result.Issues += "Stale lock file (PID $($result.LockFilePID) not running)"
        }
    }

    return $result
}

function Test-IsWindows {
    return ($env:OS -eq 'Windows_NT')
}

function Resolve-UserScript {
    param([string]$Name)
    $candidates = @(
        (Join-Path $env:USERPROFILE "bin\\$Name"),
        (Join-Path $env:USERPROFILE ".local\\bin\\$Name")
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Ensure-MsvcEnv {
    if (-not (Test-IsWindows)) { return }

    $forceMsvcBootstrap = $env:CARGOTOOLS_FORCE_MSVC_ENV -and $env:CARGOTOOLS_FORCE_MSVC_ENV -ne '0'
    $alreadyBootstrapped = $env:CARGOTOOLS_MSVC_ENV_INITIALIZED -eq '1'
    $hasCompilerEnv = $env:VCINSTALLDIR -and $env:LIB -and $env:INCLUDE
    if ($hasCompilerEnv -and $alreadyBootstrapped -and -not $forceMsvcBootstrap) { return }

    $msvcEnv = Resolve-UserScript 'msvc-env.ps1'
    if (-not $msvcEnv) { return }

    try {
        & $msvcEnv -Arch x64 -HostArch x64 -NoChocoRefresh | Out-Null
        $env:CARGOTOOLS_MSVC_ENV_INITIALIZED = '1'
    } catch {
        Write-Warning "Unable to load MSVC environment via ${msvcEnv}: $_"
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-CacheRoot {
    param([string]$CacheRoot)
    if ($CacheRoot -and (Test-Path $CacheRoot)) { return $CacheRoot }

    $tDrive = 'T:\'
    if (Test-Path $tDrive) {
        $candidate = Join-Path $tDrive 'RustCache'
        Ensure-Directory -Path $candidate
        return $candidate
    }

    $fallback = Join-Path $env:LOCALAPPDATA 'RustCache'
    Ensure-Directory -Path $fallback
    return $fallback
}

function Resolve-Sccache {
    $cmd = Get-Command sccache -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-SanitizedPath {
    <#
    .SYNOPSIS
    Returns PATH with known conflicting compiler directories removed.
    .DESCRIPTION
    Strips Strawberry Perl gcc.exe directory and Git mingw64/bin to prevent
    them from shadowing MSVC cl.exe/link.exe during Windows-native builds.
    #>
    [CmdletBinding()]
    param([string]$CurrentPath = $env:PATH)

    $conflictPatterns = @(
        '*\Strawberry\c\bin*',
        '*\Strawberry\perl\bin*',
        '*\Git\mingw64\bin*',
        '*\Git\usr\bin*'
    )

    $parts = $CurrentPath -split ';' | Where-Object { $_ -and $_.Trim() }
    $cleaned = @()
    $removed = @()

    foreach ($part in $parts) {
        $isConflict = $false
        foreach ($pattern in $conflictPatterns) {
            if ($part -like $pattern) {
                $isConflict = $true
                $removed += $part
                break
            }
        }
        if (-not $isConflict) { $cleaned += $part }
    }

    if ($removed.Count -gt 0) {
        Write-Verbose "[CargoTools] Sanitized PATH: removed $($removed -join ', ')"
    }

    return $cleaned -join ';'
}

function Get-MsvcClExePath {
    <#
    .SYNOPSIS
    Resolves the absolute path to MSVC cl.exe (not Strawberry/MinGW).
    #>
    [CmdletBinding()]
    param()

    # Prefer explicit VCToolsInstallDir when present
    if ($env:VCToolsInstallDir) {
        $msvcCl = Join-Path $env:VCToolsInstallDir 'bin\\Hostx64\\x64\\cl.exe'
        if (Test-Path $msvcCl) { return $msvcCl }
    }

    # VCINSTALLDIR may point either to the VC root or directly to a tools version
    if ($env:VCINSTALLDIR) {
        $directCl = Join-Path $env:VCINSTALLDIR 'bin\\Hostx64\\x64\\cl.exe'
        if (Test-Path $directCl) { return $directCl }

        $toolsRoot = Join-Path $env:VCINSTALLDIR 'Tools\\MSVC'
        if (Test-Path $toolsRoot) {
            $latestToolsDir = Get-ChildItem -LiteralPath $toolsRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First 1

            if ($latestToolsDir) {
                $nestedCl = Join-Path $latestToolsDir.FullName 'bin\\Hostx64\\x64\\cl.exe'
                if (Test-Path $nestedCl) { return $nestedCl }
            }
        }
    }

    # Search PATH but skip known conflict directories
    $cleanPath = Get-SanitizedPath
    foreach ($dir in ($cleanPath -split ';')) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir 'cl.exe'
        if ((Test-Path $candidate) -and $dir -notlike '*Strawberry*' -and $dir -notlike '*mingw*') {
            return $candidate
        }
    }

    return $null
}

function Initialize-CargoEnv {
    param(
        [string]$CacheRoot = 'T:\RustCache'
    )

    Ensure-MsvcEnv

    if (Test-IsWindows) {
        $msvcCl = Get-MsvcClExePath
        if ($msvcCl) {
            if (-not $env:CC -or ($env:CC -eq 'cl.exe')) { $env:CC = $msvcCl }
            if (-not $env:CXX -or ($env:CXX -eq 'cl.exe')) { $env:CXX = $msvcCl }
        }
        # Sanitize PATH to prevent Strawberry Perl/Git mingw from shadowing MSVC
        $env:PATH = Get-SanitizedPath
    }

    if ($env:CL) {
        $clValue = $env:CL
        $isPathLike = ($clValue -match '[A-Za-z]:') -or ($clValue -match '\\') -or ($clValue -match '/')
        $isOption = $clValue.TrimStart().StartsWith('/') -or $clValue.TrimStart().StartsWith('-')
        if ($isPathLike -and -not $isOption) {
            Remove-Item Env:CL -ErrorAction SilentlyContinue
        }
    }

    $CacheRoot = Resolve-CacheRoot -CacheRoot $CacheRoot
    $sccacheExe = Resolve-Sccache
    if ($sccacheExe) {
        $env:RUSTC_WRAPPER = 'sccache'
    } else {
        if (Test-Path Env:RUSTC_WRAPPER) { Remove-Item Env:RUSTC_WRAPPER }
        $env:SCCACHE_DISABLE = '1'
        Write-Warning 'sccache not found; disabling RUSTC_WRAPPER for this session.'
    }
    if (-not $env:CARGO_INCREMENTAL) { $env:CARGO_INCREMENTAL = '0' }

    # CARGO_INCREMENTAL=1 with sccache silently destroys cache hit rates (sccache#236)
    if ($env:CARGO_INCREMENTAL -eq '1' -and $env:RUSTC_WRAPPER -eq 'sccache') {
        Write-Warning '[CargoTools] CARGO_INCREMENTAL=1 with sccache severely reduces cache hit rates. Setting CARGO_INCREMENTAL=0.'
        $env:CARGO_INCREMENTAL = '0'
    }

    if (-not $env:SCCACHE_DIR) { $env:SCCACHE_DIR = Join-Path $CacheRoot 'sccache' }
    if (-not $env:SCCACHE_CACHE_COMPRESSION) { $env:SCCACHE_CACHE_COMPRESSION = 'zstd' }
    if (-not $env:SCCACHE_CACHE_SIZE) { $env:SCCACHE_CACHE_SIZE = '30G' }
    if (-not $env:SCCACHE_IDLE_TIMEOUT) { $env:SCCACHE_IDLE_TIMEOUT = '600' }  # 10 min - release memory faster
    # Fallbacks for non-cargo invocations; .cargo/config.toml is the source of truth
    if (-not $env:SCCACHE_STARTUP_TIMEOUT) { $env:SCCACHE_STARTUP_TIMEOUT = '30' }
    if (-not $env:SCCACHE_REQUEST_TIMEOUT) { $env:SCCACHE_REQUEST_TIMEOUT = '180' }
    if (-not $env:SCCACHE_DIRECT) { $env:SCCACHE_DIRECT = 'true' }
    if (-not $env:SCCACHE_SERVER_PORT) { $env:SCCACHE_SERVER_PORT = '4226' }
    if (-not $env:SCCACHE_LOG) { $env:SCCACHE_LOG = 'warn' }
    if (-not $env:SCCACHE_ERROR_LOG) { $env:SCCACHE_ERROR_LOG = (Join-Path $CacheRoot 'sccache\error.log') }
    if (-not $env:SCCACHE_NO_DAEMON) { $env:SCCACHE_NO_DAEMON = '0' }
    if (-not $env:SCCACHE_MAX_CONNECTIONS) { $env:SCCACHE_MAX_CONNECTIONS = '8' }  # Matches .cargo/config.toml

    # Auto-enable lld-link when installed (significantly faster linking)
    if (-not $env:CARGO_USE_LLD) {
        $lldDefault = 'C:\Program Files\LLVM\bin\lld-link.exe'
        if (($env:CARGO_LLD_PATH -and (Test-Path $env:CARGO_LLD_PATH)) -or (Test-Path $lldDefault)) {
            $env:CARGO_USE_LLD = '1'
        } else {
            # Fallback: check for bundled rust-lld in active toolchain
            $bundledLld = Resolve-BundledRustLld
            if ($bundledLld) {
                $env:CARGO_USE_LLD = '1'
            } else {
                $env:CARGO_USE_LLD = '0'
            }
        }
    }
    if (-not $env:CARGO_USE_FASTLINK) { $env:CARGO_USE_FASTLINK = '0' }
    if (-not $env:CARGO_LLD_PATH) {
        $lldDefault = 'C:\Program Files\LLVM\bin\lld-link.exe'
        if (Test-Path $lldDefault) {
            $env:CARGO_LLD_PATH = $lldDefault
        }
    }

    # rust-analyzer memory optimization
    if (-not $env:RA_LRU_CAPACITY) { $env:RA_LRU_CAPACITY = '64' }  # Limit LRU cache entries
    if (-not $env:CHALK_SOLVER_MAX_SIZE) { $env:CHALK_SOLVER_MAX_SIZE = '10' }  # Limit trait solver
    if (-not $env:RA_PROC_MACRO_WORKERS) { $env:RA_PROC_MACRO_WORKERS = '1' }  # Single proc-macro worker
    if (-not $env:RUST_ANALYZER_CACHE_DIR) { $env:RUST_ANALYZER_CACHE_DIR = Join-Path $CacheRoot 'ra-cache' }

    # Build job limits for memory management
    if (-not $env:CARGO_BUILD_JOBS) { $env:CARGO_BUILD_JOBS = (Get-OptimalBuildJobs) }  # Prevent paging file exhaustion

    # Mandatory quality-gate defaults
    if (-not $env:CARGOTOOLS_ENFORCE_QUALITY) { $env:CARGOTOOLS_ENFORCE_QUALITY = '1' }
    if (-not $env:CARGOTOOLS_AUTO_FIX) { $env:CARGOTOOLS_AUTO_FIX = '1' }
    if (-not $env:CARGOTOOLS_PREFLIGHT_MODE) { $env:CARGOTOOLS_PREFLIGHT_MODE = 'all' }
    if (-not $env:CARGOTOOLS_RUN_TESTS_AFTER_BUILD) { $env:CARGOTOOLS_RUN_TESTS_AFTER_BUILD = '1' }
    if (-not $env:CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD) { $env:CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD = '1' }

    # Auto-enable nextest for test commands when installed
    if (-not $env:CARGO_USE_NEXTEST) {
        $nextestCmd = Get-Command cargo-nextest -ErrorAction SilentlyContinue
        if ($nextestCmd) {
            $env:CARGO_USE_NEXTEST = '1'
        }
    }

    # CMake: prefer Ninja generator for native C/C++ dependencies in build.rs
    if (-not $env:CMAKE_GENERATOR) {
        $ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
        if ($ninjaCmd) { $env:CMAKE_GENERATOR = 'Ninja' }
    }

    # Parallel make/cmake for native deps
    $optimalJobs = Get-OptimalBuildJobs
    if (-not $env:MAKEFLAGS) { $env:MAKEFLAGS = "-j$optimalJobs" }
    if (-not $env:CMAKE_BUILD_PARALLEL_LEVEL) { $env:CMAKE_BUILD_PARALLEL_LEVEL = "$optimalJobs" }

    if (-not $env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR = Join-Path $CacheRoot 'cargo-target' }
    if (-not $env:CARGO_HOME) { $env:CARGO_HOME = Join-Path $CacheRoot 'cargo-home' }
    if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = Join-Path $CacheRoot 'rustup' }

    Ensure-Directory -Path $env:SCCACHE_DIR
    Ensure-Directory -Path $env:CARGO_TARGET_DIR
    Ensure-Directory -Path $env:CARGO_HOME
    Ensure-Directory -Path $env:RUSTUP_HOME
    if ($env:RUST_ANALYZER_CACHE_DIR) { Ensure-Directory -Path $env:RUST_ANALYZER_CACHE_DIR }
}

function Get-SccacheMemoryMB {
    $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $total = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum
        return [math]::Round($total / 1MB, 0)
    }
    return 0
}

function Start-SccacheServer {
    param(
        [int]$MaxMemoryMB = 2048,
        [switch]$Force
    )

    # Acquire cross-process mutex to prevent concurrent startup races.
    # Multiple LLM agents may invoke cargo simultaneously - without this,
    # they can both see 0 sccache processes and race to start servers.
    $mutexHandle = $null
    $useMutex = ([System.Management.Automation.PSTypeName]'CargoTools.ProcessMutex').Type
    if ($useMutex) {
        $mutexHandle = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_SccacheStartup', 10000)
        if (-not $mutexHandle) {
            Write-Verbose '[sccache] Another process is starting sccache, waiting...'
            # Could not acquire in 10s - another process is handling startup.
            # Check if sccache is already running (the other process may have started it).
            $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 0) { return $true }
            Write-Warning 'Timed out waiting for sccache startup mutex. Proceeding without lock.'
        }
    }

    try {
        $manager = Resolve-UserScript 'sccache-manager.ps1'
        if ($manager) {
            & $manager -HealthCheck | Out-Null
            if ($LASTEXITCODE -eq 0) { return $true }
        }

        $sccacheCmd = Resolve-Sccache
        if (-not $sccacheCmd) {
            Write-Warning 'sccache not found in PATH. Builds will continue without sccache.'
            return $false
        }

        # Check for multiple instances or high memory usage
        $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 1) {
            Write-Verbose "[Memory] Multiple sccache instances ($($procs.Count)), consolidating..."
            sccache --stop-server 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
            $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 1 -and $Force) {
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                $procs = @()
            } elseif ($procs.Count -gt 1) {
                Write-Warning 'Multiple sccache instances detected; use -Force to consolidate.'
            }
        }

        $memMB = Get-SccacheMemoryMB
        if ($procs.Count -eq 1 -and $memMB -gt $MaxMemoryMB) {
            Write-Verbose "[Memory] sccache using ${memMB}MB > ${MaxMemoryMB}MB limit, restarting..."
            sccache --stop-server 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
            $procs = @()
        }

        if ($procs.Count -eq 0 -or $Force) {
            & $sccacheCmd --start-server 2>$null | Out-Null
            Start-Sleep -Milliseconds 300
            $healthOk = $true
            try {
                & $sccacheCmd --show-stats 2>$null | Out-Null
                $healthOk = ($LASTEXITCODE -eq 0)
            } catch {
                $healthOk = $false
            }
            if (-not $healthOk) {
                Write-Warning 'sccache started but health check failed.'
                return $false
            }

            # Lower priority to prevent system overload
            $newProc = Get-Process -Name 'sccache' -ErrorAction SilentlyContinue
            if ($newProc) {
                try { $newProc.PriorityClass = 'BelowNormal' } catch {}
            }
        }
        return $true
    } catch {
        Write-Warning "Unable to start sccache server: $_"
    } finally {
        if ($mutexHandle) {
            $mutexHandle.Dispose()
        }
    }
    return $false
}

function Test-SccacheHealth {
    <#
    .SYNOPSIS
    Verifies sccache server is responsive. Used for post-failure diagnosis.
    .OUTPUTS
    PSCustomObject with Healthy, Running, ProcessCount, MemoryMB, Port, Error fields.
    #>
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Healthy      = $false
        Running      = $false
        ProcessCount = 0
        MemoryMB     = 0
        Port         = $env:SCCACHE_SERVER_PORT
        Error        = $null
    }

    $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
    $result.ProcessCount = $procs.Count
    $result.Running = $procs.Count -gt 0
    $result.MemoryMB = Get-SccacheMemoryMB

    if (-not $result.Running) {
        $result.Error = 'sccache server not running'
        return $result
    }

    try {
        $sccacheCmd = Resolve-Sccache
        if ($sccacheCmd) {
            & $sccacheCmd --show-stats 2>$null | Out-Null
            $result.Healthy = ($LASTEXITCODE -eq 0)
            if (-not $result.Healthy) {
                $result.Error = "sccache --show-stats returned exit code $LASTEXITCODE"
            }
        } else {
            $result.Error = 'sccache binary not found in PATH'
        }
    } catch {
        $result.Error = "sccache health check exception: $_"
    }

    return $result
}

function Stop-SccacheServer {
    $existing = Get-Process -Name 'sccache' -ErrorAction SilentlyContinue
    if (-not $existing) { return }
    sccache --stop-server 2>$null | Out-Null
    Start-Sleep -Milliseconds 500
    $remaining = Get-Process -Name 'sccache' -ErrorAction SilentlyContinue
    if ($remaining) {
        $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Get-OptimalBuildJobs {
    param([switch]$LowMemory)
    $defaultJobs = 4
    $lowMemoryJobs = 2

    if ($LowMemory) { return $lowMemoryJobs }

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
            if ($freeGB -lt 4) { return $lowMemoryJobs }
        }
    } catch {}

    return $defaultJobs
}

function Resolve-BundledRustLld {
    <#
    .SYNOPSIS
    Finds the bundled rust-lld.exe in the active Rust toolchain.
    .DESCRIPTION
    Rust ships a bundled lld linker at <toolchain>/lib/rustlib/x86_64-pc-windows-msvc/bin/rust-lld.exe.
    This is significantly faster than link.exe and requires no external LLVM install.
    #>
    $rustupPath = Get-RustupPath
    if (-not (Test-Path $rustupPath)) { return $null }

    $rustupHome = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME }
                  elseif (Test-Path 'T:\RustCache\rustup') { 'T:\RustCache\rustup' }
                  else { Join-Path $env:USERPROFILE '.rustup' }

    try {
        $toolchainOutput = & $rustupPath show active-toolchain 2>$null
        if ($toolchainOutput -match '^([^\s]+)') {
            $toolchain = $Matches[1]
            $bundledPath = Join-Path $rustupHome "toolchains\$toolchain\lib\rustlib\x86_64-pc-windows-msvc\bin\rust-lld.exe"
            if (Test-Path $bundledPath) {
                return $bundledPath
            }
        }
    } catch {
        Write-Verbose "Failed to resolve bundled rust-lld: $_"
    }
    return $null
}

function Resolve-LldLinker {
    # Priority 1: Explicit path
    if ($env:CARGO_LLD_PATH -and (Test-Path $env:CARGO_LLD_PATH)) {
        return $env:CARGO_LLD_PATH
    }
    # Priority 2: External lld-link on PATH
    $lldCmd = Get-Command lld-link -ErrorAction SilentlyContinue
    if ($lldCmd) { return $lldCmd.Source }
    # Priority 3: Bundled rust-lld in active toolchain
    return Resolve-BundledRustLld
}

function Apply-LinkerSettings {
    param(
        [bool]$UseLld,
        [string]$LldPath
    )

    if ($UseLld) {
        if ($LldPath) {
            $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = $LldPath
            # Bundled rust-lld requires explicit linker-flavor flag
            if ($LldPath -match '[/\\]rust-lld') {
                Add-RustFlags '-C linker-flavor=lld-link'
            }
            return $true
        }
        Write-Warning 'CARGO_USE_LLD requested, but no lld-link.exe or bundled rust-lld found. Falling back to link.exe.'
        $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = 'link.exe'
        return $false
    }

    $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = 'link.exe'
    return $false
}

function Apply-NativeCpuFlag {
    param([bool]$UseNative)
    if ($UseNative) { Add-RustFlags '-C target-cpu=native' }
}
