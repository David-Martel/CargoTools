#Requires -Modules Pester
<#
.SYNOPSIS
Pester tests for the environment and argument handling that decides sccache cache keys.
.DESCRIPTION
sccache hashes every CARGO_* variable that rustc inherits, plus RUSTFLAGS and the spelling of the
rustc wrapper. Anything that makes those differ between two checkouts of the same source gives each
checkout its own cache. These tests pin the rules that keep them equal:

  - the target directory travels as --target-dir, not as an exported CARGO_TARGET_DIR
    (Add-CargoTargetDirArg, Invoke-RustupCargo);
  - CargoTools' own CARGO_* switches are hidden from cargo for the call and restored afterwards;
  - one spelling of the sccache wrapper (CARGO_BUILD_RUSTC_WRAPPER);
  - an explicit SCCACHE_SERVER_PORT is kept and never rewritten from shared state;
  - Add-RustFlags does not append a flag that is already present.

The measurements behind each rule are in CHANGELOG.md and the pull request that introduced this file.
Every test here fails on the commit before that change, because the function it calls does not exist
or behaves differently.
#>

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'CargoTools.psd1') -Force
    $script:CargoModule = Get-Module CargoTools
    $script:AddCargoTargetDirArg = & $script:CargoModule { ${function:Add-CargoTargetDirArg} }
    $script:PrivateEnvPattern = & $script:CargoModule { $script:CargoToolsPrivateEnvPattern }

    function Read-Call { Get-Content -LiteralPath $script:Log | ForEach-Object { $_ | ConvertFrom-Json } | Select-Object -Last 1 }

    $script:SavedEnvironment = @{}
    Get-ChildItem Env: | ForEach-Object { $script:SavedEnvironment[$_.Name] = $_.Value }
}

AfterAll {
    foreach ($item in @(Get-ChildItem Env:)) {
        if (-not $script:SavedEnvironment.ContainsKey($item.Name)) {
            [Environment]::SetEnvironmentVariable($item.Name, $null)
        }
    }
    foreach ($item in $script:SavedEnvironment.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($item.Key, $item.Value)
    }
}

Describe 'Add-CargoTargetDirArg' {
    # Protects: the target directory reaches cargo as a flag, so it is not in rustc's environment.
    # Detects: leaving CARGO_TARGET_DIR exported (a second checkout missed 57 of 57 cached units), and
    # putting the flag after a bare `--`, where `cargo test` hands it to the test harness.
    It 'appends --target-dir to a build command' {
        $result = & $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'build' -ArgsList @('build', '-p', 'uu_tr')
        $result | Should -Be @('build', '-p', 'uu_tr', '--target-dir', 'T:\shared')
    }

    It 'puts the flag before a bare -- so a test harness never receives it' {
        $result = & $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'test' -ArgsList @('test', '-p', 'x', '--', '--nocapture')
        $result | Should -Be @('test', '-p', 'x', '--target-dir', 'T:\shared', '--', '--nocapture')
    }

    It 'inserts the flag once when the arguments hold a second --' {
        $result = & $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'run' -ArgsList @('run', '--', 'a', '--', 'b')
        $result | Should -Be @('run', '--target-dir', 'T:\shared', '--', 'a', '--', 'b')
    }

    It 'keeps a caller-supplied --target-dir (separate value)' {
        $argsIn = @('check', '--target-dir', 'T:\mine', '-p', 'x')
        $result = & $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'check' -ArgsList $argsIn
        $result | Should -Be $argsIn
    }

    It 'keeps a caller-supplied --target-dir= form' {
        $argsIn = @('check', '--target-dir=T:\mine')
        $result = & $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'check' -ArgsList $argsIn
        $result | Should -Be $argsIn
    }

    It 'adds the flag when --target-dir appears only after -- (it belongs to the program being run)' {
        $result = & $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'run' -ArgsList @('run', '--', '--target-dir', 'x')
        $result | Should -Be @('run', '--target-dir', 'T:\shared', '--', '--target-dir', 'x')
    }

    It 'leaves the arguments alone for a subcommand without the flag' {
        $argsIn = @('fmt', '--check')
        (& $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'fmt' -ArgsList $argsIn) | Should -Be $argsIn
    }

    It 'leaves the arguments alone when no target directory is set' {
        $argsIn = @('build')
        (& $script:AddCargoTargetDirArg -TargetDir '' -PrimaryCommand 'build' -ArgsList $argsIn) | Should -Be $argsIn
    }

    It 'leaves cargo llvm-cov alone, because cargo-llvm-cov rejects --target-dir' {
        # Detects: every coverage run failing with "invalid option '--target-dir'" (cargo-llvm-cov 0.9.1) once
        # CARGO_TARGET_DIR is set. The variable then stays in the environment, which llvm-cov does read.
        $argsIn = @('llvm-cov', '--workspace')
        (& $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'llvm-cov' -ArgsList $argsIn) | Should -Be $argsIn
    }

    It 'adds the flag to nextest <Sub>, which accepts it' -ForEach @(
        @{ Sub = 'run' }, @{ Sub = 'r' }, @{ Sub = 'list' }, @{ Sub = 'archive' }
    ) {
        $out = @(& $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'nextest' -ArgsList @('nextest', $Sub))
        $out | Should -Be @('nextest', $Sub, '--target-dir', 'T:\shared')
    }

    It 'leaves administrative nextest subcommands alone (<Sub> rejects --target-dir)' -ForEach @(
        @{ Sub = 'show-config' }, @{ Sub = 'self' }, @{ Sub = 'store' }
    ) {
        $argsIn = @('nextest', $Sub)
        (& $script:AddCargoTargetDirArg -TargetDir 'T:\shared' -PrimaryCommand 'nextest' -ArgsList $argsIn) | Should -Be $argsIn
    }
}

