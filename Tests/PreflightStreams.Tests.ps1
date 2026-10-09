#Requires -Version 5.1

BeforeDiscovery {
    $preflightCases = foreach ($mode in @('check','clippy','fmt','deny','all')) {
        foreach ($code in @(0,101)) {
            foreach ($blocking in @($true,$false)) { @{Mode=$mode;Code=$code;Blocking=$blocking} }
        }
    }
    $raCases = foreach ($json in @($true,$false)) {
        foreach ($code in @(0,101)) {
            foreach ($blocking in @($true,$false)) { @{Json=$json;Code=$code;Blocking=$blocking} }
        }
    }
}

BeforeAll {
    $script:StreamModule = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1') -Force -PassThru
    $script:StreamChild = Join-Path $TestDrive 'native-stream.cmd'
    # A real private native child substitutes only the external toolchain. Each
    # invocation emits one useful JSON frame and an independent process status.
    [IO.File]::WriteAllText($script:StreamChild, @'
@echo off
if "%~1"=="diagnostics" (set phase=ra) else (set phase=%~4)
set result=%PCAI_STREAM_EXIT%
if not "%PCAI_STREAM_FAIL_PHASE%"=="" if not "%phase%"=="%PCAI_STREAM_FAIL_PHASE%" set result=0
if "%phase%"=="build" set result=0
if "%phase%"=="ra" echo ERROR inference diagnostic in desugared expr fixture-filter
echo {"reason":"fixture","phase":"%phase%","code":%result%}
>>"%PCAI_STREAM_LOG%" echo %phase%
>>"%PCAI_STREAM_ARGV_LOG%" echo %*
exit /b %result%
'@, [Text.ASCIIEncoding]::new())
    $script:StreamEnvironmentNames = @(
        'PCAI_STREAM_EXIT','PCAI_STREAM_FAIL_PHASE','PCAI_STREAM_LOG','PCAI_STREAM_CHILD','PCAI_STREAM_ARGV_LOG',
        'CARGO_RAW','CARGOTOOLS_ENFORCE_QUALITY','CARGOTOOLS_AUTO_FIX',
        'CARGOTOOLS_RUN_TESTS_AFTER_BUILD','CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD',
        'CARGO_USE_NEXTEST','CARGO_RA_PREFLIGHT','CARGO_PREFLIGHT','CARGO_PREFLIGHT_MODE',
        'CARGO_PREFLIGHT_STRICT','CARGO_PREFLIGHT_BLOCKING','CARGO_PREFLIGHT_IDE_GUARD',
        'CARGO_PREFLIGHT_FORCE','CARGOTOOLS_RA_PREFLIGHT','CARGOTOOLS_PREFLIGHT_MODE',
        'CARGOTOOLS_ENABLE_DENY','CARGO_VERBOSITY','CARGO_LLM_DEBUG','CARGO_TIMINGS',
        'CARGO_QUICK_CHECK','CARGO_RELEASE_LTO','RUSTC_WRAPPER'
    )
    $script:StreamSavedEnvironment = @{}
    foreach ($name in $script:StreamEnvironmentNames) { $script:StreamSavedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name) }
    function Get-StreamCall {
        if (Test-Path -LiteralPath $env:PCAI_STREAM_LOG) { @(Get-Content -LiteralPath $env:PCAI_STREAM_LOG) }
    }
    function Get-StreamFrame {
        param([object[]]$Values)
        foreach ($value in $Values) { if ($value -is [string] -and $value.StartsWith('{"reason":"fixture"')) { $value | ConvertFrom-Json } }
    }
}

AfterAll {
    foreach ($name in $script:StreamEnvironmentNames) { [Environment]::SetEnvironmentVariable($name,$script:StreamSavedEnvironment[$name]) }
}

