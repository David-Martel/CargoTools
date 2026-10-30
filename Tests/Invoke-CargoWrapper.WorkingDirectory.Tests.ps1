#Requires -Modules Pester

BeforeAll {
    Set-StrictMode -Version Latest
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1') -Force
    $script:originalLocation = Get-Location
    $script:controlledEnvironment = @(
        'CARGO_RAW', 'CARGOTOOLS_ENFORCE_QUALITY', 'CARGOTOOLS_AUTO_FIX',
        'CARGOTOOLS_RUN_TESTS_AFTER_BUILD', 'CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD',
        'CARGO_USE_NEXTEST', 'CARGO_RA_PREFLIGHT', 'CARGO_PREFLIGHT', 'CARGO_VERBOSITY',
        'CARGO_LLM_DEBUG', 'CARGO_TIMINGS', 'CARGOTOOLS_RA_PREFLIGHT',
        'CARGOTOOLS_PREFLIGHT_MODE', 'CARGO_PREFLIGHT_FORCE', 'CARGO_PREFLIGHT_MODE',
        'CARGO_PREFLIGHT_STRICT', 'CARGO_PREFLIGHT_BLOCKING', 'CARGO_PREFLIGHT_IDE_GUARD',
        'CARGO_QUICK_CHECK', 'CARGO_RELEASE_LTO', 'RUSTC_WRAPPER',
        'CARGOTOOLS_CWD_PWSH', 'CARGOTOOLS_CWD_LOG', 'CARGOTOOLS_CWD_FIXTURE',
        'CARGOTOOLS_CWD_SHIM', 'CARGOTOOLS_CWD_EXIT', 'CARGOTOOLS_CWD_THROW'
    )
    $script:savedEnvironment = @{}
    foreach ($name in $script:controlledEnvironment) {
        $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $exitVariable = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $script:hadLastExitCode = $null -ne $exitVariable
    $script:savedLastExitCode = if ($script:hadLastExitCode) { $exitVariable.Value } else { $null }
    $env:CARGOTOOLS_CWD_PWSH = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $env:CARGOTOOLS_CWD_LOG = Join-Path $TestDrive 'native-cwd.jsonl'
    $env:CARGOTOOLS_CWD_FIXTURE = Join-Path $TestDrive 'native-cwd.ps1'
    $env:CARGOTOOLS_CWD_SHIM = Join-Path $TestDrive 'rustup-cwd.ps1'
    @'
[IO.File]::AppendAllText($env:CARGOTOOLS_CWD_LOG, (ConvertTo-Json -InputObject @{ cwd = (Get-Location).ProviderPath; argv = @($args) } -Compress) + [Environment]::NewLine)
exit [int]$env:CARGOTOOLS_CWD_EXIT
'@ | Set-Content -LiteralPath $env:CARGOTOOLS_CWD_FIXTURE
    @'
if ($env:CARGOTOOLS_CWD_THROW -eq '1') {
    [IO.File]::AppendAllText($env:CARGOTOOLS_CWD_LOG, (ConvertTo-Json -InputObject @{ cwd = (Get-Location).ProviderPath; argv = @($args) } -Compress) + [Environment]::NewLine)
    throw 'synthetic invocation failure'
}
& $env:CARGOTOOLS_CWD_PWSH -NoLogo -NoProfile -File $env:CARGOTOOLS_CWD_FIXTURE @args
'@ | Set-Content -LiteralPath $env:CARGOTOOLS_CWD_SHIM
    $script:caller = Join-Path $TestDrive 'caller'
    $script:project = Join-Path $TestDrive 'project'
    $script:literalProject = Join-Path $TestDrive 'project[1]'
    foreach ($path in @($script:caller, $script:project, $script:literalProject)) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    $script:filePath = Join-Path $TestDrive 'not-a-directory.txt'
    [IO.File]::WriteAllText($script:filePath, 'synthetic fixture')
    $script:missingPath = Join-Path $TestDrive 'missing-project'
    function Read-CwdCall {
        if (Test-Path -LiteralPath $env:CARGOTOOLS_CWD_LOG) {
            foreach ($line in [IO.File]::ReadAllLines($env:CARGOTOOLS_CWD_LOG)) { $line | ConvertFrom-Json }
        }
    }
}

AfterAll {
    Set-Location -LiteralPath $script:originalLocation.Path
    foreach ($name in $script:controlledEnvironment) {
        $value = $script:savedEnvironment[$name]
        if ($null -eq $value) { $value = [System.Management.Automation.Language.NullString]::Value }
        [Environment]::SetEnvironmentVariable($name, $value)
    }
    if ($script:hadLastExitCode) { $global:LASTEXITCODE = $script:savedLastExitCode }
    else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
}

Describe 'Invoke-CargoWrapper literal working directory custody' {
    BeforeEach {
        Set-Location -LiteralPath $script:caller
        foreach ($name in $script:controlledEnvironment | Where-Object { $_ -notlike 'CARGOTOOLS_CWD_*' }) {
            [Environment]::SetEnvironmentVariable($name, [System.Management.Automation.Language.NullString]::Value)
        }
        $env:CARGOTOOLS_ENFORCE_QUALITY = '0'
        $env:CARGOTOOLS_RUN_TESTS_AFTER_BUILD = '0'
        $env:CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD = '0'
        $env:CARGO_USE_NEXTEST = '0'
        $env:CARGOTOOLS_CWD_EXIT = '0'
        $env:CARGOTOOLS_CWD_THROW = '0'
        Remove-Item -LiteralPath $env:CARGOTOOLS_CWD_LOG -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = 0
        Mock Resolve-CacheRoot -ModuleName CargoTools { $TestDrive }
        Mock Ensure-MsvcEnv -ModuleName CargoTools {}
        Mock Initialize-CargoEnv -ModuleName CargoTools {}
        Mock Test-CargoMachineDependencies -ModuleName CargoTools { [pscustomobject]@{ Passed = $true } }
        Mock Resolve-LldLinker -ModuleName CargoTools { $null }
        Mock Apply-LinkerSettings -ModuleName CargoTools { $false }
        Mock Apply-NativeCpuFlag -ModuleName CargoTools {}
        Mock Start-SccacheServer -ModuleName CargoTools { $true }
        Mock Enter-CargoBuildQueue -ModuleName CargoTools { [pscustomobject]@{ TicketPath = 'fake-ticket' } }
        Mock Exit-CargoBuildQueue -ModuleName CargoTools {}
        Mock Get-RustupPath -ModuleName CargoTools { $env:CARGOTOOLS_CWD_SHIM }
        Mock Resolve-CargoToolchain -ModuleName CargoTools { 'stable' }
        Mock Apply-PreflightEnvDefaults -ModuleName CargoTools { @{ Enabled = $false; RA = $false; Blocking = $true } }
        Mock Apply-PreflightIdeGuard -ModuleName CargoTools { param($State) $State }
        Mock Write-Host -ModuleName CargoTools {}
        Mock Write-CargoStatus -ModuleName CargoTools {}
        Mock Write-CargoBuildPhase -ModuleName CargoTools {}
        Mock Write-CargoDebug -ModuleName CargoTools {}
        Mock Format-CargoDiagnostics -ModuleName CargoTools { 'synthetic diagnostics' }
        Mock Show-SccacheStatus -ModuleName CargoTools {}
        Mock Test-AutoCopyEnabled -ModuleName CargoTools { $false }
        & (Get-Module CargoTools) { $script:LlmOutputMode = $false }
    }

    AfterEach { Set-Location -LiteralPath $script:caller }

    # Protects: raw, passthrough and normal invocations execute in the requested project.
    # Detects: early raw return bypassing WorkingDirectory and commands targeting the caller's repository.
    # Needs: mocked module services and synthetic child pwsh only; no Cargo, rustup, install or hardware.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'runs <Label> in the requested project and restores the caller' -ForEach @(
        @{ Label = 'raw'; Flags = @('--raw') }
        @{ Label = 'passthrough'; Flags = @('--passthrough') }
        @{ Label = 'normal'; Flags = @() }
    ) {
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs $Flags -WorkingDirectory $script:project -ErrorAction SilentlyContinue)
        $code = $global:LASTEXITCODE
        $calls = @(Read-CwdCall)
        $calls.Count | Should -Be 1
        $calls[0].cwd | Should -Be $script:project
        $calls[0].argv | Should -Be @('run', 'stable', 'cargo', 'check')
        $result[-1] | Should -Be 0
        $code | Should -Be 0
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: environment-selected raw mode honors the same project boundary.
    # Detects: CARGO_RAW taking a separate early-return path that silently chooses the wrong manifest.
    # Needs: process-local CARGO_RAW=1 and synthetic native peer; original environment restored after the file.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'honors WorkingDirectory when CARGO_RAW selects passthrough' {
        $env:CARGO_RAW = '1'
        $result = @(Invoke-CargoWrapper -Command check -WorkingDirectory $script:project -ErrorAction SilentlyContinue)
        $calls = @(Read-CwdCall)
        $calls.Count | Should -Be 1
        $calls[0].cwd | Should -Be $script:project
        $result[-1] | Should -Be 0
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: bracket characters in directory names are literal across both invocation routes.
    # Detects: wildcard Test-Path/Push-Location rejecting or expanding a valid project name.
    # Needs: TestDrive project[1] and synthetic native peer; no filesystem access outside the fixture.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'uses literal directory names in <Label> mode' -ForEach @(
        @{ Label = 'raw'; Flags = @('--raw') }
        @{ Label = 'normal'; Flags = @() }
    ) {
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs $Flags -WorkingDirectory $script:literalProject -ErrorAction SilentlyContinue)
        $calls = @(Read-CwdCall)
        $calls.Count | Should -Be 1
        $calls[0].cwd | Should -Be $script:literalProject
        $result[-1] | Should -Be 0
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: an invalid project path cannot fall through to a native build in the caller directory.
    # Detects: missing/file paths accepted by raw mode or a nonterminating Push-Location failure.
    # Needs: synthetic missing path and plain file; no Cargo or filesystem mutation beyond TestDrive.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'rejects <Kind> in <Label> mode before native invocation' -ForEach @(
        @{ Label = 'raw'; Flags = @('--raw'); Kind = 'missing'; PathKind = 'missingPath' }
        @{ Label = 'normal'; Flags = @(); Kind = 'missing'; PathKind = 'missingPath' }
        @{ Label = 'raw'; Flags = @('--raw'); Kind = 'file'; PathKind = 'filePath' }
        @{ Label = 'normal'; Flags = @(); Kind = 'file'; PathKind = 'filePath' }
    ) {
        $path = if ($PathKind -eq 'missingPath') { $script:missingPath } else { $script:filePath }
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs $Flags -WorkingDirectory $path -ErrorAction SilentlyContinue)
        $code = $global:LASTEXITCODE
        @(Read-CwdCall).Count | Should -Be 0
        $result[-1] | Should -Be 1
        $code | Should -Be 1
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: native nonzero status is preserved while caller location is restored.
    # Detects: location cleanup masking the actual command result or leaking project cwd on failure.
    # Needs: synthetic child exits37; no failing Rust build or real native tool.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'restores caller and preserves native exit37 in <Label> mode' -ForEach @(
        @{ Label = 'raw'; Flags = @('--raw') }
        @{ Label = 'normal'; Flags = @() }
    ) {
        $env:CARGOTOOLS_CWD_EXIT = '37'
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs $Flags -WorkingDirectory $script:project -ErrorAction SilentlyContinue)
        $code = $global:LASTEXITCODE
        $calls = @(Read-CwdCall)
        $calls.Count | Should -Be 1
        $calls[0].cwd | Should -Be $script:project
        $result[-1] | Should -Be 37
        $code | Should -Be 37
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: exception cleanup releases the requested location on the raw route.
    # Detects: a new raw Push-Location without a finally covering an invocation exception.
    # Needs: script shim throws a synthetic error before any external command; no Rust process.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'restores the caller when raw invocation throws' {
        $env:CARGOTOOLS_CWD_THROW = '1'
        { Invoke-CargoWrapper -Command check -AdditionalArgs @('--raw') -WorkingDirectory $script:project -ErrorAction SilentlyContinue } | Should -Throw '*synthetic invocation failure*'
        $code = $global:LASTEXITCODE
        $calls = @(Read-CwdCall)
        $calls.Count | Should -Be 1
        $calls[0].cwd | Should -Be $script:project
        $code | Should -Be 1
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: normal-route invocation errors retain failure status and release project cwd.
    # Detects: shared location cleanup lost while moving it to cover early raw returns.
    # Needs: synthetic throwing shim and mocked diagnostics; no Cargo, cache daemon or deployment.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'restores the caller when normal invocation fails with an exception' {
        $env:CARGOTOOLS_CWD_THROW = '1'
        $result = @(Invoke-CargoWrapper -Command check -WorkingDirectory $script:project -ErrorAction SilentlyContinue)
        $code = $global:LASTEXITCODE
        $calls = @(Read-CwdCall)
        $calls.Count | Should -Be 1
        $calls[0].cwd | Should -Be $script:project
        $result[-1] | Should -Be 1
        $code | Should -Be 1
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: commands without an explicit project retain their existing caller-cwd contract.
    # Detects: an unsolicited default directory switch introduced by shared location setup.
    # Needs: synthetic child pwsh and TestDrive caller directory; no Rust process.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'preserves caller cwd when <Label> mode has no WorkingDirectory' -ForEach @(
        @{ Label = 'raw'; Flags = @('--raw') }
        @{ Label = 'normal'; Flags = @() }
    ) {
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs $Flags -ErrorAction SilentlyContinue)
        $calls = @(Read-CwdCall)
        $calls.Count | Should -Be 1
        $calls[0].cwd | Should -Be $script:caller
        $result[-1] | Should -Be 0
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: wrapper-only help releases a valid literal project without invoking native tools.
    # Detects: location custody tied only to raw/normal build paths instead of every early return.
    # Needs: TestDrive project[1] and mocked host output; no Cargo, rustup or environment bootstrap.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'restores caller after wrapper-help with a valid literal directory' {
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs @('--wrapper-help') -WorkingDirectory $script:literalProject -ErrorAction SilentlyContinue)
        @(Read-CwdCall).Count | Should -Be 0
        $result[-1] | Should -Be 0
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: any explicitly requested project is validated, including wrapper-only help.
    # Detects: invalid directories silently accepted by help's earlier return.
    # Needs: synthetic missing TestDrive path and mocked host output; no native invocation.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'rejects an invalid explicit directory even for wrapper-help' {
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs @('--wrapper-help') -WorkingDirectory $script:missingPath -ErrorAction SilentlyContinue)
        $code = $global:LASTEXITCODE
        @(Read-CwdCall).Count | Should -Be 0
        $result[-1] | Should -Be 1
        $code | Should -Be 1
        (Get-Location).ProviderPath | Should -Be $script:caller
    }

    # Protects: a raw early return after selecting a project still restores the caller.
    # Detects: cleanup scoped only to the native invocation rather than the full raw route.
    # Needs: mocked missing rustup path; no native invocation or installation fallback.
    # Breadcrumb: Public/Invoke-CargoWrapper.ps1#Invoke-CargoWrapper.
    It 'restores caller after raw missing-tool early return' {
        Mock Get-RustupPath -ModuleName CargoTools { Join-Path $TestDrive 'missing-rustup.ps1' }
        $result = @(Invoke-CargoWrapper -Command check -AdditionalArgs @('--raw') -WorkingDirectory $script:project -ErrorAction SilentlyContinue)
        @(Read-CwdCall).Count | Should -Be 0
        $result[-1] | Should -Be 1
        (Get-Location).ProviderPath | Should -Be $script:caller
    }
}
