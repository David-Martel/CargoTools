function Test-RustAnalyzerHealth {
<#
.SYNOPSIS
Performs comprehensive health check on rust-analyzer singleton infrastructure.
.DESCRIPTION
Validates rust-analyzer installation, singleton enforcement, memory usage, and lock file state.
Returns a detailed health report with actionable recommendations.
.PARAMETER WarnThresholdMB
Memory threshold in MB above which a warning is issued. Default: 1500MB.
.PARAMETER Force
When specified with issues detected, attempts to fix them (kill runaway processes, clean stale locks).
.PARAMETER Quiet
Suppresses informational output; only returns the result object.
.PARAMETER OutputFormat
Output format: Text (human-readable), Json (LLM-friendly), Object (PowerShell object).
.EXAMPLE
Test-RustAnalyzerHealth
# Returns health status with recommendations
.EXAMPLE
Test-RustAnalyzerHealth -Force
# Fixes detected issues like multiple instances or stale locks
.EXAMPLE
Test-RustAnalyzerHealth -WarnThresholdMB 1000 -Quiet
# Custom threshold, object-only output
.EXAMPLE
Test-RustAnalyzerHealth -OutputFormat Json
# Returns JSON for LLM/AI consumption
#>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$WarnThresholdMB = 1500,

        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$Quiet,

        [Parameter()]
        [ValidateSet('Text', 'Json', 'Object')]
        [string]$OutputFormat = 'Text'
    )

    # If OutputFormat specified, use Quiet mode for data collection
    if ($OutputFormat -ne 'Text') {
        $Quiet = $true
    }

    # Dynamic path resolution
    $cacheRoot = Resolve-CacheRoot
    $shimPath = Join-Path $env:USERPROFILE 'bin\rust-analyzer.cmd'
    $lockFilePath = Join-Path $cacheRoot 'rust-analyzer\ra.lock'

    $result = [PSCustomObject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Status = 'Unknown'
        RustAnalyzerPath = $null
        ProcessCount = 0
        MainProcessCount = 0
        ProcMacroCount = 0
        MemoryMB = 0
        LockFile = @{
            Path = $lockFilePath
            Exists = $false
            PID = $null
            Valid = $false
        }
        EnvironmentVariables = @{
            RA_LRU_CAPACITY = $env:RA_LRU_CAPACITY
            CHALK_SOLVER_MAX_SIZE = $env:CHALK_SOLVER_MAX_SIZE
            RA_PROC_MACRO_WORKERS = $env:RA_PROC_MACRO_WORKERS
            RUST_ANALYZER_CACHE_DIR = $env:RUST_ANALYZER_CACHE_DIR
        }
        ShimPath = $shimPath
        ShimExists = $false
        ShimPriority = $false
        Issues = @()
        Recommendations = @()
        ActionsTaken = @()
    }

    # Check rust-analyzer path resolution
    $result.RustAnalyzerPath = Resolve-RustAnalyzerPath
    if (-not $result.RustAnalyzerPath) {
        $result.Issues += 'rust-analyzer executable not found'
        $result.Recommendations += 'Install rust-analyzer: rustup component add rust-analyzer'
    }

    # Check processes
    $allProcs = @(Get-Process -Name 'rust-analyzer*' -ErrorAction SilentlyContinue)
    $mainProcs = @($allProcs | Where-Object { $_.ProcessName -eq 'rust-analyzer' })
    $procMacroProcs = @($allProcs | Where-Object { $_.ProcessName -like '*proc-macro*' })

    $result.ProcessCount = $allProcs.Count
    $result.MainProcessCount = $mainProcs.Count
    $result.ProcMacroCount = $procMacroProcs.Count
    $result.MemoryMB = Get-RustAnalyzerMemoryMB

    # Check lock file
    $result.LockFile.Exists = Test-Path $result.LockFile.Path
    if ($result.LockFile.Exists) {
        $content = Get-Content $result.LockFile.Path -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($content -match '^\d+$') {
            $result.LockFile.PID = [int]$content
            $lockProc = Get-Process -Id $result.LockFile.PID -ErrorAction SilentlyContinue
            $result.LockFile.Valid = ($null -ne $lockProc)
        }
    }

    # Check shim
    $result.ShimExists = Test-Path $result.ShimPath
    if ($result.ShimExists) {
        $resolvedCmd = Get-Command rust-analyzer -ErrorAction SilentlyContinue
        if ($resolvedCmd -and $resolvedCmd.Source -eq $result.ShimPath) {
            $result.ShimPriority = $true
        } elseif ($resolvedCmd -and $resolvedCmd.Source -like '*.cmd') {
            $result.ShimPriority = $true
        }
    }

    # Analyze status and issues
    if ($result.MainProcessCount -eq 0) {
        $result.Status = 'NotRunning'
    } elseif ($result.MainProcessCount -eq 1) {
        if ($result.MemoryMB -gt $WarnThresholdMB) {
            $result.Status = 'HighMemory'
            $result.Issues += "Memory usage ($($result.MemoryMB)MB) exceeds threshold (${WarnThresholdMB}MB)"
            $result.Recommendations += 'Restart rust-analyzer to reclaim memory'
            $result.Recommendations += 'Consider reducing workspace complexity or disabling proc-macros'
        } else {
            $result.Status = 'Healthy'
        }
    } else {
        $result.Status = 'MultipleInstances'
        $result.Issues += "Multiple rust-analyzer processes detected ($($result.MainProcessCount) main, $($result.ProcMacroCount) proc-macro)"
        $result.Recommendations += 'Kill extra instances: Get-Process rust-analyzer | Stop-Process -Force'
        $result.Recommendations += 'Ensure all IDEs use the wrapper shim'
    }

    # Lock file consistency
    if ($result.MainProcessCount -gt 0 -and -not $result.LockFile.Exists) {
        $result.Issues += 'No lock file present - wrapper may not be in use'
        $result.Recommendations += "Configure VS Code: rust-analyzer.server.path = $shimPath"
    }

    if ($result.LockFile.Exists -and -not $result.LockFile.Valid) {
        $result.Issues += "Stale lock file (PID $($result.LockFile.PID) not running)"
        $result.Recommendations += "Remove stale lock: Remove-Item '$($result.LockFile.Path)'"
    }

    # Shim issues
    $shimDir = Split-Path $shimPath -Parent
    if (-not $result.ShimExists) {
        $result.Issues += 'System-wide shim not installed'
        $result.Recommendations += "Create shim at $shimPath"
    } elseif (-not $result.ShimPriority) {
        $result.Issues += 'Shim not first in PATH resolution'
        $result.Recommendations += "Ensure $shimDir is early in PATH"
    }

    # Environment variable checks
    if (-not $env:RA_LRU_CAPACITY) {
        $result.Issues += 'RA_LRU_CAPACITY not set - memory limits not active'
    }

    # Force mode: attempt fixes
    if ($Force -and $result.Issues.Count -gt 0) {
        if ($result.MainProcessCount -gt 1) {
            if (-not $Quiet) { Write-Host 'Killing extra rust-analyzer instances...' -ForegroundColor Yellow }
            $mainProcs | Select-Object -Skip 1 | Stop-Process -Force -ErrorAction SilentlyContinue
            $result.ActionsTaken += "Killed $($result.MainProcessCount - 1) extra rust-analyzer processes"
        }

        if ($result.LockFile.Exists -and -not $result.LockFile.Valid) {
            Remove-Item $result.LockFile.Path -Force -ErrorAction SilentlyContinue
            $result.ActionsTaken += 'Removed stale lock file'
        }

        if ($result.Status -eq 'HighMemory') {
            if (-not $Quiet) { Write-Host 'Restarting rust-analyzer to reclaim memory...' -ForegroundColor Yellow }
            $mainProcs | Stop-Process -Force -ErrorAction SilentlyContinue
            $result.ActionsTaken += 'Killed high-memory rust-analyzer process (will restart on next use)'
        }
    }

    # Output
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '=== Rust-Analyzer Health Check ===' -ForegroundColor Cyan
        Write-Host "Status: $($result.Status)" -ForegroundColor $(
            switch ($result.Status) {
                'Healthy' { 'Green' }
                'NotRunning' { 'Gray' }
                'HighMemory' { 'Yellow' }
                'MultipleInstances' { 'Red' }
                default { 'White' }
            }
        )
        Write-Host "Processes: $($result.MainProcessCount) main, $($result.ProcMacroCount) proc-macro"
        Write-Host "Memory: $($result.MemoryMB)MB (threshold: ${WarnThresholdMB}MB)"
        Write-Host "Lock file: $(if ($result.LockFile.Exists) { 'Present' } else { 'Absent' }) $(if ($result.LockFile.Valid) { '(valid)' } elseif ($result.LockFile.Exists) { '(STALE)' } else { '' })"
        Write-Host "Shim: $(if ($result.ShimExists) { 'Installed' } else { 'Missing' }) $(if ($result.ShimPriority) { '(priority OK)' } else { '' })"

        if ($result.Issues.Count -gt 0) {
            Write-Host ''
            Write-Host 'Issues:' -ForegroundColor Red
            foreach ($issue in $result.Issues) {
                Write-Host "  - $issue" -ForegroundColor Red
            }
        }

        if ($result.Recommendations.Count -gt 0) {
            Write-Host ''
            Write-Host 'Recommendations:' -ForegroundColor Yellow
            foreach ($rec in $result.Recommendations) {
                Write-Host "  - $rec" -ForegroundColor Yellow
            }
        }

        if ($result.ActionsTaken.Count -gt 0) {
            Write-Host ''
            Write-Host 'Actions Taken:' -ForegroundColor Green
            foreach ($action in $result.ActionsTaken) {
                Write-Host "  - $action" -ForegroundColor Green
            }
        }

        Write-Host ''
    }

    # Return in requested format
    switch ($OutputFormat) {
        'Json' {
            return Format-CargoOutput -Data $result -OutputFormat Json -Tool 'rust-analyzer-health' -IncludeContext
        }
        'Object' {
            return Format-CargoOutput -Data $result -OutputFormat Object -Tool 'rust-analyzer-health'
        }
        default {
            return $result
        }
    }
}
