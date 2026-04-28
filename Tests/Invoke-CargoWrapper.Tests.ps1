#Requires -Modules Pester
<#
.SYNOPSIS
Pester tests for Invoke-CargoWrapper and wrapper-level features.
.DESCRIPTION
Tests for --raw mode, --nextest, --llm-output, verbosity, and argument handling.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    $module = Get-Module CargoTools
    $script:InitVerbosity = & $module { ${function:Initialize-CargoVerbosity} }
    $script:GetVerbosity = & $module { ${function:Get-CargoVerbosity} }
    $script:SetVerbosity = & $module { ${function:Set-CargoVerbosity} }
    $script:GetVerbosityArgs = & $module { ${function:Get-VerbosityArgs} }
    $script:InitLlmOutput = & $module { ${function:Initialize-CargoLlmOutput} }
    $script:TestIsBuildCommand = & $module { ${function:Test-IsBuildCommand} }
    $script:GetBuildProfile = & $module { ${function:Get-BuildProfile} }
}

Describe 'Verbosity System' {
    BeforeEach {
        & $script:SetVerbosity 1
        Remove-Item Env:CARGO_VERBOSITY -ErrorAction SilentlyContinue
    }

    Context 'Initialize-CargoVerbosity' {
        It 'Sets quiet from -q' {
            & $script:InitVerbosity @('-q')
            & $script:GetVerbosity | Should -Be 0
        }
        It 'Sets quiet from --quiet' {
            & $script:InitVerbosity @('--quiet')
            & $script:GetVerbosity | Should -Be 0
        }
        It 'Sets verbose from -v' {
            & $script:InitVerbosity @('-v')
            & $script:GetVerbosity | Should -Be 2
        }
        It 'Sets debug from -vv' {
            & $script:InitVerbosity @('-vv')
            & $script:GetVerbosity | Should -Be 3
        }
        It 'Sets debug from --debug' {
            & $script:InitVerbosity @('--debug')
            & $script:GetVerbosity | Should -Be 3
        }
        It 'Reads CARGO_VERBOSITY env var' {
            $env:CARGO_VERBOSITY = '2'
            try {
                & $script:InitVerbosity @()
                & $script:GetVerbosity | Should -Be 2
            } finally {
                Remove-Item Env:CARGO_VERBOSITY -ErrorAction SilentlyContinue
            }
        }
        It 'Activates LLM output mode from env' {
            $env:CARGO_VERBOSITY = 'llm'
            try {
                & $script:InitVerbosity @()
                # LLM mode sets verbosity to 1
                & $script:GetVerbosity | Should -Be 1
            } finally {
                Remove-Item Env:CARGO_VERBOSITY -ErrorAction SilentlyContinue
            }
        }
        It 'Arguments override env var' {
            $env:CARGO_VERBOSITY = '0'
            try {
                & $script:InitVerbosity @('-vv')
                & $script:GetVerbosity | Should -Be 3
            } finally {
                Remove-Item Env:CARGO_VERBOSITY -ErrorAction SilentlyContinue
            }
        }
    }

    Context 'Get-VerbosityArgs filtering' {
        It 'Removes -q' {
            $result = & $script:GetVerbosityArgs @('build', '-q', '--release')
            $result | Should -Not -Contain '-q'
            $result | Should -Contain 'build'
            $result | Should -Contain '--release'
        }
        It 'Removes --verbose' {
            $result = & $script:GetVerbosityArgs @('build', '--verbose')
            $result | Should -Not -Contain '--verbose'
        }
        It 'Removes -vv' {
            $result = & $script:GetVerbosityArgs @('build', '-vv')
            $result | Should -Not -Contain '-vv'
        }
        It 'Removes --llm-output' {
            $result = & $script:GetVerbosityArgs @('build', '--llm-output', '--release')
            $result | Should -Not -Contain '--llm-output'
            $result | Should -Contain '--release'
        }
        It 'Returns empty array for empty input' {
            $result = & $script:GetVerbosityArgs @()
            $result | Should -HaveCount 0
        }
    }
}

Describe 'LLM Output Mode' {
    BeforeEach {
        & $script:SetVerbosity 1
    }

    It 'Initialize-CargoLlmOutput sets mode' {
        & $script:InitLlmOutput
        & $script:GetVerbosity | Should -Be 1
    }
}

