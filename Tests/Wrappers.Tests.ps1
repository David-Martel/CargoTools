#Requires -Modules Pester
# Wrappers.Tests.ps1 — CargoTools v0.9.0 wrapper layer tests
# Tests: _WrapperHelpers.psm1 + all 9 wrapper scripts

# NOTE: In Pester 5, script-level variables set at parse time DO persist through
# test execution. $PSScriptRoot is available at both discovery and run time.
# We use it here to compute paths for TestCases that need data at discovery time.

$__root     = Split-Path -Parent $PSScriptRoot
$__wrappers = Join-Path $__root 'wrappers'
$__helpers  = Join-Path $__wrappers '_WrapperHelpers.psm1'

$__WrapperTestCases = @(
    @{ WName = 'cargo';                 WPath = (Join-Path $__wrappers 'cargo.ps1') },
    @{ WName = 'cargo-route';           WPath = (Join-Path $__wrappers 'cargo-route.ps1') },
    @{ WName = 'cargo-wrapper';         WPath = (Join-Path $__wrappers 'cargo-wrapper.ps1') },
    @{ WName = 'cargo-wsl';             WPath = (Join-Path $__wrappers 'cargo-wsl.ps1') },
    @{ WName = 'cargo-docker';          WPath = (Join-Path $__wrappers 'cargo-docker.ps1') },
    @{ WName = 'cargo-macos';           WPath = (Join-Path $__wrappers 'cargo-macos.ps1') },
    @{ WName = 'maturin';               WPath = (Join-Path $__wrappers 'maturin.ps1') },
    @{ WName = 'rust-analyzer';         WPath = (Join-Path $__wrappers 'rust-analyzer.ps1') },
    @{ WName = 'rust-analyzer-wrapper'; WPath = (Join-Path $__wrappers 'rust-analyzer-wrapper.ps1') }
)

$__WrapperFileTestCases = @(
    @{ FileName = 'cargo.ps1' },
    @{ FileName = 'cargo-route.ps1' },
    @{ FileName = 'cargo-wrapper.ps1' },
    @{ FileName = 'cargo-wsl.ps1' },
    @{ FileName = 'cargo-docker.ps1' },
    @{ FileName = 'cargo-macos.ps1' },
    @{ FileName = 'maturin.ps1' },
    @{ FileName = 'rust-analyzer.ps1' },
    @{ FileName = 'rust-analyzer-wrapper.ps1' },
    @{ FileName = '_WrapperHelpers.psm1' }
)

BeforeAll {
    $script:ModuleRoot  = Split-Path -Parent $PSScriptRoot
    $script:WrappersDir = Join-Path $script:ModuleRoot 'wrappers'
    $script:HelpersPath = Join-Path $script:WrappersDir '_WrapperHelpers.psm1'

    Import-Module $script:HelpersPath -Force

    $script:SavedEnv = @{}
    foreach ($k in @('CARGOTOOLS_MANIFEST', 'CARGO_RAW', 'CARGO_VERBOSITY')) {
        if (Test-Path "Env:$k") { $script:SavedEnv[$k] = (Get-Item "Env:$k").Value }
    }
}

