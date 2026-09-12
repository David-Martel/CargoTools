#Requires -Modules Pester

BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1') -Force
    $script:savedEnvironment = @{}
    $script:controlledEnvironment = @(
        'CARGO_RAW', 'CARGOTOOLS_ENFORCE_QUALITY', 'CARGOTOOLS_RUN_TESTS_AFTER_BUILD',
        'CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD', 'CARGO_USE_NEXTEST', 'CARGO_RA_PREFLIGHT',
        'CARGO_PREFLIGHT', 'CARGO_VERBOSITY', 'CARGO_LLM_DEBUG', 'CARGO_TIMINGS',
        'CARGO_QUICK_CHECK', 'CARGO_RELEASE_LTO', 'RUSTC_WRAPPER',
        'CARGOTOOLS_CONTRACT_LOG', 'CARGOTOOLS_CONTRACT_FIXTURE',
        'CARGOTOOLS_CONTRACT_SHIM', 'CARGOTOOLS_CONTRACT_PWSH',
        'CARGOTOOLS_CONTRACT_FAIL_COMMAND', 'CARGOTOOLS_CONTRACT_EXIT'
    )
    foreach ($name in $script:controlledEnvironment) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:CARGOTOOLS_CONTRACT_PWSH = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $env:CARGOTOOLS_CONTRACT_LOG = Join-Path $TestDrive 'native-argv.jsonl'
    $env:CARGOTOOLS_CONTRACT_FIXTURE = Join-Path $TestDrive 'native-fixture.ps1'
    $env:CARGOTOOLS_CONTRACT_SHIM = Join-Path $TestDrive 'rustup-fixture.ps1'
    # Only the external Rust toolchain is substituted. The real wrapper, argument
    # selectors, and native PowerShell argv boundary run in every applicable test.
    @'
[IO.File]::AppendAllText($env:CARGOTOOLS_CONTRACT_LOG, (ConvertTo-Json -InputObject @($args) -Compress) + [Environment]::NewLine)
if ($args -contains $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND -and $args -notcontains '--version') {
    exit [int]$env:CARGOTOOLS_CONTRACT_EXIT
}
exit 0
'@ | Set-Content -LiteralPath $env:CARGOTOOLS_CONTRACT_FIXTURE
    @'
& $env:CARGOTOOLS_CONTRACT_PWSH -NoProfile -File $env:CARGOTOOLS_CONTRACT_FIXTURE @args
'@ | Set-Content -LiteralPath $env:CARGOTOOLS_CONTRACT_SHIM

    function Read-NativeCall {
        if (Test-Path -LiteralPath $env:CARGOTOOLS_CONTRACT_LOG) {
            foreach ($line in Get-Content -LiteralPath $env:CARGOTOOLS_CONTRACT_LOG) {
                ,@($line | ConvertFrom-Json)
            }
        }
    }
}

AfterAll {
    foreach ($name in $script:controlledEnvironment) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
    }
}