Describe 'Preflight native output and integer status are independent' -Tag 'Unit' {
    BeforeEach {
        foreach ($name in $script:StreamEnvironmentNames) { [Environment]::SetEnvironmentVariable($name,$null) }
        $env:PCAI_STREAM_EXIT='0'
        $env:PCAI_STREAM_CHILD=$script:StreamChild
        $script:StreamDirectory=Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($script:StreamDirectory)
        $env:PCAI_STREAM_LOG=Join-Path $script:StreamDirectory 'native-calls.txt'
        $env:PCAI_STREAM_ARGV_LOG=Join-Path $script:StreamDirectory 'native-argv.txt'
        $env:CARGOTOOLS_ENFORCE_QUALITY='0'
        $env:CARGOTOOLS_RUN_TESTS_AFTER_BUILD='0'
        $env:CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD='0'
        $env:CARGO_USE_NEXTEST='0'
        $global:LASTEXITCODE=0
        Push-Location $script:StreamDirectory
        Mock Resolve-CacheRoot -ModuleName CargoTools { Split-Path -Parent $env:PCAI_STREAM_LOG }
        Mock Resolve-RustAnalyzerPath -ModuleName CargoTools { $env:PCAI_STREAM_CHILD }
        Mock Test-CargoCommand -ModuleName CargoTools { $true }
        Mock Ensure-MsvcEnv -ModuleName CargoTools {}
        Mock Initialize-CargoEnv -ModuleName CargoTools {}
        Mock Test-CargoMachineDependencies -ModuleName CargoTools { [pscustomobject]@{Passed=$true} }
        Mock Resolve-LldLinker -ModuleName CargoTools { $null }
        Mock Apply-LinkerSettings -ModuleName CargoTools { $false }
        Mock Apply-NativeCpuFlag -ModuleName CargoTools {}
        Mock Start-SccacheServer -ModuleName CargoTools { $true }
        Mock Enter-CargoBuildQueue -ModuleName CargoTools { [pscustomobject]@{TicketPath='private-stream-fixture'} }
        Mock Exit-CargoBuildQueue -ModuleName CargoTools { $global:LASTEXITCODE=73 }
        Mock Get-RustupPath -ModuleName CargoTools { $env:PCAI_STREAM_CHILD }
        Mock Resolve-CargoToolchain -ModuleName CargoTools { 'stable' }
        Mock Write-CargoStatus -ModuleName CargoTools {}
        Mock Write-CargoBuildPhase -ModuleName CargoTools { $global:LASTEXITCODE=77 }
        Mock Write-CargoDebug -ModuleName CargoTools {}
        Mock Format-CargoDiagnostics -ModuleName CargoTools { 'private native stream fixture diagnostics' }
        Mock Show-SccacheStatus -ModuleName CargoTools {}
        Mock Test-AutoCopyEnabled -ModuleName CargoTools { $false }
        & $script:StreamModule { $script:LlmOutputMode=$false }
    }
    AfterEach { Pop-Location }

    It 'keeps <Mode> code <Code> blocking <Blocking> scalar and buffers each exact frame once' -ForEach $preflightCases {
        $env:PCAI_STREAM_EXIT=[string]$Code
        $buffer=[Collections.Generic.List[object]]::new()
        $state=@{Enabled=$true;Mode=$Mode;Strict=$false;Blocking=$Blocking}
        $status=& $script:StreamModule {
            param($child,$state,$buffer)
            Invoke-PreflightLocal -RustupPath $child -Toolchain stable -PassThroughArgs @('build','--message-format=json-render-diagnostics') -State $state -OutputBuffer $buffer
        } $script:StreamChild $state $buffer
        $expected=if ($Code -ne 0 -and $Blocking) { $Code } else { 0 }
        $status.GetType().FullName | Should -BeExactly 'System.Int32'
        $status | Should -Be $expected
        $calls=@(Get-StreamCall)
        $phases=if ($Mode -eq 'all') { if ($Code -ne 0 -and $Blocking) { @('check') } else { @('check','clippy','fmt') } } else { @($Mode) }
        $calls | Should -Be $phases
        $buffer.Count | Should -Be $phases.Count
        $frames=@(Get-StreamFrame -Values $buffer.ToArray())
        $frames.Count | Should -Be $phases.Count
        @($frames.phase) | Should -Be $phases
        foreach ($frame in $frames) { $frame.code | Should -Be $Code }
    }

    It 'keeps RA code <Code> blocking <Blocking> JSON <Json> scalar with the declared output route' -ForEach $raCases {
        $env:PCAI_STREAM_EXIT=[string]$Code
        $buffer=[Collections.Generic.List[object]]::new()
        $state=@{RA=$true;Blocking=$Blocking;JsonOutput=$Json}
        $status=& $script:StreamModule {
            param($state,$buffer)
            Invoke-RaDiagnosticsLocal -State $state -PassThroughArgs @('build') -OutputBuffer $buffer
        } $state $buffer
        $expected=if ($Code -ne 0 -and $Blocking) { $Code } else { 0 }
        $status.GetType().FullName | Should -BeExactly 'System.Int32'
        $status | Should -Be $expected
        @(Get-StreamCall) | Should -Be @('ra')
        if ($Json) {
            $buffer.Count | Should -Be 0
            $path=Join-Path $script:StreamDirectory '.cache/ra-diagnostics.json'
            $content=Get-Content -LiteralPath $path -Raw
            $content | Should -Not -Match 'fixture-filter'
            $frame=$content|ConvertFrom-Json
            $frame.phase | Should -BeExactly 'ra'
            $frame.code | Should -Be $Code
        } else {
            $buffer.Count | Should -Be 1
            $frame=@(Get-StreamFrame -Values $buffer.ToArray())
            $frame.Count | Should -Be 1
            $frame[0].phase | Should -BeExactly 'ra'
            $frame[0].code | Should -Be $Code
        }
    }

    It 'returns only zero without launching a child when each helper is disabled' {
        $buffer=[Collections.Generic.List[object]]::new()
        $status=& $script:StreamModule { param($child,$buffer) Invoke-PreflightLocal -RustupPath $child -State @{Enabled=$false} -OutputBuffer $buffer } $script:StreamChild $buffer
        $status.GetType().FullName | Should -BeExactly 'System.Int32'
        $status | Should -Be 0
        $ra=& $script:StreamModule { param($buffer) Invoke-RaDiagnosticsLocal -State @{RA=$false} -OutputBuffer $buffer } $buffer
        $ra.GetType().FullName | Should -BeExactly 'System.Int32'
        $ra | Should -Be 0
        $buffer.Count | Should -Be 0
        @(Get-StreamCall).Count | Should -Be 0
    }

    It 'retains a scalar legacy helper call without an output buffer' {
        $status=& $script:StreamModule { param($child) Invoke-PreflightLocal -RustupPath $child -Toolchain stable -PassThroughArgs @('build') -State @{Enabled=$true;Mode='check';Blocking=$true} } $script:StreamChild
        $status.GetType().FullName | Should -BeExactly 'System.Int32'
        $status | Should -Be 0
        @(Get-StreamCall) | Should -Be @('check')
    }

    It 'replays <Mode> code <Code> blocking <Blocking> once and preserves the authoritative wrapper status' -ForEach @(
        @{Mode='check';Code=0;Blocking=$true}
        @{Mode='check';Code=101;Blocking=$true}
        @{Mode='check';Code=101;Blocking=$false}
        @{Mode='all';Code=0;Blocking=$true}
        @{Mode='all';Code=101;Blocking=$true}
        @{Mode='all';Code=101;Blocking=$false}
    ) {
        $env:PCAI_STREAM_EXIT=[string]$Code
        $flag=if ($Blocking) { '--preflight-blocking' } else { '--preflight-nonblocking' }
        $result=@(Invoke-CargoWrapper -ArgumentList @('build','--preflight-mode',$Mode,$flag,'--preflight-force','--message-format=json-render-diagnostics'))
        $exitCode=$global:LASTEXITCODE
        $expected=if ($Code -ne 0 -and $Blocking) { $Code } else { 0 }
        $result[-1].GetType().FullName | Should -BeExactly 'System.Int32'
        $result[-1] | Should -Be $expected
        $exitCode.GetType().FullName | Should -BeExactly 'System.Int32'
        $exitCode | Should -Be $expected
        $phases=@(if ($Mode -eq 'all') { if ($Code -ne 0 -and $Blocking) { @('check') } else { @('check','clippy','fmt') } } else { @('check') })
        if ($expected -eq 0) { $phases+=@('build') }
        @(Get-StreamCall) | Should -Be $phases
        $frames=@(Get-StreamFrame -Values $result)
        $frames.Count | Should -Be $phases.Count
        @($frames.phase) | Should -Be $phases
        $result.Count | Should -Be ($phases.Count+1)
        Should -Invoke Exit-CargoBuildQueue -ModuleName CargoTools -Times 1 -Exactly
    }

    It 'replays RA code <Code> JSON <Json> through the real wrapper without allowing a failed blocking gate to build' -ForEach @(
        @{Code=0;Json=$false};@{Code=101;Json=$false};@{Code=0;Json=$true};@{Code=101;Json=$true}
    ) {
        $env:PCAI_STREAM_EXIT=[string]$Code
        $env:PCAI_STREAM_FAIL_PHASE='ra'
        $arguments=@('build','--preflight-mode','check','--preflight-blocking','--preflight-force','--preflight-ra')
        if ($Json) { $arguments+=@('--llm-output') }
        $result=@(Invoke-CargoWrapper -ArgumentList $arguments)
        $exitCode=$global:LASTEXITCODE
        $result[-1].GetType().FullName | Should -BeExactly 'System.Int32'
        $result[-1] | Should -Be $Code
        $exitCode.GetType().FullName | Should -BeExactly 'System.Int32'
        $exitCode | Should -Be $Code
        $calls=@('check','ra')
        if ($Code -eq 0) { $calls+=@('build') }
        @(Get-StreamCall) | Should -Be $calls
        $streamed=if ($Json) { @($calls|Where-Object {$_ -ne 'ra'}) } else { $calls }
        $frames=@(Get-StreamFrame -Values $result)
        @($frames.phase) | Should -Be $streamed
        $result.Count | Should -Be ($streamed.Count+1)
        if ($Json) { (Get-Content -LiteralPath '.cache/ra-diagnostics.json' -Raw|ConvertFrom-Json).code | Should -Be $Code }
    }

    It 'runs the main child once without preflight output for a genuine disabled gate' {
        $result=@(Invoke-CargoWrapper -ArgumentList @('build','--no-preflight'))
        $exitCode=$global:LASTEXITCODE
        $result[-1] | Should -Be 0
        $exitCode | Should -Be 0
        @(Get-StreamCall) | Should -Be @('build')
        $result.Count | Should -Be 2
    }

    It 'keeps <Label> child tokens after the Cargo separator without changing preflight state' -ForEach @(
        @{Label='LLM output';Tokens=@('--llm-output')}
        @{Label='disable';Tokens=@('--no-preflight')}
        @{Label='mode';Tokens=@('--preflight-mode','all')}
    ) {
        $arguments=@('build','--')+$Tokens
        $split=& $script:StreamModule { param($arguments) Split-PreflightArgs -InputArgs $arguments } $arguments
        @($split.Remaining) | Should -Be $arguments
        $split.State.Enabled | Should -BeFalse
        $split.State.ExplicitDisable | Should -BeFalse
        $split.State.JsonOutput | Should -BeFalse
        $split.State.Mode | Should -BeNullOrEmpty
    }

    It 'replays RA without a file when an LLM token belongs to the child and preserves that native token' {
        $arguments=@('build','--preflight-mode','check','--preflight-blocking','--preflight-force','--preflight-ra','--','--llm-output')
        $result=@(Invoke-CargoWrapper -ArgumentList $arguments)
        $exitCode=$global:LASTEXITCODE
        $result[-1] | Should -Be 0
        $exitCode | Should -Be 0
        @((Get-StreamFrame -Values $result).phase) | Should -Be @('check','ra','build')
        $result.Count | Should -Be 4
        Test-Path -LiteralPath '.cache/ra-diagnostics.json' | Should -BeFalse
        $nativeArguments=@(Get-Content -LiteralPath $env:PCAI_STREAM_ARGV_LOG)
        $nativeArguments[-1] | Should -BeExactly 'run stable cargo build -- --llm-output'
    }

    It 'injects LLM format with <Label> arguments and retains the separator position' -ForEach @(
        @{Label='empty Cargo part';Tokens=@('--');Expected=@('--message-format=json','--')}
        @{Label='empty child part';Tokens=@('build','--');Expected=@('build','--message-format=json','--')}
        @{Label='no arguments';Tokens=@();Expected=@('--message-format=json')}
        @{Label='an empty-string child';Tokens=@('build','--','');Expected=@('build','--message-format=json','--','')}
    ) {
        $result=@(& $script:StreamModule { param($tokens) Get-MessageFormatArgs -PrimaryCommand build -ArgsList $tokens } $Tokens)
        $result | Should -Be $Expected
        @(Get-StreamCall).Count | Should -Be 0
    }

    It 'reaches the native build with top-level LLM output and an empty child tail' {
        $result=@(Invoke-CargoWrapper -ArgumentList @('build','--llm-output','--'))
        $exitCode=$global:LASTEXITCODE
        $result[-1].GetType().FullName | Should -BeExactly 'System.Int32'
        $result[-1] | Should -Be 0
        $exitCode | Should -Be 0
        @(Get-StreamCall) | Should -Be @('build')
        $nativeArguments=@(Get-Content -LiteralPath $env:PCAI_STREAM_ARGV_LOG)
        $nativeArguments[-1] | Should -BeExactly 'run stable cargo build --message-format=json --'
        $result.Count | Should -Be 2
    }

    It 'retains genuine top-level LLM no-argument invocation without inventing a build command' {
        $result=@(Invoke-CargoWrapper -ArgumentList @('--llm-output'))
        $exitCode=$global:LASTEXITCODE
        $result[-1].GetType().FullName | Should -BeExactly 'System.Int32'
        $result[-1] | Should -Be 0
        $exitCode | Should -Be 0
        $nativeArguments=@(Get-Content -LiteralPath $env:PCAI_STREAM_ARGV_LOG)
        $nativeArguments[-1] | Should -BeExactly 'run stable cargo'
        $result.Count | Should -Be 2
    }
}