Describe 'Invoke-RustupCargo' {
    BeforeEach {
        # A stand-in for `rustup run <toolchain> cargo ...`: it records what cargo would be given.
        $script:Log = Join-Path $TestDrive "calls-$([guid]::NewGuid().ToString('N')).jsonl"
        $script:Stub = Join-Path $TestDrive 'rustup-stub.ps1'
        Set-Content -LiteralPath $script:Stub -Value @'
$names = 'CARGO_TARGET_DIR', 'CARGO_USE_LLD', 'CARGO_PREFLIGHT_MODE', 'CARGO_AUTO_COPY', 'CARGO_INCREMENTAL', 'CARGO_HOME'
$seen = [ordered]@{}
foreach ($n in $names) { $seen[$n] = [Environment]::GetEnvironmentVariable($n) }
[pscustomobject]@{ Args = @($args); Env = $seen } | ConvertTo-Json -Compress -Depth 4 | Add-Content -LiteralPath $env:CT_STUB_LOG
if ($env:CT_STUB_THROW) { throw 'stub failure' }
$global:LASTEXITCODE = 0
'@
        $env:CT_STUB_LOG = $script:Log
        Remove-Item Env:CT_STUB_THROW -ErrorAction SilentlyContinue
        $env:CARGO_TARGET_DIR = 'T:\shared-target'
        $env:CARGO_USE_LLD = '1'
        $env:CARGO_PREFLIGHT_MODE = 'fast'
        $env:CARGO_AUTO_COPY = '1'
        $env:CARGO_INCREMENTAL = '0'
        $env:CARGO_HOME = 'T:\cargo-home'
    }

    It 'hands cargo the target directory as a flag and no CARGO_TARGET_DIR' {
        & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @('check', '-p', 'x') } $script:Stub
        $call = Read-Call
        @($call.Args) | Should -Be @('run', 'stable', 'cargo', 'check', '-p', 'x', '--target-dir', 'T:\shared-target')
        $call.Env.CARGO_TARGET_DIR | Should -BeNullOrEmpty
    }

    It 'restores CARGO_TARGET_DIR afterwards for the wrapper own post-build steps' {
        & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @('check') } $script:Stub
        $env:CARGO_TARGET_DIR | Should -Be 'T:\shared-target'
    }

    It 'hides CargoTools private CARGO_* switches from cargo and restores them' {
        # Detects: CARGO_USE_LLD, CARGO_PREFLIGHT_MODE and CARGO_AUTO_COPY reaching rustc, where sccache hashes them.
        & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @('check') } $script:Stub
        $call = Read-Call
        $call.Env.CARGO_USE_LLD | Should -BeNullOrEmpty
        $call.Env.CARGO_PREFLIGHT_MODE | Should -BeNullOrEmpty
        $call.Env.CARGO_AUTO_COPY | Should -BeNullOrEmpty
        $env:CARGO_USE_LLD | Should -Be '1'
        $env:CARGO_PREFLIGHT_MODE | Should -Be 'fast'
        $env:CARGO_AUTO_COPY | Should -Be '1'
    }

    It 'leaves genuine cargo variables in place' {
        & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @('check') } $script:Stub
        $call = Read-Call
        $call.Env.CARGO_INCREMENTAL | Should -Be '0'
        $call.Env.CARGO_HOME | Should -Be 'T:\cargo-home'
    }

    It 'restores the environment when cargo throws' {
        $env:CT_STUB_THROW = '1'
        { & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @('check') } $script:Stub } | Should -Throw
        $env:CARGO_TARGET_DIR | Should -Be 'T:\shared-target'
        $env:CARGO_USE_LLD | Should -Be '1'
    }

    It 'keeps CARGO_TARGET_DIR for a subcommand that cannot take the flag (cargo clean needs it)' {
        & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @('clean') } $script:Stub
        $call = Read-Call
        @($call.Args) | Should -Be @('run', 'stable', 'cargo', 'clean')
        $call.Env.CARGO_TARGET_DIR | Should -Be 'T:\shared-target'
    }

    It 'runs bare cargo when there are no arguments (wrapper with no command)' {
        # Detects: Mandatory on an empty array, which made `Invoke-CargoWrapper --llm-output` exit 1
        # instead of running bare cargo.
        & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @() } $script:Stub
        $call = Read-Call
        @($call.Args) | Should -Be @('run', 'stable', 'cargo')
    }

    It 'does not add a second --target-dir when the caller passed one' {
        & $script:CargoModule { param($stub) Invoke-RustupCargo -RustupPath $stub -Toolchain stable -CargoArgs @('check', '--target-dir', 'T:\mine') } $script:Stub
        $call = Read-Call
        @($call.Args) | Should -Be @('run', 'stable', 'cargo', 'check', '--target-dir', 'T:\mine')
    }
}