Describe 'Build Profile Detection' {
    It 'Detects --release' {
        & $script:GetBuildProfile @('build', '--release') | Should -Be 'release'
    }
    It 'Detects -r shorthand' {
        & $script:GetBuildProfile @('build', '-r') | Should -Be 'release'
    }
    It 'Detects --profile custom' {
        & $script:GetBuildProfile @('build', '--profile', 'bench') | Should -Be 'bench'
    }
    It 'Detects --profile=custom' {
        & $script:GetBuildProfile @('build', '--profile=release-lto') | Should -Be 'release-lto'
    }
    It 'Defaults to debug' {
        & $script:GetBuildProfile @('build') | Should -Be 'debug'
    }
}

Describe 'Build Command Detection' {
    It 'Recognizes build' {
        & $script:TestIsBuildCommand 'build' | Should -Be $true
    }
    It 'Recognizes b (alias)' {
        & $script:TestIsBuildCommand 'b' | Should -Be $true
    }
    It 'Recognizes run' {
        & $script:TestIsBuildCommand 'run' | Should -Be $true
    }
    It 'Recognizes test' {
        & $script:TestIsBuildCommand 'test' | Should -Be $true
    }
    It 'Recognizes bench' {
        & $script:TestIsBuildCommand 'bench' | Should -Be $true
    }
    It 'Does not recognize check' {
        & $script:TestIsBuildCommand 'check' | Should -Be $false
    }
    It 'Does not recognize clippy' {
        & $script:TestIsBuildCommand 'clippy' | Should -Be $false
    }
    It 'Does not recognize fmt' {
        & $script:TestIsBuildCommand 'fmt' | Should -Be $false
    }
}

Describe 'Invoke-CargoWrapper Help' {
    It 'Shows help with --wrapper-help' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*Centralized Rust build wrapper*'
    }

    It 'Help includes --raw documentation' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*--raw*'
        $output | Should -BeLike '*--passthrough*'
    }

    It 'Help includes --nextest documentation' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*--nextest*'
    }

    It 'Help includes --llm-output documentation' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*--llm-output*'
    }

    It 'Help includes --timings documentation' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*--timings*'
    }

    It 'Help includes --release-optimized documentation' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*--release-optimized*'
    }

    It 'Help includes CARGO_TIMINGS env var' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*CARGO_TIMINGS*'
    }

    It 'Help includes CARGO_RELEASE_LTO env var' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*CARGO_RELEASE_LTO*'
    }
}

Describe 'Quick-Check Flag' {
    It 'Help includes --quick-check documentation' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*--quick-check*'
    }

    It 'Help includes CARGO_QUICK_CHECK env var' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*CARGO_QUICK_CHECK*'
    }

    It 'Help includes --preflight-mode deny' {
        $result = Invoke-CargoWrapper --wrapper-help 6>&1
        $output = $result -join "`n"
        $output | Should -BeLike '*deny*'
    }
}

Describe 'Test-BuildEnvironment' {
    It 'Runs without errors' {
        { Test-BuildEnvironment } | Should -Not -Throw
    }
    It 'Returns detailed object when -Detailed is specified' {
        $result = Test-BuildEnvironment -Detailed
        $result | Should -Not -BeNullOrEmpty
        $result.Results | Should -Not -BeNullOrEmpty
        $result.PSObject.Properties.Name | Should -Contain 'Issues'
        $result.PSObject.Properties.Name | Should -Contain 'Optimizations'
    }
    It 'Includes Rustup in results' {
        $result = Test-BuildEnvironment -Detailed
        $result.Results.Keys | Should -Contain 'Rustup'
    }
    It 'Includes Linker in results' {
        $result = Test-BuildEnvironment -Detailed
        $result.Results.Keys | Should -Contain 'Linker'
    }
    It 'Includes Sccache in results' {
        $result = Test-BuildEnvironment -Detailed
        $result.Results.Keys | Should -Contain 'Sccache'
    }
    It 'Includes BuildJobs in results' {
        $result = Test-BuildEnvironment -Detailed
        $result.Results.Keys | Should -Contain 'BuildJobs'
    }
    It 'Includes CargoConfig in results' {
        $result = Test-BuildEnvironment -Detailed
        $result.Results.Keys | Should -Contain 'CargoConfig'
    }
    It 'Includes RustfmtConfig in results' {
        $result = Test-BuildEnvironment -Detailed
        $result.Results.Keys | Should -Contain 'RustfmtConfig'
    }
}
