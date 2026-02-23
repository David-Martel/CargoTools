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
    if ($env:VCINSTALLDIR -and $env:LIB -and $env:INCLUDE) { return }

    $msvcEnv = Resolve-UserScript 'msvc-env.ps1'
    if (-not $msvcEnv) { return }

    try {
        & $msvcEnv -Arch x64 -HostArch x64 -NoChocoRefresh | Out-Null
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

function Initialize-CargoEnv {
    param(
        [string]$CacheRoot = 'T:\RustCache'
    )

    Ensure-MsvcEnv

    if (Test-IsWindows) {
        $cl = Get-Command cl.exe -ErrorAction SilentlyContinue
        if ($cl) {
            if (-not $env:CC -or ($env:CC -notmatch 'cl\.exe$')) { $env:CC = 'cl.exe' }
            if (-not $env:CXX -or ($env:CXX -notmatch 'cl\.exe$')) { $env:CXX = 'cl.exe' }
        }
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

    if (-not $env:SCCACHE_DIR) { $env:SCCACHE_DIR = Join-Path $CacheRoot 'sccache' }
    if (-not $env:SCCACHE_CACHE_COMPRESSION) { $env:SCCACHE_CACHE_COMPRESSION = 'zstd' }
    if (-not $env:SCCACHE_CACHE_SIZE) { $env:SCCACHE_CACHE_SIZE = '30G' }
    if (-not $env:SCCACHE_IDLE_TIMEOUT) { $env:SCCACHE_IDLE_TIMEOUT = '600' }  # 10 min - release memory faster
    if (-not $env:SCCACHE_STARTUP_TIMEOUT) { $env:SCCACHE_STARTUP_TIMEOUT = '15' }
    if (-not $env:SCCACHE_REQUEST_TIMEOUT) { $env:SCCACHE_REQUEST_TIMEOUT = '60' }
    if (-not $env:SCCACHE_DIRECT) { $env:SCCACHE_DIRECT = 'true' }
    if (-not $env:SCCACHE_SERVER_PORT) { $env:SCCACHE_SERVER_PORT = '4400' }
    if (-not $env:SCCACHE_LOG) { $env:SCCACHE_LOG = 'warn' }
    if (-not $env:SCCACHE_ERROR_LOG) { $env:SCCACHE_ERROR_LOG = (Join-Path $CacheRoot 'sccache\error.log') }
    if (-not $env:SCCACHE_NO_DAEMON) { $env:SCCACHE_NO_DAEMON = '0' }
    if (-not $env:SCCACHE_MAX_CONNECTIONS) { $env:SCCACHE_MAX_CONNECTIONS = '4' }  # Shared default for concurrent builds

    if (-not $env:CARGO_USE_LLD) { $env:CARGO_USE_LLD = '0' }
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
    }
    return $false
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

function Resolve-LldLinker {
    if ($env:CARGO_LLD_PATH -and (Test-Path $env:CARGO_LLD_PATH)) {
        return $env:CARGO_LLD_PATH
    }
    $lldCmd = Get-Command lld-link -ErrorAction SilentlyContinue
    if ($lldCmd) { return $lldCmd.Source }
    return $null
}

function Apply-LinkerSettings {
    param(
        [bool]$UseLld,
        [string]$LldPath
    )

    if ($UseLld) {
        if ($LldPath) {
            $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = $LldPath
            return $true
        }
        Write-Warning 'CARGO_USE_LLD requested, but lld-link.exe not found. Falling back to link.exe.'
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
