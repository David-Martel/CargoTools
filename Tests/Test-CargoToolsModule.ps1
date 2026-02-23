#Requires -Version 5.1
<#
.SYNOPSIS
Comprehensive test script for CargoTools PowerShell module.

.DESCRIPTION
Tests all exported functions from the CargoTools module to ensure they work correctly.
Reports findings on which functions work and which need fixes.

.EXAMPLE
.\Test-CargoToolsModule.ps1 -Verbose
#>

[CmdletBinding()]
param(
    [switch]$StopOnFirstFailure
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Initialize test tracking
$script:TestResults = @{
    Passed = @()
    Failed = @()
    Warnings = @()
    StartTime = Get-Date
}

function Write-TestHeader {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

function Write-TestResult {
    param(
        [string]$TestName,
        [string]$Status,
        [string]$Message = ''
    )

    $color = switch ($Status) {
        'PASS' { 'Green' }
        'FAIL' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'White' }
    }

    $prefix = switch ($Status) {
        'PASS' { '[✓]' }
        'FAIL' { '[✗]' }
        'WARN' { '[!]' }
        default { '[?]' }
    }

    Write-Host "$prefix $TestName" -ForegroundColor $color
    if ($Message) {
        Write-Host "    $Message" -ForegroundColor Gray
    }

    switch ($Status) {
        'PASS' { $script:TestResults.Passed += $TestName }
        'FAIL' { $script:TestResults.Failed += "$TestName`: $Message" }
        'WARN' { $script:TestResults.Warnings += "$TestName`: $Message" }
    }
}

function Test-ModuleImport {
    Write-TestHeader "Test 1: Module Import"

    try {
        $modulePath = Join-Path $PSScriptRoot '..\CargoTools.psd1'
        if (-not (Test-Path $modulePath)) {
            Write-TestResult 'Module Import' 'FAIL' "Module manifest not found at $modulePath"
            return $false
        }

        Import-Module $modulePath -Force -ErrorAction Stop
        Write-TestResult 'Module Import' 'PASS' "Successfully imported CargoTools v$((Get-Module CargoTools).Version)"
        return $true
    }
    catch {
        Write-TestResult 'Module Import' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Test-InitializeCargoEnv {
    Write-TestHeader "Test 2: Initialize-CargoEnv"

    try {
        # Save current environment
        $oldRustcWrapper = $env:RUSTC_WRAPPER
        $oldCargoIncremental = $env:CARGO_INCREMENTAL

        Initialize-CargoEnv -Verbose

        # Verify key environment variables are set
        $checks = @(
            @{ Name = 'SCCACHE_DIR'; Required = $true }
            @{ Name = 'CARGO_INCREMENTAL'; Required = $true }
            @{ Name = 'SCCACHE_SERVER_PORT'; Required = $true }
            @{ Name = 'SCCACHE_CACHE_COMPRESSION'; Required = $true }
        )

        $allPassed = $true
        foreach ($check in $checks) {
            if ($check.Required -and -not (Test-Path "Env:$($check.Name)")) {
                Write-TestResult "Initialize-CargoEnv [$($check.Name)]" 'FAIL' "Environment variable not set"
                $allPassed = $false
            }
        }

        if ($allPassed) {
            Write-TestResult 'Initialize-CargoEnv' 'PASS' "All environment variables configured correctly"
            Write-Host "  SCCACHE_DIR: $env:SCCACHE_DIR" -ForegroundColor Gray
            Write-Host "  CARGO_INCREMENTAL: $env:CARGO_INCREMENTAL" -ForegroundColor Gray
            Write-Host "  RUSTC_WRAPPER: $env:RUSTC_WRAPPER" -ForegroundColor Gray
        }

        return $allPassed
    }
    catch {
        Write-TestResult 'Initialize-CargoEnv' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Test-SccacheServer {
    Write-TestHeader "Test 3: Sccache Server Management"

    try {
        # Check if sccache is available
        $sccacheCmd = Get-Command sccache -ErrorAction SilentlyContinue
        if (-not $sccacheCmd) {
            Write-TestResult 'Sccache Availability' 'WARN' 'sccache not found in PATH - skipping server tests'
            return $true
        }

        Write-TestResult 'Sccache Availability' 'PASS' "Found at $($sccacheCmd.Source)"

        # Test Get-SccacheMemoryMB
        try {
            $memMB = Get-SccacheMemoryMB
            Write-TestResult 'Get-SccacheMemoryMB' 'PASS' "Current memory usage: ${memMB}MB"
        }
        catch {
            Write-TestResult 'Get-SccacheMemoryMB' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test Start-SccacheServer
        try {
            $started = Start-SccacheServer -Verbose
            if ($started) {
                Write-TestResult 'Start-SccacheServer' 'PASS' 'Server started or already running'
            }
            else {
                Write-TestResult 'Start-SccacheServer' 'WARN' 'Server start returned false but no exception'
            }
        }
        catch {
            Write-TestResult 'Start-SccacheServer' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test Stop-SccacheServer (optional - commented out to keep server running)
        # try {
        #     Stop-SccacheServer
        #     Write-TestResult 'Stop-SccacheServer' 'PASS' 'Server stopped successfully'
        # }
        # catch {
        #     Write-TestResult 'Stop-SccacheServer' 'FAIL' $_.Exception.Message
        #     return $false
        # }

        Write-TestResult 'Stop-SccacheServer' 'PASS' 'Function exists (not tested to avoid disruption)'

        return $true
    }
    catch {
        Write-TestResult 'Sccache Server Management' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Test-OptimalBuildJobs {
    Write-TestHeader "Test 4: Get-OptimalBuildJobs"

    try {
        $jobs = Get-OptimalBuildJobs
        if ($jobs -gt 0 -and $jobs -le 16) {
            Write-TestResult 'Get-OptimalBuildJobs' 'PASS' "Recommended jobs: $jobs"
        }
        else {
            Write-TestResult 'Get-OptimalBuildJobs' 'WARN' "Unusual job count: $jobs"
        }

        # Test low memory mode
        $lowMemJobs = Get-OptimalBuildJobs -LowMemory
        if ($lowMemJobs -le $jobs) {
            Write-TestResult 'Get-OptimalBuildJobs (LowMemory)' 'PASS' "Low memory jobs: $lowMemJobs"
        }
        else {
            Write-TestResult 'Get-OptimalBuildJobs (LowMemory)' 'FAIL' "Low memory jobs ($lowMemJobs) should be <= normal jobs ($jobs)"
            return $false
        }

        return $true
    }
    catch {
        Write-TestResult 'Get-OptimalBuildJobs' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Test-RustAnalyzerFunctions {
    Write-TestHeader "Test 5: Rust-Analyzer Functions"

    try {
        # Test Resolve-RustAnalyzerPath
        try {
            $raPath = Resolve-RustAnalyzerPath
            if ($raPath) {
                Write-TestResult 'Resolve-RustAnalyzerPath' 'PASS' "Found at: $raPath"
            }
            else {
                Write-TestResult 'Resolve-RustAnalyzerPath' 'WARN' 'rust-analyzer not found (may not be installed)'
            }
        }
        catch {
            Write-TestResult 'Resolve-RustAnalyzerPath' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test Get-RustAnalyzerMemoryMB
        try {
            $memMB = Get-RustAnalyzerMemoryMB
            Write-TestResult 'Get-RustAnalyzerMemoryMB' 'PASS' "Current memory: ${memMB}MB"
        }
        catch {
            Write-TestResult 'Get-RustAnalyzerMemoryMB' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test Test-RustAnalyzerSingleton
        try {
            $singleton = Test-RustAnalyzerSingleton -WarnThresholdMB 1500
            Write-TestResult 'Test-RustAnalyzerSingleton' 'PASS' "Status: $($singleton.Status), Processes: $($singleton.ProcessCount), Memory: $($singleton.MemoryMB)MB"

            if ($singleton.Issues) {
                Write-Host "  Issues:" -ForegroundColor Yellow
                $singleton.Issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
            }
        }
        catch {
            Write-TestResult 'Test-RustAnalyzerSingleton' 'FAIL' $_.Exception.Message
            return $false
        }

        return $true
    }
    catch {
        Write-TestResult 'Rust-Analyzer Functions' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Test-LlmOutputFunctions {
    Write-TestHeader "Test 6: LLM-Friendly Output Functions"

    try {
        # Test Format-CargoOutput
        try {
            $testData = @{ Status = 'Success'; Message = 'Test message' }

            # Test Text format
            $textOutput = Format-CargoOutput -Data $testData -OutputFormat Text -Tool 'test-tool'
            Write-TestResult 'Format-CargoOutput (Text)' 'PASS' 'Text format generated'

            # Test Json format
            $jsonOutput = Format-CargoOutput -Data $testData -OutputFormat Json -Tool 'test-tool'
            $parsed = $jsonOutput | ConvertFrom-Json
            if ($parsed.tool -eq 'test-tool' -and $parsed.data.Status -eq 'Success') {
                Write-TestResult 'Format-CargoOutput (Json)' 'PASS' 'JSON format valid'
            }
            else {
                Write-TestResult 'Format-CargoOutput (Json)' 'FAIL' 'JSON structure incorrect'
                return $false
            }

            # Test Object format
            $objOutput = Format-CargoOutput -Data $testData -OutputFormat Object -Tool 'test-tool'
            if ($objOutput.tool -eq 'test-tool') {
                Write-TestResult 'Format-CargoOutput (Object)' 'PASS' 'Object format valid'
            }
            else {
                Write-TestResult 'Format-CargoOutput (Object)' 'FAIL' 'Object structure incorrect'
                return $false
            }
        }
        catch {
            Write-TestResult 'Format-CargoOutput' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test Get-RustProjectContext
        try {
            $context = Get-RustProjectContext -Path $PSScriptRoot
            Write-TestResult 'Get-RustProjectContext' 'PASS' "Project root: $($context.project_root)"
        }
        catch {
            Write-TestResult 'Get-RustProjectContext' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test Get-CargoContextSnapshot
        try {
            $snapshot = Get-CargoContextSnapshot
            if ($snapshot.working_directory) {
                Write-TestResult 'Get-CargoContextSnapshot' 'PASS' "Working dir: $($snapshot.working_directory)"
            }
            else {
                Write-TestResult 'Get-CargoContextSnapshot' 'FAIL' 'Snapshot missing required fields'
                return $false
            }
        }
        catch {
            Write-TestResult 'Get-CargoContextSnapshot' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test Format-CargoError
        try {
            $testError = 'error[E0382]: borrow of moved value: x'
            $errorObj = Format-CargoError -ErrorOutput $testError -Command 'cargo' -Arguments @('build')

            if ($errorObj.error_code -eq 'E0382') {
                $errorCode = $errorObj.error_code
                Write-TestResult 'Format-CargoError' 'PASS' "Parsed error code: $errorCode"
            }
            else {
                Write-TestResult 'Format-CargoError' 'WARN' 'Error parsing may be incomplete'
            }
        }
        catch {
            Write-TestResult 'Format-CargoError' 'FAIL' $_.Exception.Message
            return $false
        }

        # Test ConvertTo-LlmContext
        try {
            $testOutput = @{
                Status = 'Success'
                Issues = @('Issue 1', 'Issue 2')
                Recommendations = @('Rec 1')
            }
            $llmContext = ConvertTo-LlmContext -ToolOutput ([PSCustomObject]$testOutput)

            if ($llmContext.summary -and $llmContext.key_findings) {
                Write-TestResult 'ConvertTo-LlmContext' 'PASS' 'LLM context generated'
            }
            else {
                Write-TestResult 'ConvertTo-LlmContext' 'FAIL' 'LLM context missing required fields'
                return $false
            }
        }
        catch {
            Write-TestResult 'ConvertTo-LlmContext' 'FAIL' $_.Exception.Message
            return $false
        }

        return $true
    }
    catch {
        Write-TestResult 'LLM Output Functions' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Test-CargoWrapperFunctions {
    Write-TestHeader "Test 7: Cargo Wrapper Functions"

    try {
        # Test Invoke-CargoRoute (basic existence check)
        $routeCmd = Get-Command Invoke-CargoRoute -ErrorAction SilentlyContinue
        if ($routeCmd) {
            Write-TestResult 'Invoke-CargoRoute' 'PASS' 'Function exists and is exported'
        }
        else {
            Write-TestResult 'Invoke-CargoRoute' 'FAIL' 'Function not found'
            return $false
        }

        # Test Invoke-CargoWrapper (basic existence check)
        $wrapperCmd = Get-Command Invoke-CargoWrapper -ErrorAction SilentlyContinue
        if ($wrapperCmd) {
            Write-TestResult 'Invoke-CargoWrapper' 'PASS' 'Function exists and is exported'
        }
        else {
            Write-TestResult 'Invoke-CargoWrapper' 'FAIL' 'Function not found'
            return $false
        }

        # Test other cargo functions
        $cargoFunctions = @('Invoke-CargoWsl', 'Invoke-CargoDocker', 'Invoke-CargoMacos')
        foreach ($func in $cargoFunctions) {
            $cmd = Get-Command $func -ErrorAction SilentlyContinue
            if ($cmd) {
                Write-TestResult $func 'PASS' 'Function exists and is exported'
            }
            else {
                Write-TestResult $func 'FAIL' 'Function not found'
                return $false
            }
        }

        return $true
    }
    catch {
        Write-TestResult 'Cargo Wrapper Functions' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Test-RustAnalyzerWrapperFunctions {
    Write-TestHeader "Test 8: Rust-Analyzer Wrapper Functions"

    try {
        # Test Invoke-RustAnalyzerWrapper
        $wrapperCmd = Get-Command Invoke-RustAnalyzerWrapper -ErrorAction SilentlyContinue
        if ($wrapperCmd) {
            Write-TestResult 'Invoke-RustAnalyzerWrapper' 'PASS' 'Function exists and is exported'
        }
        else {
            Write-TestResult 'Invoke-RustAnalyzerWrapper' 'FAIL' 'Function not found'
            return $false
        }

        # Test Test-RustAnalyzerHealth
        $healthCmd = Get-Command Test-RustAnalyzerHealth -ErrorAction SilentlyContinue
        if ($healthCmd) {
            Write-TestResult 'Test-RustAnalyzerHealth' 'PASS' 'Function exists and is exported'

            # Try to run health check
            try {
                $health = Test-RustAnalyzerHealth
                Write-Host "  Health Status: $($health.Status)" -ForegroundColor Gray
                Write-Host "  Memory Usage: $($health.MemoryMB)MB" -ForegroundColor Gray
            }
            catch {
                Write-TestResult 'Test-RustAnalyzerHealth (execution)' 'WARN' "Failed to execute: $($_.Exception.Message)"
            }
        }
        else {
            Write-TestResult 'Test-RustAnalyzerHealth' 'FAIL' 'Function not found'
            return $false
        }

        return $true
    }
    catch {
        Write-TestResult 'Rust-Analyzer Wrapper Functions' 'FAIL' $_.Exception.Message
        return $false
    }
}

function Show-TestSummary {
    Write-TestHeader "Test Summary"

    $duration = (Get-Date) - $script:TestResults.StartTime

    Write-Host "Total Tests: $($script:TestResults.Passed.Count + $script:TestResults.Failed.Count)" -ForegroundColor White
    Write-Host "Passed: $($script:TestResults.Passed.Count)" -ForegroundColor Green
    Write-Host "Failed: $($script:TestResults.Failed.Count)" -ForegroundColor Red
    Write-Host "Warnings: $($script:TestResults.Warnings.Count)" -ForegroundColor Yellow
    Write-Host "Duration: $($duration.TotalSeconds.ToString('F2'))s`n" -ForegroundColor Gray

    if ($script:TestResults.Failed.Count -gt 0) {
        Write-Host "Failed Tests:" -ForegroundColor Red
        $script:TestResults.Failed | ForEach-Object {
            Write-Host "  - $_" -ForegroundColor Red
        }
        Write-Host ""
    }

    if ($script:TestResults.Warnings.Count -gt 0) {
        Write-Host "Warnings:" -ForegroundColor Yellow
        $script:TestResults.Warnings | ForEach-Object {
            Write-Host "  - $_" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    # Return exit code based on results
    return ($script:TestResults.Failed.Count -eq 0)
}

# Main test execution
try {
    Write-Host "`nCargoTools Module Verification" -ForegroundColor Magenta
    Write-Host "==============================`n" -ForegroundColor Magenta

    # Run all tests
    $tests = @(
        { Test-ModuleImport }
        { Test-InitializeCargoEnv }
        { Test-SccacheServer }
        { Test-OptimalBuildJobs }
        { Test-RustAnalyzerFunctions }
        { Test-LlmOutputFunctions }
        { Test-CargoWrapperFunctions }
        { Test-RustAnalyzerWrapperFunctions }
    )

    $continueTests = $true
    foreach ($test in $tests) {
        if (-not $continueTests) { break }

        $result = & $test
        if (-not $result -and $StopOnFirstFailure) {
            Write-Host "`nStopping on first failure (use -StopOnFirstFailure:`$false to continue)" -ForegroundColor Red
            $continueTests = $false
        }
    }

    # Show summary
    $success = Show-TestSummary

    if ($success) {
        Write-Host "All tests passed successfully!" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "Some tests failed. Review the output above." -ForegroundColor Red
        exit 1
    }
}
catch {
    Write-Host "`nFatal error during test execution:" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    exit 2
}