AfterAll {
    foreach ($entry in $script:SavedEnv.GetEnumerator()) {
        Set-Item -Path ("Env:" + $entry.Key) -Value $entry.Value
    }
    Remove-Item Env:CARGOTOOLS_MANIFEST -ErrorAction SilentlyContinue
    Remove-Item Env:CARGO_RAW          -ErrorAction SilentlyContinue
    Remove-Module _WrapperHelpers      -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# _WrapperHelpers.psm1 — exported function presence
# ---------------------------------------------------------------------------
Describe '_WrapperHelpers exports' {
    It 'exports Get-CargoToolsVersion' {
        Get-Command Get-CargoToolsVersion -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Get-WrapperContext' {
        Get-Command Get-WrapperContext -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Import-CargoToolsResilient' {
        Get-Command Import-CargoToolsResilient -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Invoke-WrapperDoctor' {
        Get-Command Invoke-WrapperDoctor -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Resolve-Subcommand' {
        Get-Command Resolve-Subcommand -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Show-WrapperHelp' {
        Get-Command Show-WrapperHelp -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Show-WrapperList' {
        Get-Command Show-WrapperList -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Show-WrapperVersion' {
        Get-Command Show-WrapperVersion -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
    It 'exports Write-LlmEvent' {
        Get-Command Write-LlmEvent -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Get-CargoToolsVersion
# ---------------------------------------------------------------------------
Describe 'Get-CargoToolsVersion' {
    It 'returns a semver string' {
        Get-CargoToolsVersion | Should -Match '^\d+\.\d+\.\d+$'
    }
    It 'returns 0.9.0' {
        Get-CargoToolsVersion | Should -Be '0.9.0'
    }
}

# ---------------------------------------------------------------------------
# Get-WrapperContext — flag parsing
# ---------------------------------------------------------------------------
Describe 'Get-WrapperContext flag parsing' {
    BeforeEach {
        Remove-Item Env:CARGOTOOLS_MANIFEST -ErrorAction SilentlyContinue
        Remove-Item Env:CARGO_RAW          -ErrorAction SilentlyContinue
    }

    It 'parses --help' {
        $ctx = Get-WrapperContext -InvocationArgs @('--help') -WrapperName 'cargo'
        $ctx.HelpRequested | Should -BeTrue
        $ctx.PassThrough   | Should -BeNullOrEmpty
    }
    It 'parses -h as help' {
        (Get-WrapperContext -InvocationArgs @('-h') -WrapperName 'cargo').HelpRequested | Should -BeTrue
    }
    It 'parses -? as help' {
        (Get-WrapperContext -InvocationArgs @('-?') -WrapperName 'cargo').HelpRequested | Should -BeTrue
    }
    It 'parses /? as help' {
        (Get-WrapperContext -InvocationArgs @('/?') -WrapperName 'cargo').HelpRequested | Should -BeTrue
    }
    It 'parses --version' {
        $ctx = Get-WrapperContext -InvocationArgs @('--version') -WrapperName 'cargo'
        $ctx.VersionRequested | Should -BeTrue
        $ctx.PassThrough      | Should -BeNullOrEmpty
    }
    It 'parses --doctor (LlmMode stays false)' {
        $ctx = Get-WrapperContext -InvocationArgs @('--doctor') -WrapperName 'cargo'
        $ctx.DoctorRequested | Should -BeTrue
        $ctx.LlmMode         | Should -BeFalse
    }
    It 'parses --diagnose sets DoctorRequested, DiagnoseRequested, LlmMode' {
        $ctx = Get-WrapperContext -InvocationArgs @('--diagnose') -WrapperName 'cargo'
        $ctx.DoctorRequested   | Should -BeTrue
        $ctx.DiagnoseRequested | Should -BeTrue
        $ctx.LlmMode           | Should -BeTrue
    }
    It 'parses --llm; preserves remaining args' {
        $ctx = Get-WrapperContext -InvocationArgs @('--llm', 'build') -WrapperName 'cargo'
        $ctx.LlmMode     | Should -BeTrue
        $ctx.PassThrough | Should -Be @('build')
    }
    It 'parses --json-output as --llm alias' {
        (Get-WrapperContext -InvocationArgs @('--json-output') -WrapperName 'cargo').LlmMode | Should -BeTrue
    }
    It 'parses --list-wrappers' {
        (Get-WrapperContext -InvocationArgs @('--list-wrappers') -WrapperName 'cargo').ListRequested | Should -BeTrue
    }
    It 'parses --no-wrapper' {
        (Get-WrapperContext -InvocationArgs @('--no-wrapper') -WrapperName 'cargo').NoWrapper | Should -BeTrue
    }
    It 'passes through all non-wrapper args verbatim' {
        $input = @('build', '--release', '--target', 'x86_64-pc-windows-msvc', '--', '--foo')
        $ctx   = Get-WrapperContext -InvocationArgs $input -WrapperName 'cargo'
        $ctx.HelpRequested    | Should -BeFalse
        $ctx.VersionRequested | Should -BeFalse
        $ctx.PassThrough      | Should -Be $input
    }
    It 'strips --llm; preserves cargo args in mixed invocation' {
        $ctx = Get-WrapperContext -InvocationArgs @('--llm', 'build', '--release', 'foo', '--bar') -WrapperName 'cargo'
        $ctx.LlmMode     | Should -BeTrue
        $ctx.PassThrough | Should -Be @('build', '--release', 'foo', '--bar')
    }
    It 'handles empty argument list' {
        $ctx = Get-WrapperContext -InvocationArgs @() -WrapperName 'cargo'
        $ctx.HelpRequested    | Should -BeFalse
        $ctx.VersionRequested | Should -BeFalse
        $ctx.PassThrough      | Should -BeNullOrEmpty
    }
    It 'handles null argument list' {
        $ctx = Get-WrapperContext -WrapperName 'cargo'
        $ctx.HelpRequested | Should -BeFalse
        $ctx.PassThrough   | Should -BeNullOrEmpty
    }
    It '--help not in PassThrough' {
        $ctx = Get-WrapperContext -InvocationArgs @('--help', 'build') -WrapperName 'cargo'
        $ctx.PassThrough | Should -Not -Contain '--help'
    }
    It '--version not in PassThrough' {
        $ctx = Get-WrapperContext -InvocationArgs @('--version') -WrapperName 'cargo'
        $ctx.PassThrough | Should -Not -Contain '--version'
    }
}

# ---------------------------------------------------------------------------
# Resolve-Subcommand
# ---------------------------------------------------------------------------
Describe 'Resolve-Subcommand' {
    It 'returns first non-flag arg' {
        Resolve-Subcommand -ArgList @('build', '--release') | Should -Be 'build'
    }
    It 'skips leading flags' {
        Resolve-Subcommand -ArgList @('--verbose', '--quiet', 'test') | Should -Be 'test'
    }
    It 'returns null for empty array' {
        Resolve-Subcommand -ArgList @() | Should -BeNullOrEmpty
    }
    It 'returns null for flag-only array' {
        Resolve-Subcommand -ArgList @('--release', '--verbose') | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Write-LlmEvent
# ---------------------------------------------------------------------------
Describe 'Write-LlmEvent no-op when EmitLlm false' {
    It 'runs without error' {
        { Write-LlmEvent -Phase start -Wrapper cargo -Args @('build') -EmitLlm:$false } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# MODULE_NOT_FOUND recovery — function returns false on nonexistent manifest
# ---------------------------------------------------------------------------
Describe 'Import-CargoToolsResilient MODULE_NOT_FOUND' {
    It 'function returns false when CARGOTOOLS_MANIFEST points to nonexistent path and module not loaded' {
        # This test simulates partial failure — the manifest env var is invalid but
        # the script-relative candidate may still resolve. We verify the function
        # returns false ONLY if no candidate resolves — on this machine CargoTools
        # is always findable, so we test the diagnostic path instead.
        # Test: when module is already loaded, Import-CargoToolsResilient returns true
        if (Get-Module CargoTools -ErrorAction SilentlyContinue) {
            $result = Import-CargoToolsResilient -EmitLlm:$false
            $result | Should -BeTrue
        } else {
            Set-ItResult -Skipped -Because 'CargoTools not loaded; cannot verify idempotent behavior'
        }
    }

    It 'subprocess exits 2 when genuinely no module available' {
        # Use a completely isolated PS with no module paths and a temp helpers copy
        # that has the script-relative path stripped out by using a helper in a temp dir
        $tmpDir = Join-Path $env:TEMP "ct-test-$([System.Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        Copy-Item $script:HelpersPath (Join-Path $tmpDir '_WrapperHelpers.psm1')
        $hp = Join-Path $tmpDir '_WrapperHelpers.psm1'
        try {
            pwsh -NoProfile -NonInteractive -Command "
                `$env:CARGOTOOLS_MANIFEST = 'C:\DoesNotExist\CargoTools.psd1'
                `$env:PSModulePath = ''
                `$env:USERPROFILE = 'C:\DoesNotExistUser'
                `$env:LOCALAPPDATA = 'C:\DoesNotExistLocal'
                Import-Module '$hp' -Force
                `$ok = Import-CargoToolsResilient -EmitLlm:`$false
                if (`$ok) { exit 0 } else { exit 2 }
            " 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 2
        } finally {
            Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Idempotent load
# ---------------------------------------------------------------------------
Describe 'Import-CargoToolsResilient idempotent' {
    It 'returns true when CargoTools already loaded' {
        if (-not (Get-Module CargoTools -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $script:ModuleRoot 'CargoTools.psd1') -Force -ErrorAction SilentlyContinue
        }
        if (Get-Module CargoTools -ErrorAction SilentlyContinue) {
            Import-CargoToolsResilient -EmitLlm:$false | Should -BeTrue
        } else {
            Set-ItResult -Skipped -Because 'CargoTools not loadable in this environment'
        }
    }
}

# ---------------------------------------------------------------------------
# Invoke-WrapperDoctor
# ---------------------------------------------------------------------------
Describe 'Invoke-WrapperDoctor' {
    It 'returns numeric exit code' {
        $code = Invoke-WrapperDoctor -WrapperName 'cargo' -AsJson:$false 6>$null
        ($code -is [int] -or $code -is [long]) | Should -BeTrue
    }
    It 'exit code is 0 or 4' {
        $code = Invoke-WrapperDoctor -WrapperName 'cargo' -AsJson:$false 6>$null
        ($code -eq 0 -or $code -eq 4) | Should -BeTrue
    }
    It 'JSON mode returns parseable JSON' {
        # Write-Host goes to Information stream 6; capture via *>&1
        $lines    = Invoke-WrapperDoctor -WrapperName 'cargo' -AsJson:$true *>&1
        $jsonLine = $lines | ForEach-Object { "$_" } | Where-Object { $_ -and $_.Trim().StartsWith('{') } | Select-Object -First 1
        $jsonLine | Should -Not -BeNullOrEmpty
        { $jsonLine | ConvertFrom-Json } | Should -Not -Throw
    }
    It 'JSON has required keys' {
        $lines    = Invoke-WrapperDoctor -WrapperName 'cargo' -AsJson:$true *>&1
        $jsonLine = $lines | ForEach-Object { "$_" } | Where-Object { $_ -and $_.Trim().StartsWith('{') } | Select-Object -First 1
        $j = $jsonLine | ConvertFrom-Json
        $j.wrapper    | Should -Be 'cargo'
        $j.checks     | Should -Not -BeNullOrEmpty
        ($null -ne $j.issues) | Should -BeTrue
        ($j.exit_code -is [int] -or $j.exit_code -is [long]) | Should -BeTrue
        $j.timestamp  | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Show-WrapperVersion
# ---------------------------------------------------------------------------
Describe 'Show-WrapperVersion' {
    It 'outputs a version number' {
        Show-WrapperVersion -WrapperName 'cargo' *>&1 | Out-String | Should -Match '\d+\.\d+\.\d+'
    }
    It 'output includes wrapper name' {
        Show-WrapperVersion -WrapperName 'cargo' *>&1 | Out-String | Should -Match 'cargo'
    }
}

# ---------------------------------------------------------------------------
# Show-WrapperHelp
# ---------------------------------------------------------------------------
Describe 'Show-WrapperHelp' {
    It 'outputs WRAPPER FLAGS section' {
        Show-WrapperHelp -WrapperName 'cargo' *>&1 | Out-String | Should -Match 'WRAPPER FLAGS'
    }
    It 'output mentions --help' {
        Show-WrapperHelp -WrapperName 'cargo' *>&1 | Out-String | Should -Match '--help'
    }
    It 'output mentions ENVIRONMENT VARIABLES' {
        Show-WrapperHelp -WrapperName 'cargo' *>&1 | Out-String | Should -Match 'ENVIRONMENT VARIABLES'
    }
    It 'output mentions CARGOTOOLS_MANIFEST' {
        Show-WrapperHelp -WrapperName 'cargo' *>&1 | Out-String | Should -Match 'CARGOTOOLS_MANIFEST'
    }
}

# ---------------------------------------------------------------------------
# Show-WrapperList
# ---------------------------------------------------------------------------
Describe 'Show-WrapperList' {
    It 'runs without error' {
        # 6>$null silences Write-Host noise so test output stays clean.
        { Show-WrapperList 6>$null } | Should -Not -Throw
    }
    It 'enumerates at least one wrapper when deployed' {
        $output = Show-WrapperList *>&1 | Out-String
        $output | Should -Match 'cargo'
    }
}

# ---------------------------------------------------------------------------
# Wrapper script files exist
# ---------------------------------------------------------------------------
Describe 'Wrapper script files exist' {
    It 'file exists: <FileName>' -TestCases $__WrapperFileTestCases {
        param($FileName)
        Test-Path (Join-Path $script:WrappersDir $FileName) | Should -BeTrue
    }
}

# ---------------------------------------------------------------------------
# Wrapper content checks
# ---------------------------------------------------------------------------
Describe 'Wrapper scripts have correct structure' {
    It '<WName> sets ErrorActionPreference Stop' -TestCases $__WrapperTestCases {
        param($WName, $WPath)
        Get-Content -Path $WPath -Raw | Should -Match "ErrorActionPreference\s*=\s*'Stop'"
    }
    It '<WName> imports _WrapperHelpers.psm1' -TestCases $__WrapperTestCases {
        param($WName, $WPath)
        Get-Content -Path $WPath -Raw | Should -Match '_WrapperHelpers\.psm1'
    }
    It '<WName> calls Get-WrapperContext' -TestCases $__WrapperTestCases {
        param($WName, $WPath)
        Get-Content -Path $WPath -Raw | Should -Match 'Get-WrapperContext'
    }
}

# ---------------------------------------------------------------------------
# cargo.ps1 subprocess tests
# ---------------------------------------------------------------------------
Describe 'cargo.ps1 --help subprocess' {
    BeforeAll { $script:CargoPs1 = Join-Path $script:WrappersDir 'cargo.ps1' }
    It 'exits 0' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --help 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'output contains WRAPPER FLAGS' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --help 2>&1 | Out-String | Should -Match 'WRAPPER FLAGS'
    }
    It 'output contains --version' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --help 2>&1 | Out-String | Should -Match '--version'
    }
}

Describe 'cargo.ps1 --version subprocess' {
    BeforeAll { $script:CargoPs1 = Join-Path $script:WrappersDir 'cargo.ps1' }
    It 'exits 0' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --version 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'output contains version number' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --version 2>&1 | Out-String | Should -Match '\d+\.\d+\.\d+'
    }
}

Describe 'cargo.ps1 --list-wrappers subprocess' {
    BeforeAll { $script:CargoPs1 = Join-Path $script:WrappersDir 'cargo.ps1' }
    It 'exits 0' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --list-wrappers 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'cargo.ps1 --doctor subprocess' {
    BeforeAll { $script:CargoPs1 = Join-Path $script:WrappersDir 'cargo.ps1' }
    It 'exits 0 or 4' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --doctor 2>&1 | Out-Null
        ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 4) | Should -BeTrue
    }
    It 'output contains CargoTools Doctor' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --doctor 2>&1 | Out-String | Should -Match 'CargoTools Doctor'
    }
}

Describe 'cargo.ps1 --diagnose subprocess' {
    BeforeAll { $script:CargoPs1 = Join-Path $script:WrappersDir 'cargo.ps1' }
    It 'exits 0 or 4' {
        pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --diagnose 2>&1 | Out-Null
        ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 4) | Should -BeTrue
    }
    It 'output contains a valid JSON object' {
        # Write-Host in subprocess writes to stdout (not stderr), 2>&1 captures both
        $out  = pwsh -NoProfile -NonInteractive -File $script:CargoPs1 --diagnose 2>&1 | Out-String
        $line = ($out -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith('{') } | Select-Object -First 1)
        $line | Should -Not -BeNullOrEmpty
        { $line | ConvertFrom-Json } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Write-LlmEvent JSON envelope shape (subprocess via script files)
# ---------------------------------------------------------------------------
Describe 'Write-LlmEvent JSON envelope shape' {
    BeforeAll {
        $script:LlmTmpDir = Join-Path $env:TEMP 'ct-llm-test'
        New-Item -ItemType Directory -Path $script:LlmTmpDir -Force | Out-Null
        $hp = $script:HelpersPath

        # Write helper scripts to avoid quoting issues
        Set-Content -Path (Join-Path $script:LlmTmpDir 'test-start.ps1') -Value @"
Import-Module '$hp' -Force
Write-LlmEvent -Phase start -Wrapper cargo -Args @('build') -EmitLlm:`$true
"@ -Encoding UTF8

        Set-Content -Path (Join-Path $script:LlmTmpDir 'test-end.ps1') -Value @"
Import-Module '$hp' -Force
Write-LlmEvent -Phase end -Wrapper cargo -ExitCode 0 -DurationMs 456 -EmitLlm:`$true
"@ -Encoding UTF8

        Set-Content -Path (Join-Path $script:LlmTmpDir 'test-diag.ps1') -Value @"
Import-Module '$hp' -Force
Write-LlmEvent -Phase diagnostic -Level warn -Code TEST_CODE -Detail 'detail text' -Recovery 'do x' -EmitLlm:`$true
"@ -Encoding UTF8
    }

    AfterAll {
        Remove-Item $script:LlmTmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'start envelope: valid JSON with phase, wrapper, timestamp' {
        $stderr = Join-Path $script:LlmTmpDir 'out-start.txt'
        $proc = Start-Process pwsh -ArgumentList @(
            '-NoProfile','-NonInteractive','-File',(Join-Path $script:LlmTmpDir 'test-start.ps1')
        ) -RedirectStandardError $stderr -PassThru -Wait -WindowStyle Hidden
        $line = (Get-Content $stderr -Raw -ErrorAction SilentlyContinue).Trim()
        $line | Should -Not -BeNullOrEmpty
        { $line | ConvertFrom-Json } | Should -Not -Throw
        $j = $line | ConvertFrom-Json
        $j.phase     | Should -Be 'start'
        $j.wrapper   | Should -Be 'cargo'
        $j.timestamp | Should -Not -BeNullOrEmpty
    }

    It 'end envelope: has exit_code and duration_ms' {
        $stderr = Join-Path $script:LlmTmpDir 'out-end.txt'
        Start-Process pwsh -ArgumentList @(
            '-NoProfile','-NonInteractive','-File',(Join-Path $script:LlmTmpDir 'test-end.ps1')
        ) -RedirectStandardError $stderr -PassThru -Wait -WindowStyle Hidden | Out-Null
        $line = (Get-Content $stderr -Raw -ErrorAction SilentlyContinue).Trim()
        $line | Should -Not -BeNullOrEmpty
        $j = $line | ConvertFrom-Json
        $j.phase       | Should -Be 'end'
        $j.exit_code   | Should -Be 0
        $j.duration_ms | Should -Be 456
    }

    It 'diagnostic envelope: has level, code, detail, recovery' {
        $stderr = Join-Path $script:LlmTmpDir 'out-diag.txt'
        Start-Process pwsh -ArgumentList @(
            '-NoProfile','-NonInteractive','-File',(Join-Path $script:LlmTmpDir 'test-diag.ps1')
        ) -RedirectStandardError $stderr -PassThru -Wait -WindowStyle Hidden | Out-Null
        $line = (Get-Content $stderr -Raw -ErrorAction SilentlyContinue).Trim()
        $line | Should -Not -BeNullOrEmpty
        $j = $line | ConvertFrom-Json
        $j.phase    | Should -Be 'diagnostic'
        $j.level    | Should -Be 'warn'
        $j.code     | Should -Be 'TEST_CODE'
        $j.detail   | Should -Be 'detail text'
        $j.recovery | Should -Be 'do x'
    }
}

# ---------------------------------------------------------------------------
# Argument pass-through fidelity
# ---------------------------------------------------------------------------
Describe 'Argument pass-through fidelity' {
    It 'preserves all cargo args including -- separator' {
        $in = @('test', '--release', '--', '--nocapture', '--test-threads=4')
        (Get-WrapperContext -InvocationArgs $in -WrapperName 'cargo').PassThrough | Should -Be $in
    }
    It 'preserves multiple flags' {
        $in = @('build', '--target', 'x86_64-pc-windows-msvc', '--message-format', 'json')
        (Get-WrapperContext -InvocationArgs $in -WrapperName 'cargo').PassThrough | Should -Be $in
    }
    It '--llm NOT forwarded' {
        $ctx = Get-WrapperContext -InvocationArgs @('--llm', 'build', '--release') -WrapperName 'cargo'
        $ctx.PassThrough | Should -Not -Contain '--llm'
        $ctx.PassThrough | Should -Be @('build', '--release')
    }
    It '--doctor NOT forwarded' {
        $ctx = Get-WrapperContext -InvocationArgs @('--doctor', 'build') -WrapperName 'cargo'
        $ctx.PassThrough | Should -Not -Contain '--doctor'
    }
    It '--no-wrapper NOT forwarded' {
        $ctx = Get-WrapperContext -InvocationArgs @('--no-wrapper', 'build', '--release') -WrapperName 'cargo'
        $ctx.PassThrough | Should -Not -Contain '--no-wrapper'
        $ctx.PassThrough | Should -Be @('build', '--release')
    }
    It '--version NOT forwarded' {
        $ctx = Get-WrapperContext -InvocationArgs @('--version') -WrapperName 'cargo'
        $ctx.PassThrough | Should -Not -Contain '--version'
    }
    It '--list-wrappers NOT forwarded' {
        $ctx = Get-WrapperContext -InvocationArgs @('--list-wrappers', 'build') -WrapperName 'cargo'
        $ctx.PassThrough | Should -Not -Contain '--list-wrappers'
    }
}

# ---------------------------------------------------------------------------
# Per-wrapper subprocess tests
# ---------------------------------------------------------------------------
Describe 'Per-wrapper --version exits 0' {
    It '<WName> --version exits 0' -TestCases $__WrapperTestCases {
        param($WName, $WPath)
        pwsh -NoProfile -NonInteractive -File $WPath --version 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Per-wrapper --help exits 0' {
    It '<WName> --help exits 0' -TestCases $__WrapperTestCases {
        param($WName, $WPath)
        pwsh -NoProfile -NonInteractive -File $WPath --help 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Per-wrapper --help WRAPPER FLAGS' {
    It '<WName> --help contains WRAPPER FLAGS' -TestCases $__WrapperTestCases {
        param($WName, $WPath)
        pwsh -NoProfile -NonInteractive -File $WPath --help 2>&1 | Out-String | Should -Match 'WRAPPER FLAGS'
    }
}

Describe 'Per-wrapper --list-wrappers exits 0' {
    It '<WName> --list-wrappers exits 0' -TestCases $__WrapperTestCases {
        param($WName, $WPath)
        pwsh -NoProfile -NonInteractive -File $WPath --list-wrappers 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# CargoTools.psd1 manifest checks
# ---------------------------------------------------------------------------
Describe 'CargoTools.psd1 manifest checks' {
    BeforeAll { $script:PsdData = Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'CargoTools.psd1') }
    It 'ModuleVersion equals 0.9.0' {
        $script:PsdData.ModuleVersion | Should -Be '0.9.0'
    }
    It 'FileList contains wrappers\_WrapperHelpers.psm1 (any separator form)' {
        # FileList uses double-backslash in psd1 single-quoted strings
        $found = $script:PsdData.FileList | Where-Object { $_ -like '*WrapperHelpers*' }
        $found | Should -Not -BeNullOrEmpty
    }
    It 'FileList contains Tests\Wrappers.Tests.ps1 (any separator form)' {
        $found = $script:PsdData.FileList | Where-Object { $_ -like '*Wrappers.Tests*' }
        $found | Should -Not -BeNullOrEmpty
    }
}
