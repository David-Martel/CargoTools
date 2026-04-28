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
    $MemoryLimitMB = 0
    $NoProcMacros = $false
    $GenerateConfig = $false
    $Transport = $null

    # Dynamic lock file path resolution
    $cacheRoot = Resolve-CacheRoot
    $LockFile = Join-Path $cacheRoot 'rust-analyzer\ra.lock'

    function Show-Help {
        Write-Host 'rust-analyzer-wrapper - Single-instance rust-analyzer launcher' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  rust-analyzer-wrapper [--allow-multi] [--force] [--global-singleton] [--lock-file <path>]' -ForegroundColor Gray
        Write-Host '  rust-analyzer-wrapper [--memory-limit <MB>] [--no-proc-macros] [--generate-config]' -ForegroundColor Gray
        Write-Host '  rust-analyzer-wrapper [--transport auto|direct|lspmux] [--direct] [--lspmux]' -ForegroundColor Gray
        Write-Host '  rust-analyzer-wrapper --help' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Behavior:' -ForegroundColor Yellow
        Write-Host '  - Enforces single instance unless --allow-multi is specified' -ForegroundColor Gray
        Write-Host '  - Uses a global mutex when --global-singleton is set (or RA_SINGLETON=1)' -ForegroundColor Gray
        Write-Host '  - Writes a lock file with PID; removes it on exit' -ForegroundColor Gray
        Write-Host '  - Sets RA_LOG=error if not already set' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Memory Management:' -ForegroundColor Yellow
        Write-Host '  --memory-limit <MB>   Kill and warn if rust-analyzer exceeds this memory (default: 0 = disabled)' -ForegroundColor Gray
        Write-Host '                        Also settable via RA_MEMORY_LIMIT_MB env var' -ForegroundColor Gray
        Write-Host '  --no-proc-macros      Disable proc-macro expansion (saves ~500MB on large projects)' -ForegroundColor Gray
        Write-Host '                        Sets RA_PROC_MACRO_WORKERS=0' -ForegroundColor Gray
        Write-Host '  --transport <mode>    Transport mode: auto (default), direct, or lspmux' -ForegroundColor Gray
        Write-Host '  --direct              Shortcut for --transport direct' -ForegroundColor Gray
        Write-Host '  --lspmux              Shortcut for --transport lspmux' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Config Generation:' -ForegroundColor Yellow
        Write-Host '  --generate-config     Generate rust-analyzer.toml in current directory' -ForegroundColor Gray
        Write-Host '                        Uses merge strategy: existing values preserved, missing keys added' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Wrappers:' -ForegroundColor Yellow
        Write-Host '  rust-analyzer.ps1 / rust-analyzer.cmd (preferred shim)' -ForegroundColor Gray
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
            '--memory-limit' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --memory-limit'; return 1 }
                $MemoryLimitMB = [int]$rawArgs[$i]
                continue
            }
            '--no-proc-macros' { $NoProcMacros = $true; continue }
            '--generate-config' { $GenerateConfig = $true; continue }
            '--transport' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --transport'; return 1 }
                $Transport = [string]$rawArgs[$i]
                continue
            }
            '--direct' { $Transport = 'direct'; continue }
            '--lspmux' { $Transport = 'lspmux'; continue }
            default { }
        }
    }

    if ($Help) { Show-Help; return 0 }

    # --no-proc-macros overrides the default proc-macro worker setting (before --generate-config exit)
    if ($NoProcMacros) {
        $env:RA_PROC_MACRO_WORKERS = '0'
    }

    # --generate-config: create/merge rust-analyzer.toml in current directory then exit
    if ($GenerateConfig) {
        $configPath = Join-Path (Get-Location) 'rust-analyzer.toml'
        $defaults = Get-DefaultRustAnalyzerConfig
        $header = '# Generated by CargoTools -- existing values preserved on update'
        if (Test-Path $configPath) {
            $existing = Read-TomlSections -Path $configPath
            $mergeResult = Merge-TomlConfig -Existing $existing -Defaults $defaults
            $toml = ConvertTo-TomlString -Data $mergeResult.Config -Header $header
            Write-ConfigFile -Path $configPath -Content $toml
        } else {
            $toml = ConvertTo-TomlString -Data $defaults -Header $header
            Write-ConfigFile -Path $configPath -Content $toml
        }
        Write-Host "Generated $configPath" -ForegroundColor Green
        return 0
    }

    # RA_MEMORY_LIMIT_MB env var fallback
    if ($MemoryLimitMB -eq 0 -and $env:RA_MEMORY_LIMIT_MB) {
        $MemoryLimitMB = [int]$env:RA_MEMORY_LIMIT_MB
    }

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
    if (-not $env:RUSTC_WRAPPER) {
        $sccachePath = Resolve-Sccache
        if ($sccachePath) { $env:RUSTC_WRAPPER = 'sccache' }
    }
    if (-not $env:RUST_ANALYZER_CACHE_DIR) { $env:RUST_ANALYZER_CACHE_DIR = Join-Path $cacheRoot 'ra-cache' }

    # Strip wrapper-specific args before passing to rust-analyzer or lspmux.
    $raArgs = @()
    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $arg = $rawArgs[$i]
        if ($arg -in @('--allow-multi', '--force', '--global-singleton', '--no-proc-macros', '--generate-config', '--direct', '--lspmux')) { continue }
        if ($arg -in @('--lock-file', '--memory-limit', '--transport')) { $i++; continue }
        $raArgs += $arg
    }

    $transportStatus = Resolve-RustAnalyzerTransportMode -ArgumentList $raArgs -Preference $Transport
    if ($transportStatus.Effective -eq 'lspmux') {
        Write-Verbose "Resolved rust-analyzer transport: lspmux ($($transportStatus.Reason))"
        & $transportStatus.LspmuxPath client --server-path $raExe @raArgs
        return $LASTEXITCODE
    }

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

            # Memory watchdog: poll rust-analyzer memory and kill if over limit
            $watchdogJob = $null
            if ($MemoryLimitMB -gt 0) {
                $raPid = $raProcess.Id
                $limitBytes = [long]$MemoryLimitMB * 1024 * 1024
                $watchdogJob = Start-Job -ScriptBlock {
                    param($pid, $limitBytes)
                    while ($true) {
                        Start-Sleep -Seconds 60
                        try {
                            $proc = Get-Process -Id $pid -ErrorAction Stop
                            if ($proc.WorkingSet64 -gt $limitBytes) {
                                $memMB = [Math]::Round($proc.WorkingSet64 / 1MB, 0)
                                $limitMB = [Math]::Round($limitBytes / 1MB, 0)
                                # Write to stderr so the parent can see it
                                [Console]::Error.WriteLine("rust-analyzer memory watchdog: ${memMB}MB exceeds limit of ${limitMB}MB. Killing process.")
                                Stop-Process -Id $pid -Force
                                break
                            }
                        } catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
                            # Process exited - stop watching
                            break
                        } catch {
                            break
                        }
                    }
                } -ArgumentList $raPid, $limitBytes
            }

            $raProcess.WaitForExit()
            return $raProcess.ExitCode
        } else {
            & $raExe @raArgs
            return $LASTEXITCODE
        }
    } finally {
        # Clean up memory watchdog job
        if ($watchdogJob) {
            Stop-Job -Job $watchdogJob -ErrorAction SilentlyContinue
            Remove-Job -Job $watchdogJob -Force -ErrorAction SilentlyContinue
        }

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