Describe 'CargoTools private CARGO_* switches' {
    # Protects: every CARGO_* variable this module invents is hidden from cargo.
    # Detects: a new switch added to the module without extending the pattern, which would put it back
    # into every sccache key. Names cargo itself reads must stay visible, so they are listed here.
    It 'covers every CARGO_* variable the module reads except the ones cargo defines' {
        $cargoDefined = @(
            'CARGO_TARGET_DIR', 'CARGO_HOME', 'CARGO_INCREMENTAL', 'CARGO_BUILD_JOBS', 'CARGO_BUILD_TARGET',
            'CARGO_TERM_COLOR', 'CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER', 'CARGO_BUILD_RUSTC_WRAPPER'
        )
        $sources = Get-ChildItem -Path (Join-Path $script:ModuleRoot 'Private'), (Join-Path $script:ModuleRoot 'Public') -Filter *.ps1
        $names = $sources | ForEach-Object { Select-String -Path $_.FullName -Pattern 'env:(CARGO_[A-Z0-9_]+)' -AllMatches } |
            ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $names.Count | Should -BeGreaterThan 10
        $uncovered = @($names | Where-Object { $_ -notin $cargoDefined -and $_ -notmatch $script:PrivateEnvPattern })
        $uncovered | Should -BeNullOrEmpty
    }

    It 'does not match a variable cargo defines' {
        foreach ($name in 'CARGO_TARGET_DIR', 'CARGO_HOME', 'CARGO_INCREMENTAL', 'CARGO_BUILD_JOBS', 'CARGO_PROFILE_RELEASE_LTO') {
            $name | Should -Not -Match $script:PrivateEnvPattern
        }
    }
}