Describe 'Invoke-CargoWrapper native argv and status contract' {
    BeforeEach {
        foreach ($name in $script:controlledEnvironment | Where-Object { $_ -notlike 'CARGOTOOLS_CONTRACT_*' }) {
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $env:CARGOTOOLS_ENFORCE_QUALITY = '1'
        $env:CARGOTOOLS_RUN_TESTS_AFTER_BUILD = '0'
        $env:CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD = '0'
        $env:CARGO_USE_NEXTEST = '0'
        $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND = 'clippy'
        $env:CARGOTOOLS_CONTRACT_EXIT = '37'
        Remove-Item -LiteralPath $env:CARGOTOOLS_CONTRACT_LOG -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
        Mock Resolve-CacheRoot -ModuleName CargoTools { $TestDrive }
        Mock Ensure-MsvcEnv -ModuleName CargoTools {}
        Mock Initialize-CargoEnv -ModuleName CargoTools {}
        Mock Test-CargoMachineDependencies -ModuleName CargoTools { [pscustomobject]@{ Passed = $true } }
        Mock Resolve-LldLinker -ModuleName CargoTools { $null }
        Mock Apply-LinkerSettings -ModuleName CargoTools { $false }
        Mock Apply-NativeCpuFlag -ModuleName CargoTools {}
        Mock Start-SccacheServer -ModuleName CargoTools { $true }
        Mock Enter-CargoBuildQueue -ModuleName CargoTools { [pscustomobject]@{ TicketPath = 'fixture-ticket' } }
        Mock Exit-CargoBuildQueue -ModuleName CargoTools {
            & $env:CARGOTOOLS_CONTRACT_PWSH -NoProfile -Command 'exit 0'
        }
        Mock Get-RustupPath -ModuleName CargoTools { $env:CARGOTOOLS_CONTRACT_SHIM }
        Mock Resolve-CargoToolchain -ModuleName CargoTools { 'stable' }
        Mock Apply-PreflightEnvDefaults -ModuleName CargoTools { @{ Enabled = $false; RA = $false; Blocking = $true } }
        Mock Apply-PreflightIdeGuard -ModuleName CargoTools { param($State) $State }
        Mock Write-CargoStatus -ModuleName CargoTools {}
        Mock Write-CargoBuildPhase -ModuleName CargoTools {}
        Mock Write-CargoDebug -ModuleName CargoTools {}
        Mock Format-CargoDiagnostics -ModuleName CargoTools { 'fixture diagnostics' }
        Mock Show-SccacheStatus -ModuleName CargoTools {
            & $env:CARGOTOOLS_CONTRACT_PWSH -NoProfile -Command 'exit 0'
        }
        Mock Test-AutoCopyEnabled -ModuleName CargoTools { $false }
        & (Get-Module CargoTools) { $script:LlmOutputMode = $false }
    }

    It 'preserves native autofix argv with <Label> retained options' -ForEach @(
        @{ Label = 'zero'; CargoArgs = @('test', 'filter'); Expected = @() }
        @{ Label = 'one'; CargoArgs = @('test', '--all-targets'); Expected = @('--all-targets') }
        @{ Label = 'several'; CargoArgs = @('test', '--workspace', '-p', 'worker', 'filter', '--', '--exact'); Expected = @('--workspace', '-p', 'worker') }
    ) {
        $result = @(Invoke-CargoWrapper -ArgumentList $CargoArgs)
        $exitCode = $global:LASTEXITCODE
        $calls = @(Read-NativeCall)
        $calls.Count | Should -Be 1
        $calls[0] | Should -Be (@('run', 'stable', 'cargo', 'clippy', '--fix', '--allow-dirty', '--allow-staged', '--allow-no-vcs') + $Expected)
        $result[-1] | Should -Be 37
        $exitCode | Should -Be 37
    }

    It 'retains an explicit raw separator and wrapper-looking child switches' {
        $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND = 'never'
        $result = @(Invoke-CargoWrapper -ArgumentList @('--raw', 'test', 'filter', '--', '--nocapture', '--nextest', '--fix'))
        $exitCode = $global:LASTEXITCODE
        $calls = @(Read-NativeCall)
        $calls.Count | Should -Be 1
        $calls[0] | Should -Be @('run', 'stable', 'cargo', 'test', 'filter', '--', '--nocapture', '--nextest', '--fix')
        $result[-1] | Should -Be 0
        $exitCode | Should -Be 0
    }

    It 'publishes raw native failure' {
        $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND = 'test'
        $result = @(Invoke-CargoWrapper -ArgumentList @('--raw', 'test'))
        $result[-1] | Should -Be 37
        $global:LASTEXITCODE | Should -Be 37
    }

    It 'preserves <Phase> failures through diagnostics and queue cleanup' -ForEach @(
        @{ Phase = 'clippy' }, @{ Phase = 'fmt' }, @{ Phase = 'test' }
    ) {
        $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND = $Phase
        Mock Write-CargoStatus -ModuleName CargoTools {
            & $env:CARGOTOOLS_CONTRACT_PWSH -NoProfile -Command 'exit 0'
        } -ParameterFilter { $Type -eq 'Error' }
        $result = @(Invoke-CargoWrapper -ArgumentList @('test'))
        $exitCode = $global:LASTEXITCODE
        $result[-1] | Should -Be 37
        $exitCode | Should -Be 37
        Should -Invoke Exit-CargoBuildQueue -ModuleName CargoTools -Times 1 -Exactly
    }

    It 'publishes successful completion after successful cleanup' {
        $global:LASTEXITCODE = 37
        $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND = 'never'
        $result = @(Invoke-CargoWrapper -ArgumentList @('test'))
        $exitCode = $global:LASTEXITCODE
        @(Read-NativeCall).Count | Should -Be 3
        $result[-1] | Should -Be 0
        $exitCode | Should -Be 0
    }

    It 'publishes wrapper-only success without launching native Cargo' {
        $global:LASTEXITCODE = 37
        $result = @(Invoke-CargoWrapper --wrapper-help 6>$null)
        $result[-1] | Should -Be 0
        $global:LASTEXITCODE | Should -Be 0
        @(Read-NativeCall).Count | Should -Be 0
    }

    It 'publishes dependency failure without launching native Cargo' {
        Mock Test-CargoMachineDependencies -ModuleName CargoTools { [pscustomobject]@{ Passed = $false; MissingMandatory = @('fixture') } }
        $result = @(Invoke-CargoWrapper -ArgumentList @('test'))
        $result[-1] | Should -Be 1
        $global:LASTEXITCODE | Should -Be 1
        @(Read-NativeCall).Count | Should -Be 0
    }

    It 'publishes missing raw toolchain failure without stale success' {
        Mock Get-RustupPath -ModuleName CargoTools { Join-Path $env:CARGOTOOLS_CONTRACT_LOG 'missing' }
        $result = @(Invoke-CargoWrapper -ArgumentList @('--raw', 'test') -ErrorAction SilentlyContinue)
        $result[-1] | Should -Be 1
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'preserves <Phase> preflight status with no main Cargo invocation' -ForEach @(
        @{ Phase = 'standard'; RA = $false; ExpectedExit = 29 }
        @{ Phase = 'rust-analyzer'; RA = $true; ExpectedExit = 31 }
    ) {
        $env:CARGOTOOLS_ENFORCE_QUALITY = '0'
        Mock Apply-PreflightEnvDefaults -ModuleName CargoTools { @{ Enabled = -not $RA; RA = $RA; Blocking = $true } }.GetNewClosure()
        Mock Invoke-PreflightLocal -ModuleName CargoTools { 29 }
        Mock Invoke-RaDiagnosticsLocal -ModuleName CargoTools { 31 }
        $result = @(Invoke-CargoWrapper -ArgumentList @('test'))
        $result[-1] | Should -Be $ExpectedExit
        $global:LASTEXITCODE | Should -Be $ExpectedExit
        @(Read-NativeCall).Count | Should -Be 0
    }

    It 'preserves <Phase> post-build native failures' -ForEach @(
        @{ Phase = 'nextest'; FailCommand = 'nextest'; Doctests = '0' }
        @{ Phase = 'doctest'; FailCommand = '--doc'; Doctests = '1' }
    ) {
        $env:CARGOTOOLS_RUN_TESTS_AFTER_BUILD = '1'
        $env:CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD = $Doctests
        $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND = $FailCommand
        Mock Write-CargoBuildPhase -ModuleName CargoTools {
            & $env:CARGOTOOLS_CONTRACT_PWSH -NoProfile -Command 'exit 0'
        } -ParameterFilter { $Failed }
        $result = @(Invoke-CargoWrapper -ArgumentList @('build'))
        $result[-1] | Should -Be 37
        $global:LASTEXITCODE | Should -Be 37
    }

    It 'publishes exception failure even when setup previously returned native success' {
        Mock Initialize-CargoEnv -ModuleName CargoTools {
            & $env:CARGOTOOLS_CONTRACT_PWSH -NoProfile -Command 'exit 0'
            throw 'fixture setup failure'
        }
        { Invoke-CargoWrapper -ArgumentList @('test') } | Should -Throw '*fixture setup failure*'
        $global:LASTEXITCODE | Should -Be 1
    }

    It 'publishes failure when cleanup throws after successful Cargo' {
        $env:CARGOTOOLS_CONTRACT_FAIL_COMMAND = 'never'
        Mock Exit-CargoBuildQueue -ModuleName CargoTools { throw 'fixture cleanup failure' }
        { Invoke-CargoWrapper -ArgumentList @('test') } | Should -Throw '*fixture cleanup failure*'
        $global:LASTEXITCODE | Should -Be 1
    }
}
