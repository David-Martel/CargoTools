function Invoke-RustAnalyzerWrapper {
<#
.SYNOPSIS
Single-instance rust-analyzer launcher with memory optimization.
.DESCRIPTION
Enforces singleton execution of rust-analyzer to prevent resource exhaustion.
Uses mutex for process-level synchronization and file locks for cross-process coordination.
.PARAMETER ArgumentList
Raw rust-analyzer wrapper arguments.
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
        [string[]]$ArgumentList
    )

    $rawArgs = if ($ArgumentList) { @($ArgumentList) } else { @() }
    if ($rawArgs -isnot [System.Array]) { $rawArgs = @($rawArgs) }
    $Help = $false
    $AllowMulti = $false
    $Force = $false
    $GlobalSingleton = $false

    # Dynamic lock file path resolution
    $cacheRoot = Resolve-CacheRoot
    $LockFile = Join-Path $cacheRoot 'rust-analyzer\ra.lock'

    function Show-Help {
        Write-Host 'rust-analyzer-wrapper - Single-instance rust-analyzer launcher' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  rust-analyzer-wrapper [--allow-multi] [--force] [--global-singleton] [--lock-file <path>]' -ForegroundColor Gray
        Write-Host '  rust-analyzer-wrapper --help' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Behavior:' -ForegroundColor Yellow
        Write-Host '  - Enforces single instance unless --allow-multi is specified' -ForegroundColor Gray
        Write-Host '  - Uses a global mutex when --global-singleton is set (or RA_SINGLETON=1)' -ForegroundColor Gray
        Write-Host '  - Writes a lock file with PID; removes it on exit' -ForegroundColor Gray
        Write-Host '  - Sets RA_LOG=error if not already set' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Wrappers:' -ForegroundColor Yellow
        Write-Host '  rust-analyzer-wrapper.ps1 (direct)' -ForegroundColor Gray
        Write-Host ''
    }

    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $arg = $rawArgs[$i]
        switch ($arg) {
            '--help' { $Help = $true; continue }
            '-h' { $Help = $true; continue }
            '--allow-multi' { $AllowMulti = $true; continue }
            '--force' { $Force = $true; continue }
            '--global-singleton' { $GlobalSingleton = $true; continue }
            '--lock-file' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --lock-file'; return 1 }
                $LockFile = $rawArgs[$i]
                continue
            }
            default { }
        }
    }

    if ($Help) { Show-Help; return 0 }

    # Use Resolve-RustAnalyzerPath to avoid broken shims and Get-Command loops
    $raExe = Resolve-RustAnalyzerPath
    if (-not $raExe) {
        Write-Error 'rust-analyzer not found. Install via rustup: rustup component add rust-analyzer'
        return 1
    }
    Write-Verbose "Resolved rust-analyzer: $raExe"

    $lockDir = Split-Path -Path $LockFile -Parent
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null

    if (-not $env:RA_LOG) { $env:RA_LOG = 'error' }

    # Memory optimization environment variables
    if (-not $env:RA_LRU_CAPACITY) { $env:RA_LRU_CAPACITY = '64' }  # Limit LRU cache entries
    if (-not $env:CHALK_SOLVER_MAX_SIZE) { $env:CHALK_SOLVER_MAX_SIZE = '10' }  # Limit trait solver
    if (-not $env:RA_PROC_MACRO_WORKERS) { $env:RA_PROC_MACRO_WORKERS = '1' }  # Single proc-macro worker (major memory saver)

    # Dynamic path resolution for cache directories
    if (-not $env:CARGO_TARGET_DIR) { $env:CARGO_TARGET_DIR = Join-Path $cacheRoot 'cargo-target' }
    if (-not $env:SCCACHE_DIR) { $env:SCCACHE_DIR = Join-Path $cacheRoot 'sccache' }
    if (-not $env:RUSTC_WRAPPER) { $env:RUSTC_WRAPPER = 'sccache' }
    if (-not $env:RUST_ANALYZER_CACHE_DIR) { $env:RUST_ANALYZER_CACHE_DIR = Join-Path $cacheRoot 'ra-cache' }

    $useSingleton = -not $AllowMulti
    if ($env:RA_SINGLETON -and $env:RA_SINGLETON -ne '0') { $GlobalSingleton = $true }

    if ($useSingleton) {
        $existing = Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue
        if ($existing -and -not $Force) {
            Write-Error "rust-analyzer already running (PID $($existing[0].Id)). Use --allow-multi or --force."
            return 1
        }
    }

    $mutex = $null
    $mutexAcquired = $false
    if ($useSingleton -and $GlobalSingleton) {
        try {
            $created = $false
            $mutex = New-Object System.Threading.Mutex($false, 'Local\\rust-analyzer-singleton', [ref]$created)
            # Actually acquire the mutex (with 100ms timeout to detect contention)
            $mutexAcquired = $mutex.WaitOne(100)
            if (-not $mutexAcquired) {
                if (-not $Force) {
                    Write-Error 'rust-analyzer global singleton already held. Use --allow-multi or --force.'
                    $mutex.Dispose()
                    return 1
                }
                # Force mode: wait longer then proceed anyway
                Write-Warning 'Forcing mutex acquisition despite existing holder...'
                $mutexAcquired = $mutex.WaitOne(2000)
            }
        } catch [System.Threading.AbandonedMutexException] {
            # Previous holder crashed - we now own the mutex
            Write-Verbose 'Acquired abandoned mutex from crashed process'
            $mutexAcquired = $true
        } catch {
            Write-Warning "Unable to create/acquire global mutex: $_"
        }
    }

    # Atomic lock file acquisition to prevent TOCTOU race condition
    $lockStream = $null
    if ($useSingleton) {
        try {
            # Try to create lock file with exclusive access (atomic operation)
            $lockStream = [System.IO.File]::Open(
                $LockFile,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None
            )
            # Write our PID
            $writer = [System.IO.StreamWriter]::new($lockStream)
            $writer.WriteLine($PID)
            $writer.Flush()
        } catch [System.IO.IOException] {
            # File exists - check if holder is still alive
            $existingPid = $null
            try {
                $existingPid = Get-Content -Path $LockFile -ErrorAction SilentlyContinue | Select-Object -First 1
            } catch {}

            if ($existingPid -match '^\d+$') {
                $proc = Get-Process -Id ([int]$existingPid) -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -like '*rust-analyzer*') {
                    if ($Force) {
                        Stop-Process -Id ([int]$existingPid) -Force -ErrorAction SilentlyContinue
                        Start-Sleep -Milliseconds 200
                    } else {
                        Write-Error "rust-analyzer already running (PID $existingPid). Use --allow-multi or --force."
                        return 1
                    }
                }
            }

            # Stale lock or forced - remove and retry
            Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 50  # Brief pause for filesystem sync
            try {
                $lockStream = [System.IO.File]::Open(
                    $LockFile,
                    [System.IO.FileMode]::CreateNew,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::None
                )
                $writer = [System.IO.StreamWriter]::new($lockStream)
                $writer.WriteLine($PID)
                $writer.Flush()
            } catch {
                Write-Error "Failed to acquire lock file after retry: $_"
                return 1
            }
        }
    }

    try {

        # Strip wrapper-specific args before passing to rust-analyzer
        $raArgs = @()
        for ($i = 0; $i -lt $rawArgs.Count; $i++) {
            $arg = $rawArgs[$i]
            if ($arg -in @('--allow-multi', '--force', '--global-singleton')) { continue }
            if ($arg -eq '--lock-file') { $i++; continue }
            $raArgs += $arg
        }

        # Start rust-analyzer with lower priority to prevent system overload
        $raProcess = Start-Process -FilePath $raExe -ArgumentList $raArgs -NoNewWindow -PassThru
        if ($raProcess) {
            # Update lock file with actual rust-analyzer PID
            if ($lockStream) {
                try {
                    $lockStream.SetLength(0)
                    $writer = [System.IO.StreamWriter]::new($lockStream)
                    $writer.WriteLine($raProcess.Id)
                    $writer.Flush()
                } catch {
                    Write-Warning "Failed to update lock file with rust-analyzer PID: $_"
                }
            } else {
                Set-Content -Path $LockFile -Value $raProcess.Id
            }
            try { $raProcess.PriorityClass = 'BelowNormal' } catch {}
            $raProcess.WaitForExit()
            return $raProcess.ExitCode
        } else {
            & $raExe @raArgs
            return $LASTEXITCODE
        }
    } finally {
        # Close lock file stream first
        if ($lockStream) {
            try { $lockStream.Dispose() } catch {}
        }
        Remove-Item -Path $LockFile -Force -ErrorAction SilentlyContinue

        # Only release mutex if we actually acquired it
        if ($mutex) {
            if ($mutexAcquired) {
                try { $mutex.ReleaseMutex() } catch {}
            }
            try { $mutex.Dispose() } catch {}
        }
    }
}