Describe 'Initialize-CargoEnv wrapper spelling' {
    BeforeEach {
        # Initialize-CargoEnv runs for real; only the machine-specific lookups are replaced and no sccache
        # server is contacted.
        $script:SavedForInit = @{}
        Get-ChildItem Env: | ForEach-Object { $script:SavedForInit[$_.Name] = $_.Value }
        $env:CARGOTOOLS_DISABLE_GLOBAL_RUSTFMT_SYNC = '1'
        $env:CARGO_HOME = Join-Path $TestDrive 'cargo'
        $env:RUSTUP_HOME = Join-Path $TestDrive 'rustup'
        Remove-Item Env:SCCACHE_DISABLE -ErrorAction SilentlyContinue
        Remove-Item Env:CARGO_BUILD_RUSTC_WRAPPER -ErrorAction SilentlyContinue
        Mock Ensure-MsvcEnv -ModuleName CargoTools {}
        Mock Ensure-Directory -ModuleName CargoTools {}
        Mock Resolve-Sccache -ModuleName CargoTools { 'sccache-fixture.exe' }
        Mock Resolve-CacheRoot -ModuleName CargoTools { $TestDrive }
        Mock Get-MachineConfig -ModuleName CargoTools { @{ CacheRoot = $TestDrive } }
        Mock Resolve-FreeSccachePort -ModuleName CargoTools { param($DesiredPort) $DesiredPort }
    }
    AfterEach {
        foreach ($item in @(Get-ChildItem Env:)) {
            if (-not $script:SavedForInit.ContainsKey($item.Name)) { [Environment]::SetEnvironmentVariable($item.Name, $null) }
        }
        foreach ($item in $script:SavedForInit.GetEnumerator()) { [Environment]::SetEnvironmentVariable($item.Key, $item.Value) }
    }

    It 'rewrites a full-path CARGO_BUILD_RUSTC_WRAPPER for sccache to the bare name' {
        # Protects: one wrapper spelling in every build. Detects: the same sccache.exe given as a path in
        # one shell and as `sccache` in another, which sccache hashes as two different wrappers (0 of 57 hits
        # on an identical repeat).
        $env:CARGO_BUILD_RUSTC_WRAPPER = 'C:\Users\someone\bin\sccache.exe'
        Initialize-CargoEnv -CacheRoot $TestDrive
        $env:RUSTC_WRAPPER | Should -Be 'sccache'
        $env:CARGO_BUILD_RUSTC_WRAPPER | Should -Be 'sccache'
    }

    It 'leaves another wrapper in CARGO_BUILD_RUSTC_WRAPPER alone' {
        $env:CARGO_BUILD_RUSTC_WRAPPER = 'C:\tools\custom-wrapper.exe'
        Initialize-CargoEnv -CacheRoot $TestDrive
        $env:CARGO_BUILD_RUSTC_WRAPPER | Should -Be 'C:\tools\custom-wrapper.exe'
    }

    It 'does not set CARGO_BUILD_RUSTC_WRAPPER when the caller had none' {
        Initialize-CargoEnv -CacheRoot $TestDrive
        $env:CARGO_BUILD_RUSTC_WRAPPER | Should -BeNullOrEmpty
    }
}

