#Requires -Modules Pester
<#
.SYNOPSIS
Pester tests for Invoke-RustAnalyzerWrapper and related functions.
.DESCRIPTION
Tests singleton enforcement, path resolution, memory limits, and lock file lifecycle.
#>

BeforeAll {
    # Import the module
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    # Test fixtures
    $script:TestLockDir = Join-Path $env:TEMP 'CargoTools-Tests'
    $script:TestLockFile = Join-Path $script:TestLockDir 'test-ra.lock'

    # Ensure test directory exists
    if (-not (Test-Path $script:TestLockDir)) {
        New-Item -ItemType Directory -Path $script:TestLockDir -Force | Out-Null
    }

    $script:FastCacheRoot = if ($env:CARGOTOOLS_CACHE_ROOT) {
        $env:CARGOTOOLS_CACHE_ROOT
    } elseif ($env:PCAI_CACHE_ROOT) {
        $env:PCAI_CACHE_ROOT
    } elseif (Test-Path 'T:\RustCache') {
        'T:\RustCache'
    } else {
        Join-Path $env:LOCALAPPDATA 'RustCache'
    }
}

AfterAll {
    # Cleanup test artifacts
    if (Test-Path $script:TestLockDir) {
        Remove-Item $script:TestLockDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-RustAnalyzerPath' {
    Context 'When RUST_ANALYZER_PATH is set' {
        It 'Should return the environment variable path if valid' {
            # Create a temp file to simulate rust-analyzer
            $tempFile = Join-Path $script:TestLockDir 'fake-ra.exe'
            Set-Content -Path $tempFile -Value ('X' * 2000) # >1000 bytes

            $env:RUST_ANALYZER_PATH = $tempFile
            try {
                $result = Resolve-RustAnalyzerPath
                $result | Should -Be $tempFile
            } finally {
                Remove-Item Env:RUST_ANALYZER_PATH -ErrorAction SilentlyContinue
                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
        }

        It 'Should skip invalid RUST_ANALYZER_PATH and continue resolution' {
            $env:RUST_ANALYZER_PATH = 'C:\NonExistent\rust-analyzer.exe'
            try {
                $result = Resolve-RustAnalyzerPath
                # Should return something else or null, not the invalid path
                $result | Should -Not -Be 'C:\NonExistent\rust-analyzer.exe'
            } finally {
                Remove-Item Env:RUST_ANALYZER_PATH -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'When using rustup toolchain' {
        It 'Should find rust-analyzer in stable toolchain' {
            $expectedPath = Join-Path $script:FastCacheRoot 'rustup\toolchains\stable-x86_64-pc-windows-msvc\bin\rust-analyzer.exe'
            if (Test-Path $expectedPath) {
                $result = Resolve-RustAnalyzerPath
                $result | Should -Not -BeNullOrEmpty
                # Verify the file is not empty
                (Get-Item $result).Length | Should -BeGreaterThan 1000
            } else {
                Set-ItResult -Skipped -Because 'rust-analyzer not installed via rustup'
            }
        }
    }

    Context 'Validation' {
        It 'Should reject empty files (0-byte shims)' {
            $emptyFile = Join-Path $script:TestLockDir 'empty-ra.exe'
            Set-Content -Path $emptyFile -Value '' # 0 bytes

            $env:RUST_ANALYZER_PATH = $emptyFile
            try {
                # Since it's empty, should fall through to other resolution methods
                # or return null/different path
                $result = Resolve-RustAnalyzerPath
                if ($result -eq $emptyFile) {
                    # This would be a bug - verify file size check works
                    $result | Should -Not -Be $emptyFile -Because 'empty files should be rejected'
                }
            } finally {
                Remove-Item Env:RUST_ANALYZER_PATH -ErrorAction SilentlyContinue
                Remove-Item $emptyFile -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Test-RustAnalyzerSingleton' {
    Context 'When no rust-analyzer is running' {
        It 'Should report NotRunning status' {
            # Kill any running instances for clean test
            Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500

            $result = Test-RustAnalyzerSingleton
            $result.Status | Should -Be 'NotRunning'
            $result.ProcessCount | Should -Be 0
        }
    }

    Context 'Lock file validation' {
        It 'Should detect stale lock files' {
            # Create a lock file with non-existent PID
            $lockFile = Join-Path $script:FastCacheRoot 'rust-analyzer\ra.lock'
            $lockDir = Split-Path $lockFile -Parent
            if (-not (Test-Path $lockDir)) {
                New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
            }

            # Use a PID that definitely doesn't exist
            Set-Content -Path $lockFile -Value '999999'

            try {
                $result = Test-RustAnalyzerSingleton
                $result.LockFileExists | Should -Be $true
                # Check that at least one issue contains "Stale"
                ($result.Issues -join ' ') | Should -BeLike '*Stale*'
            } finally {
                Remove-Item $lockFile -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Memory threshold' {
        It 'Should accept custom warning threshold' {
            $result = Test-RustAnalyzerSingleton -WarnThresholdMB 500
            # Just verify it accepts the parameter
            $result | Should -Not -BeNull
        }
    }
}

Describe 'Get-RustAnalyzerMemoryMB' {
    It 'Should return 0 when no rust-analyzer is running' {
        Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500

        $result = Get-RustAnalyzerMemoryMB
        $result | Should -Be 0
    }

    It 'Should return positive value when rust-analyzer is running' {
        $raPath = Resolve-RustAnalyzerPath
        if (-not $raPath) {
            Set-ItResult -Skipped -Because 'rust-analyzer not installed'
            return
        }

        # Start rust-analyzer with --version to quickly get a process
        $proc = Start-Process -FilePath $raPath -ArgumentList '--version' -PassThru -NoNewWindow
        Start-Sleep -Milliseconds 200

        try {
            $running = Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue
            if ($running) {
                $result = Get-RustAnalyzerMemoryMB
                $result | Should -BeGreaterThan 0
            }
        } finally {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Invoke-RustAnalyzerWrapper' {
    Context 'Help' {
        It 'Should display help with --help flag' {
            $result = Invoke-RustAnalyzerWrapper --help 6>&1
            $result | Should -Not -BeNullOrEmpty
        }

        It 'Help includes --memory-limit documentation' {
            $result = Invoke-RustAnalyzerWrapper --help 6>&1
            $output = $result -join "`n"
            $output | Should -BeLike '*--memory-limit*'
        }

        It 'Help includes --no-proc-macros documentation' {
            $result = Invoke-RustAnalyzerWrapper --help 6>&1
            $output = $result -join "`n"
            $output | Should -BeLike '*--no-proc-macros*'
        }

        It 'Help includes --generate-config documentation' {
            $result = Invoke-RustAnalyzerWrapper --help 6>&1
            $output = $result -join "`n"
            $output | Should -BeLike '*--generate-config*'
        }

        It 'Help includes RA_MEMORY_LIMIT_MB env var' {
            $result = Invoke-RustAnalyzerWrapper --help 6>&1
            $output = $result -join "`n"
            $output | Should -BeLike '*RA_MEMORY_LIMIT_MB*'
        }
    }

    Context 'Environment variables' {
        It 'Should set RA_LRU_CAPACITY via Initialize-CargoEnv' {
            Remove-Item Env:RA_LRU_CAPACITY -ErrorAction SilentlyContinue

            # Initialize-CargoEnv sets the rust-analyzer env vars
            Initialize-CargoEnv

            $env:RA_LRU_CAPACITY | Should -Be '64'
        }

        It 'Should set CHALK_SOLVER_MAX_SIZE via Initialize-CargoEnv' {
            Remove-Item Env:CHALK_SOLVER_MAX_SIZE -ErrorAction SilentlyContinue

            Initialize-CargoEnv

            $env:CHALK_SOLVER_MAX_SIZE | Should -Be '10'
        }

        It 'Should set RA_PROC_MACRO_WORKERS via Initialize-CargoEnv' {
            Remove-Item Env:RA_PROC_MACRO_WORKERS -ErrorAction SilentlyContinue

            Initialize-CargoEnv

            $env:RA_PROC_MACRO_WORKERS | Should -Be '1'
        }
    }
}

Describe 'Proc-macro disable' {
    It '--no-proc-macros sets RA_PROC_MACRO_WORKERS=0' {
        $savedWorkers = $env:RA_PROC_MACRO_WORKERS
        $env:RA_PROC_MACRO_WORKERS = '1'
        try {
            # Invoke with --no-proc-macros and --help to avoid starting RA
            # The flag is parsed before --help returns, so we check the env after
            # We need to call the function in a way that sets the env but doesn't launch RA
            # The simplest approach: invoke the wrapper with --generate-config in a temp dir
            # that way it returns 0 quickly and the env is set
            $tempDir = Join-Path $env:TEMP "CargoTools-ProcMacroTest-$(Get-Random)"
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
            try {
                Push-Location $tempDir
                Invoke-RustAnalyzerWrapper --no-proc-macros --generate-config | Out-Null
                Pop-Location
                $env:RA_PROC_MACRO_WORKERS | Should -Be '0'
            } finally {
                Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } finally {
            if ($null -ne $savedWorkers) { $env:RA_PROC_MACRO_WORKERS = $savedWorkers }
            else { Remove-Item Env:RA_PROC_MACRO_WORKERS -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Generate config' {
    It '--generate-config creates rust-analyzer.toml' {
        $tempDir = Join-Path $env:TEMP "CargoTools-GenConfigTest-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            Push-Location $tempDir
            Invoke-RustAnalyzerWrapper --generate-config | Out-Null
            Pop-Location
            $configPath = Join-Path $tempDir 'rust-analyzer.toml'
            Test-Path $configPath | Should -Be $true
            $content = Get-Content $configPath -Raw
            $content | Should -BeLike '*check*'
            $content | Should -BeLike '*clippy*'
        } finally {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '--generate-config merges with existing config' {
        $tempDir = Join-Path $env:TEMP "CargoTools-MergeConfigTest-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            # Write a partial config first
            $configPath = Join-Path $tempDir 'rust-analyzer.toml'
            Set-Content -Path $configPath -Value @"
[check]
command = "check"
"@
            Push-Location $tempDir
            Invoke-RustAnalyzerWrapper --generate-config | Out-Null
            Pop-Location
            $content = Get-Content $configPath -Raw
            # Existing value should be preserved (check, not clippy)
            $content | Should -BeLike '*command = "check"*'
            # New sections should be added
            $content | Should -BeLike '*procMacro*'
        } finally {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '--generate-config returns exit code 0' {
        $tempDir = Join-Path $env:TEMP "CargoTools-ExitConfigTest-$(Get-Random)"
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        try {
            Push-Location $tempDir
            $result = Invoke-RustAnalyzerWrapper --generate-config
            Pop-Location
            $result | Should -Be 0
        } finally {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'System-wide shim' {
    Context 'C:\Users\david\.local\bin\rust-analyzer.cmd' {
        It 'Should exist' {
            $shimPath = 'C:\Users\david\.local\bin\rust-analyzer.cmd'
            Test-Path $shimPath | Should -Be $true
        }

        It 'Should resolve before any rust-analyzer.exe in PATH' {
            $cmd = Get-Command rust-analyzer -ErrorAction SilentlyContinue
            if ($cmd) {
                # Should be a CargoTools shim (.cmd or .ps1) deployed to either ~/.local/bin or ~/bin,
                # not rustup's rust-analyzer.exe.
                $cmd.Source | Should -Match '\\(\.local\\bin|bin)\\rust-analyzer.*\.(cmd|ps1)$'
            } else {
                Set-ItResult -Skipped -Because 'rust-analyzer not in PATH'
            }
        }
    }
}

Describe 'Get-RustAnalyzerTransportStatus' {
        It 'Reports transport information without throwing' {
            $status = Get-RustAnalyzerTransportStatus
            $status | Should -Not -BeNullOrEmpty
            $status.PSObject.Properties.Name | Should -Contain 'Effective'
            $status.PSObject.Properties.Name | Should -Contain 'LspmuxAvailable'
            $status.PSObject.Properties.Name | Should -Contain 'LspmuxConfigPath'
            $status.PSObject.Properties.Name | Should -Contain 'LspmuxStatusTimedOut'
        }

        It 'Uses direct transport for standalone commands by default' {
            $status = Get-RustAnalyzerTransportStatus -ArgumentList @('--version')
            $status.Effective | Should -Be 'direct'
            $status.StandaloneInvocation | Should -Be $true
        }
    }

Describe 'Integration Tests' -Tag 'Integration' {
    Context 'Full singleton workflow' {
        It 'Should enforce singleton via lock file' -Skip:$true {
            # This test requires killing existing rust-analyzer processes
            # which may disrupt VS Code or other IDEs. Skip in automated runs.
            # Run manually with: Invoke-Pester -TagFilter 'Integration'

            $raPath = Resolve-RustAnalyzerPath
            if (-not $raPath) {
                Set-ItResult -Skipped -Because 'rust-analyzer not installed'
                return
            }

            # Ensure clean state
            Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $script:FastCacheRoot 'rust-analyzer\ra.lock') -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500

            # Start first instance via wrapper
            $job = Start-Job -ScriptBlock {
                param($modulePath)
                Import-Module $modulePath -Force
                Invoke-RustAnalyzerWrapper --version
            } -ArgumentList (Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\Modules\CargoTools\CargoTools.psd1')

            Start-Sleep -Seconds 2

            # Verify lock file created
            Test-Path (Join-Path $script:FastCacheRoot 'rust-analyzer\ra.lock') | Should -Be $true

            # Cleanup
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -ErrorAction SilentlyContinue
            Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue |
                Stop-Process -Force -ErrorAction SilentlyContinue
        }

        It 'Should have lock file directory accessible' {
            $lockDir = Join-Path $script:FastCacheRoot 'rust-analyzer'
            if (-not (Test-Path $lockDir)) {
                New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
            }
            Test-Path $lockDir | Should -Be $true
        }
    }
}
