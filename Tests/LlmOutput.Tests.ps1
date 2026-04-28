#Requires -Modules Pester
<#
.SYNOPSIS
Tests for LLM output functions: JSON message format injection, cargo JSON parsing,
and build summary formatting.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    $module = Get-Module CargoTools
    $script:GetMessageFormatArgs = & $module { ${function:Get-MessageFormatArgs} }
    $script:ConvertFromCargoJson = & $module { ${function:ConvertFrom-CargoJson} }
    $script:FormatLlmBuildSummary = & $module { ${function:Format-LlmBuildSummary} }
}

Describe 'Get-MessageFormatArgs' {
    It 'Injects --message-format=json for build command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'build' -ArgsList @('build', '--release')
        $result | Should -Contain '--message-format=json'
    }

    It 'Injects for check command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'check' -ArgsList @('check')
        $result | Should -Contain '--message-format=json'
    }

    It 'Injects for clippy command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'clippy' -ArgsList @('clippy')
        $result | Should -Contain '--message-format=json'
    }

    It 'Injects for test command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'test' -ArgsList @('test')
        $result | Should -Contain '--message-format=json'
    }

    It 'Injects for bench command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'bench' -ArgsList @('bench')
        $result | Should -Contain '--message-format=json'
    }

    It 'Does NOT inject for clean command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'clean' -ArgsList @('clean')
        $result | Should -Not -Contain '--message-format=json'
        $result | Should -HaveCount 1
    }

    It 'Does NOT inject for update command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'update' -ArgsList @('update')
        $result | Should -Not -Contain '--message-format=json'
    }

    It 'Does NOT inject for fmt command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'fmt' -ArgsList @('fmt')
        $result | Should -Not -Contain '--message-format=json'
    }

    It 'Does NOT inject for run command' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'run' -ArgsList @('run')
        $result | Should -Not -Contain '--message-format=json'
    }

    It 'Does NOT inject when --message-format already specified' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'build' -ArgsList @('build', '--message-format=short')
        $jsonCount = ($result | Where-Object { $_ -like '--message-format*' }).Count
        $jsonCount | Should -Be 1
        $result | Should -Contain '--message-format=short'
    }

    It 'Does NOT inject when --message-format is a separate arg' {
        $result = & $script:GetMessageFormatArgs -PrimaryCommand 'build' -ArgsList @('build', '--message-format', 'short')
        $result | Should -Not -Contain '--message-format=json'
    }
}

Describe 'ConvertFrom-CargoJson' {
    It 'Parses compiler-message with error' {
        $json = @(
            '{"reason":"compiler-message","message":{"level":"error","message":"mismatched types","code":{"code":"E0308"}}}'
        )
        $result = & $script:ConvertFromCargoJson -JsonLines $json
        $result.error_count | Should -Be 1
        $result.warning_count | Should -Be 0
        $result.diagnostics | Should -HaveCount 1
        $result.diagnostics[0].level | Should -Be 'error'
        $result.diagnostics[0].code | Should -Be 'E0308'
    }

    It 'Parses compiler-message with warning' {
        $json = @(
            '{"reason":"compiler-message","message":{"level":"warning","message":"unused variable","code":null}}'
        )
        $result = & $script:ConvertFromCargoJson -JsonLines $json
        $result.warning_count | Should -Be 1
        $result.error_count | Should -Be 0
    }

    It 'Parses compiler-artifact' {
        $json = @(
            '{"reason":"compiler-artifact","package_id":"my-crate 0.1.0","filenames":["target/debug/my-crate.exe"]}'
        )
        $result = & $script:ConvertFromCargoJson -JsonLines $json
        $result.artifacts | Should -HaveCount 1
        $result.artifacts[0].package | Should -Be 'my-crate'
        $result.artifacts[0].filenames | Should -Contain 'target/debug/my-crate.exe'
    }

    It 'Handles mixed messages' {
        $json = @(
            '{"reason":"compiler-message","message":{"level":"warning","message":"unused import","code":null}}'
            '{"reason":"compiler-message","message":{"level":"error","message":"type mismatch","code":{"code":"E0308"}}}'
            '{"reason":"compiler-artifact","package_id":"foo 0.1.0","filenames":["target/debug/foo.exe"]}'
        )
        $result = & $script:ConvertFromCargoJson -JsonLines $json
        $result.error_count | Should -Be 1
        $result.warning_count | Should -Be 1
        $result.diagnostics | Should -HaveCount 2
        $result.artifacts | Should -HaveCount 1
    }

    It 'Skips non-JSON lines' {
        $json = @(
            'Compiling my-crate v0.1.0'
            '{"reason":"compiler-message","message":{"level":"error","message":"fail","code":null}}'
            '   '
        )
        $result = & $script:ConvertFromCargoJson -JsonLines $json
        $result.error_count | Should -Be 1
    }
}

Describe 'Format-LlmBuildSummary' {
    It 'Produces valid JSON for success' {
        $output = & $script:FormatLlmBuildSummary -ExitCode 0 -Command 'build' -Duration ([TimeSpan]::FromSeconds(5.5)) 6>&1
        $jsonLine = ($output -join "`n") -replace '^CARGO_LLM_STATUS:\s*', ''
        $parsed = $jsonLine | ConvertFrom-Json
        $parsed.status | Should -Be 'success'
        $parsed.exit_code | Should -Be 0
        $parsed.command | Should -Be 'build'
        $parsed.duration_s | Should -BeGreaterOrEqual 5
    }

    It 'Produces valid JSON for failure' {
        $output = & $script:FormatLlmBuildSummary -ExitCode 101 -Command 'check' 6>&1
        $jsonLine = ($output -join "`n") -replace '^CARGO_LLM_STATUS:\s*', ''
        $parsed = $jsonLine | ConvertFrom-Json
        $parsed.status | Should -Be 'failure'
        $parsed.exit_code | Should -Be 101
    }
}