Describe 'Initialize-CargoEnv SCCACHE_SERVER_PORT' {
    BeforeEach {
        $script:SavedForPort = @{}
        Get-ChildItem Env: | ForEach-Object { $script:SavedForPort[$_.Name] = $_.Value }
        $env:CARGOTOOLS_DISABLE_GLOBAL_RUSTFMT_SYNC = '1'
        $env:CARGO_HOME = Join-Path $TestDrive 'cargo'
        $env:RUSTUP_HOME = Join-Path $TestDrive 'rustup'
        Remove-Item Env:SCCACHE_DISABLE, Env:SCCACHE_SERVER_PORT -ErrorAction SilentlyContinue
        & $script:CargoModule { $script:CargoToolsAssignedSccachePort = $null }
        # Port state is a scratch file; no real sccache server or port is contacted.
        $script:StateDir = Join-Path $TestDrive "sccache-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $script:StateDir 'sccache') -Force | Out-Null
        $script:StateFile = Join-Path $script:StateDir 'sccache\resolved-port.txt'
        Mock Ensure-MsvcEnv -ModuleName CargoTools {}
        Mock Ensure-Directory -ModuleName CargoTools {}
        Mock Resolve-Sccache -ModuleName CargoTools { 'sccache-fixture.exe' }
        # Mock bodies run in the module's scope, so they get the directory by closure, not from $script:.
        $stateDirForMocks = $script:StateDir
        Mock Resolve-CacheRoot -ModuleName CargoTools { $stateDirForMocks }.GetNewClosure()
        Mock Get-MachineConfig -ModuleName CargoTools { @{ CacheRoot = $stateDirForMocks } }.GetNewClosure()
        Mock netsh -ModuleName CargoTools { '60000 60010' }
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
        Mock Test-SccacheHealth -ModuleName CargoTools { [pscustomobject]@{ Healthy = $false } }
        Mock Test-SccachePortAvailable -ModuleName CargoTools { $true }
    }
    AfterEach {
        foreach ($item in @(Get-ChildItem Env:)) {
            if (-not $script:SavedForPort.ContainsKey($item.Name)) { [Environment]::SetEnvironmentVariable($item.Name, $null) }
        }
        foreach ($item in $script:SavedForPort.GetEnumerator()) { [Environment]::SetEnvironmentVariable($item.Key, $item.Value) }
    }

    It 'keeps an explicit port when the shared state names another usable port' {
        # Protects: a private sccache server stays private. Detects: resolved-port.txt re-pointing the
        # session at the machine-wide server (4810), after which `sccache --stop-server` stopped it.
        Set-Content -LiteralPath $script:StateFile -Value '4810' -NoNewline
        $env:SCCACHE_SERVER_PORT = '4899'
        Initialize-CargoEnv -CacheRoot $script:StateDir
        $env:SCCACHE_SERVER_PORT | Should -Be '4899'
    }

    It 'does not overwrite the shared port state with an explicit private port' {
        # Detects: the explicit port being persisted, which steered every later default session at it.
        Set-Content -LiteralPath $script:StateFile -Value '4810' -NoNewline
        $env:SCCACHE_SERVER_PORT = '4899'
        Initialize-CargoEnv -CacheRoot $script:StateDir
        (Get-Content -LiteralPath $script:StateFile -Raw).Trim() | Should -Be '4810'
    }

    It 'does not create port state for an explicit port that answers as a healthy server' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $true }
        Mock Test-SccacheHealth -ModuleName CargoTools { [pscustomobject]@{ Healthy = $true } }
        $env:SCCACHE_SERVER_PORT = '4899'
        Initialize-CargoEnv -CacheRoot $script:StateDir
        $env:SCCACHE_SERVER_PORT | Should -Be '4899'
        Test-Path -LiteralPath $script:StateFile | Should -BeFalse
    }

    It 'keeps an explicit port that is not usable and warns what would have been chosen' {
        Mock Test-SccachePortAvailable -ModuleName CargoTools { param($Port) $Port -ne 4899 }
        $env:SCCACHE_SERVER_PORT = '4899'
        Mock Write-Warning -ModuleName CargoTools {}
        Initialize-CargoEnv -CacheRoot $script:StateDir
        $env:SCCACHE_SERVER_PORT | Should -Be '4899'
        Should -Invoke Write-Warning -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Message -like 'SCCACHE_SERVER_PORT=4899 is set explicitly*' }
    }

    It 'still converges an unset port on the shared state' {
        # The default keeps its old behaviour: sessions without a choice share one server.
        Set-Content -LiteralPath $script:StateFile -Value '4810' -NoNewline
        Initialize-CargoEnv -CacheRoot $script:StateDir
        $env:SCCACHE_SERVER_PORT | Should -Be '4810'
    }

    It 'keeps re-resolving a port CargoTools chose itself on later calls' {
        # Detects: treating the value written by the first call as the caller's explicit choice.
        Set-Content -LiteralPath $script:StateFile -Value '4810' -NoNewline
        Initialize-CargoEnv -CacheRoot $script:StateDir
        Set-Content -LiteralPath $script:StateFile -Value '4811' -NoNewline
        Initialize-CargoEnv -CacheRoot $script:StateDir
        $env:SCCACHE_SERVER_PORT | Should -Be '4811'
    }
}

