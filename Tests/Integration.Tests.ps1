#Requires -Modules Pester
<#
.SYNOPSIS
Integration tests for CargoTools module.
.DESCRIPTION
End-to-end tests that exercise the full wrapper pipeline including
module import, argument flow, environment setup, and cross-function interactions.
These tests may invoke actual Rust tooling.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    $script:ModuleUnderTest = Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force -PassThru
}

Describe 'Module Import' {
    It 'Imports without errors' {
        { Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1') -Force } | Should -Not -Throw
    }

    It 'Exports expected public functions' {
        $expected = @(
            'Invoke-CargoRoute', 'Invoke-CargoWrapper', 'Invoke-CargoWsl',
            'Invoke-CargoDocker', 'Invoke-CargoMacos',
            'Invoke-RustAnalyzerWrapper', 'Test-RustAnalyzerHealth',
            'Test-BuildEnvironment', 'Initialize-RustDefaults',
            'Initialize-CargoEnv', 'Start-SccacheServer', 'Stop-SccacheServer',
            'Get-SccacheMemoryMB', 'Get-OptimalBuildJobs',
            'Resolve-RustAnalyzerPath', 'Get-RustAnalyzerMemoryMB', 'Test-RustAnalyzerSingleton',
            'Format-CargoOutput', 'Format-CargoError', 'ConvertTo-LlmContext',
            'Get-RustProjectContext', 'Get-CargoContextSnapshot'
        )
        $exported = (Get-Module CargoTools).ExportedFunctions.Keys
        foreach ($fn in $expected) {
            $exported | Should -Contain $fn -Because "$fn should be exported"
        }
    }

    It 'Module version matches manifest' {
        $manifest = Import-PowerShellDataFile (Join-Path (Split-Path $PSScriptRoot -Parent) 'CargoTools.psd1')
        $script:ModuleUnderTest.Version.ToString() | Should -Be $manifest.ModuleVersion
    }
}

Describe 'Invoke-CargoWrapper --raw mode' -Tag 'Integration' {
    It 'Passes --version through raw mode' {
        $rustupPath = "$env:USERPROFILE\.cargo\bin\rustup.exe"
        if (-not (Test-Path $rustupPath)) {
            Set-ItResult -Skipped -Because 'rustup not installed'
            return
        }
        $result = Invoke-CargoWrapper --raw --version 6>&1 2>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*cargo*'
    }

    It 'Raw mode does not produce wrapper output' {
        $rustupPath = "$env:USERPROFILE\.cargo\bin\rustup.exe"
        if (-not (Test-Path $rustupPath)) {
            Set-ItResult -Skipped -Because 'rustup not installed'
            return
        }
        $result = Invoke-CargoWrapper --raw --version 6>&1 2>&1
        $output = $result -join "`n"
        $output | Should -Not -BeLike '*Environment*'
        $output | Should -Not -BeLike '*Build*==='
    }

    It 'CARGO_RAW env var enables raw mode' {
        $rustupPath = "$env:USERPROFILE\.cargo\bin\rustup.exe"
        if (-not (Test-Path $rustupPath)) {
            Set-ItResult -Skipped -Because 'rustup not installed'
            return
        }
        $env:CARGO_RAW = '1'
        try {
            $result = Invoke-CargoWrapper --version 6>&1 2>&1
            $output = $result -join "`n"
            $output | Should -Not -BeLike '*Environment*'
        } finally {
            Remove-Item Env:CARGO_RAW -ErrorAction SilentlyContinue
        }
    }
}

Describe 'No TRACE output at default verbosity' -Tag 'Integration' {
    It 'No TRACE lines in normal build output' {
        $rustupPath = "$env:USERPROFILE\.cargo\bin\rustup.exe"
        if (-not (Test-Path $rustupPath)) {
            Set-ItResult -Skipped -Because 'rustup not installed'
            return
        }
        # Use --version as a quick non-build command
        $result = Invoke-CargoWrapper --version 6>&1 2>&1
        $output = $result -join "`n"
        $output | Should -Not -Match '\[TRACE\]'
        $output | Should -Not -Match 'Hex:'
    }
}

Describe 'WSL Argument Escaping' -Tag 'Integration' {
    BeforeAll {
        $module = $script:ModuleUnderTest
        $script:ConvertArgsToShell = & $module { ${function:Convert-ArgsToShell} }
    }

    It 'Properly escapes dollar signs for WSL' {
        $result = & $script:ConvertArgsToShell @('--env', '$HOME/project')
        # Dollar sign triggers quoting, so the arg should be wrapped in single quotes
        # Verify the result contains the arg wrapped in single quotes
        $result | Should -BeLike "*'*HOME/project'*"
        # Verify it starts with --env
        $result | Should -BeLike '--env *'
    }

    It 'Preserves simple flags unchanged' {
        $result = & $script:ConvertArgsToShell @('build', '--release', '--target=x86_64-unknown-linux-gnu')
        $result | Should -Be 'build --release --target=x86_64-unknown-linux-gnu'
    }

    It 'Quotes paths with spaces' {
        $result = & $script:ConvertArgsToShell @('--manifest-path', '/path/to my/Cargo.toml')
        $result | Should -BeLike "*'/path/to my/Cargo.toml'*"
    }
}

Describe 'Cross-function dependency chain' {
    It 'Get-PrimaryCommand works with verbosity-filtered args' {
        $module = $script:ModuleUnderTest
        $getVerbArgs = & $module { ${function:Get-VerbosityArgs} }
        $getPrimary = & $module { ${function:Get-PrimaryCommand} }

        $raw = @('-v', 'build', '--release')
        $filtered = & $getVerbArgs $raw
        $cmd = & $getPrimary $filtered
        $cmd | Should -Be 'build'
    }

    It 'Ensure-RunArgSeparator works after verbosity filtering' {
        $module = $script:ModuleUnderTest
        $getVerbArgs = & $module { ${function:Get-VerbosityArgs} }
        $ensureSep = & $module { ${function:Ensure-RunArgSeparator} }

        $raw = @('-v', 'run', '--release', 'myarg')
        $filtered = & $getVerbArgs $raw
        $result = & $ensureSep $filtered
        $result | Should -Contain '--'
    }
}