Describe 'Add-RustFlags' {
    # Protects: RUSTFLAGS, which is part of every sccache key, is the same string on every call of the same build.
    # Detects: appending a flag again on each Initialize-CargoEnv/linker call (RUSTFLAGS grew without bound in a
    # long session, each length a new key), and dropping the second flag of a two-flag call.
    BeforeEach { $script:SavedRustFlags = $env:RUSTFLAGS; Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue }
    AfterEach { if ($null -eq $script:SavedRustFlags) { Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue } else { $env:RUSTFLAGS = $script:SavedRustFlags } }

    It 'adds a flag to an empty RUSTFLAGS' {
        & $script:CargoModule { Add-RustFlags '-C target-cpu=native' }
        $env:RUSTFLAGS | Should -Be '-C target-cpu=native'
    }

    It 'does not append a flag that is already present, however often it is called' {
        & $script:CargoModule { 1..5 | ForEach-Object { Add-RustFlags '-C target-cpu=native' } }
        $env:RUSTFLAGS | Should -Be '-C target-cpu=native'
    }

    It 'appends a different flag after an existing one' {
        $env:RUSTFLAGS = '-C debuginfo=1'
        & $script:CargoModule { Add-RustFlags '-C target-cpu=native'; Add-RustFlags '-C debuginfo=1' }
        $env:RUSTFLAGS | Should -Be '-C debuginfo=1 -C target-cpu=native'
    }

    It 'applies every flag of a multi-flag call (the second used to be dropped)' {
        & $script:CargoModule { Add-RustFlags '-C lto=thin' '-C codegen-units=1' }
        $env:RUSTFLAGS | Should -Be '-C lto=thin -C codegen-units=1'
    }

    It 'treats differing whitespace as the same flag and does not match inside another flag' {
        $env:RUSTFLAGS = '-C   lto=thin -C link-arg=/STACK:8388608'
        & $script:CargoModule { Add-RustFlags '-C lto=thin'; Add-RustFlags '-C link-arg=/STACK:8' }
        $env:RUSTFLAGS | Should -Be '-C lto=thin -C link-arg=/STACK:8388608 -C link-arg=/STACK:8'
    }

    It 'appends a codegen setting whose later occurrence set another value (last one wins in rustc)' {
        # Detects: --llm-debug skipping -C debuginfo=1 because an earlier debuginfo=1 matched, although a
        # later debuginfo=0 was the effective value. Same for conflicting LTO settings.
        $env:RUSTFLAGS = '-C debuginfo=1 -C debuginfo=0'
        & $script:CargoModule { Add-RustFlags '-C debuginfo=1' }
        $env:RUSTFLAGS | Should -Be '-C debuginfo=1 -C debuginfo=0 -C debuginfo=1'
        $env:RUSTFLAGS = '-Clto=thin -C lto=fat'
        & $script:CargoModule { Add-RustFlags '-C lto=thin' }
        $env:RUSTFLAGS | Should -Be '-Clto=thin -C lto=fat -C lto=thin'
    }

    It 'skips a codegen setting whose last occurrence already has that value, in either spelling' {
        $env:RUSTFLAGS = '-C debuginfo=0 -Cdebuginfo=1'
        & $script:CargoModule { Add-RustFlags '-C debuginfo=1' }
        $env:RUSTFLAGS | Should -Be '-C debuginfo=0 -Cdebuginfo=1'
    }

    It 'treats cumulative codegen options (link-arg) as a list, not a last-wins setting' {
        $env:RUSTFLAGS = '-C link-arg=/A -C link-arg=/B'
        & $script:CargoModule { Add-RustFlags '-C link-arg=/A'; Add-RustFlags '-C link-arg=/C' }
        $env:RUSTFLAGS | Should -Be '-C link-arg=/A -C link-arg=/B -C link-arg=/C'
    }

    It 'ignores an empty or null flag' {
        $env:RUSTFLAGS = '-C debuginfo=1'
        & $script:CargoModule { Add-RustFlags ''; Add-RustFlags $null }
        $env:RUSTFLAGS | Should -Be '-C debuginfo=1'
    }
}
