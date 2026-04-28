#Requires -Modules Pester
<#
.SYNOPSIS
Pester tests for Common.ps1 utility functions.
.DESCRIPTION
Unit tests for Convert-ArgsToShell, Strip-ArgsAfterDoubleDash, Normalize-ArgsList,
Get-PrimaryCommand, Classify-Target, Test-Truthy, and argument validation helpers.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    # Access private functions via module scope
    $module = Get-Module CargoTools
    $script:ConvertArgsToShell = & $module { ${function:Convert-ArgsToShell} }
    $script:StripArgsAfterDoubleDash = & $module { ${function:Strip-ArgsAfterDoubleDash} }
    $script:NormalizeArgsList = & $module { ${function:Normalize-ArgsList} }
    $script:GetPrimaryCommand = & $module { ${function:Get-PrimaryCommand} }
    $script:ClassifyTarget = & $module { ${function:Classify-Target} }
    $script:TestTruthy = & $module { ${function:Test-Truthy} }
    $script:AssertAllowedValue = & $module { ${function:Assert-AllowedValue} }
    $script:AssertNotBoth = & $module { ${function:Assert-NotBoth} }
    $script:EnsureRunArgSeparator = & $module { ${function:Ensure-RunArgSeparator} }
    $script:GetTargetFromArgs = & $module { ${function:Get-TargetFromArgs} }
    $script:EnsureMessageFormatShort = & $module { ${function:Ensure-MessageFormatShort} }
}

Describe 'Test-Truthy' {
    It 'Returns $true for "1"' {
        & $script:TestTruthy '1' | Should -Be $true
    }
    It 'Returns $true for "true"' {
        & $script:TestTruthy 'true' | Should -Be $true
    }
    It 'Returns $true for "yes"' {
        & $script:TestTruthy 'yes' | Should -Be $true
    }
    It 'Returns $true for "on"' {
        & $script:TestTruthy 'on' | Should -Be $true
    }
    It 'Returns $false for "0"' {
        & $script:TestTruthy '0' | Should -Be $false
    }
    It 'Returns $false for "false"' {
        & $script:TestTruthy 'false' | Should -Be $false
    }
    It 'Returns $false for "no"' {
        & $script:TestTruthy 'no' | Should -Be $false
    }
    It 'Returns $false for "off"' {
        & $script:TestTruthy 'off' | Should -Be $false
    }
    It 'Returns $false for empty string' {
        & $script:TestTruthy '' | Should -Be $false
    }
    It 'Returns $false for whitespace' {
        & $script:TestTruthy '   ' | Should -Be $false
    }
    It 'Returns $false for $null' {
        & $script:TestTruthy $null | Should -Be $false
    }
    It 'Is case insensitive' {
        & $script:TestTruthy 'FALSE' | Should -Be $false
        & $script:TestTruthy 'True' | Should -Be $true
    }
}

Describe 'Normalize-ArgsList' {
    It 'Returns empty array for $null' {
        $result = & $script:NormalizeArgsList $null
        $result | Should -HaveCount 0
    }
    It 'Returns array unchanged' {
        $result = & $script:NormalizeArgsList @('a', 'b', 'c')
        $result | Should -HaveCount 3
        $result[0] | Should -Be 'a'
    }
    It 'Wraps single value in array' {
        $result = & $script:NormalizeArgsList 'single'
        $result | Should -HaveCount 1
        $result[0] | Should -Be 'single'
    }
}

Describe 'Convert-ArgsToShell' {
    Context 'Simple arguments (no quoting needed)' {
        It 'Passes simple args unchanged' {
            $result = & $script:ConvertArgsToShell @('build', '--release')
            $result | Should -Be 'build --release'
        }
        It 'Handles paths with slashes' {
            $result = & $script:ConvertArgsToShell @('--target-dir=/tmp/build')
            $result | Should -Be '--target-dir=/tmp/build'
        }
        It 'Handles feature flags with commas' {
            $result = & $script:ConvertArgsToShell @('--features=foo,bar')
            $result | Should -Be '--features=foo,bar'
        }
        It 'Handles version specs with @' {
            $result = & $script:ConvertArgsToShell @('cargo-nextest@0.9')
            $result | Should -Be 'cargo-nextest@0.9'
        }
    }

    Context 'Arguments requiring quoting' {
        It 'Quotes arguments with spaces' {
            $result = & $script:ConvertArgsToShell @('hello world')
            $result | Should -Be "'hello world'"
        }
        It 'Quotes arguments with dollar signs' {
            $result = & $script:ConvertArgsToShell @('$HOME/project')
            $expected = "'" + '$HOME/project' + "'"
            $result | Should -Be $expected
        }
        It 'Quotes arguments with backticks' {
            $result = & $script:ConvertArgsToShell @('foo`bar')
            $result | Should -Be "'foo``bar'"
        }
        It 'Quotes arguments with parentheses' {
            $result = & $script:ConvertArgsToShell @('(test)')
            $result | Should -Be "'(test)'"
        }
        It 'Quotes arguments with ampersand' {
            $result = & $script:ConvertArgsToShell @('foo&bar')
            $result | Should -Be "'foo&bar'"
        }
        It 'Quotes arguments with pipe' {
            $result = & $script:ConvertArgsToShell @('foo|bar')
            $result | Should -Be "'foo|bar'"
        }
        It 'Quotes arguments with semicolons' {
            $result = & $script:ConvertArgsToShell @('foo;bar')
            $result | Should -Be "'foo;bar'"
        }
        It 'Quotes arguments with angle brackets' {
            $result = & $script:ConvertArgsToShell @('a<b>c')
            $result | Should -Be "'a<b>c'"
        }
        It 'Quotes arguments with wildcards' {
            $result = & $script:ConvertArgsToShell @('*.rs')
            $result | Should -Be "'*.rs'"
        }
        It 'Quotes arguments with tilde' {
            $result = & $script:ConvertArgsToShell @('~/project')
            $result | Should -Be "'~/project'"
        }
        It 'Handles single quotes inside arguments' {
            $result = & $script:ConvertArgsToShell @("it's")
            # Should produce: 'it'"'"'s'
            $result | Should -BeLike "*it*s*"
            $result | Should -Not -Be "it's"
        }
    }

    Context 'Edge cases' {
        It 'Returns empty string for empty array' {
            $result = & $script:ConvertArgsToShell @()
            $result | Should -Be ''
        }
        It 'Handles double-dash separator' {
            $result = & $script:ConvertArgsToShell @('build', '--', '--my-flag')
            $result | Should -Be 'build -- --my-flag'
        }
        It 'Handles mixed safe and unsafe args' {
            $result = & $script:ConvertArgsToShell @('build', '--release', 'path with space')
            $result | Should -Be "build --release 'path with space'"
        }
    }
}

Describe 'Strip-ArgsAfterDoubleDash' {
    It 'Returns full list when no double-dash' {
        $result = & $script:StripArgsAfterDoubleDash @('build', '--release')
        $result | Should -HaveCount 2
        $result[0] | Should -Be 'build'
    }
    It 'Strips args after double-dash' {
        $result = & $script:StripArgsAfterDoubleDash @('run', '--release', '--', '--my-flag')
        $result | Should -HaveCount 2
        $result[0] | Should -Be 'run'
        $result[1] | Should -Be '--release'
    }
    It 'Returns empty array when double-dash is first' {
        $result = & $script:StripArgsAfterDoubleDash @('--', 'something')
        $result | Should -HaveCount 0
    }
    It 'Handles empty input' {
        $result = & $script:StripArgsAfterDoubleDash @()
        $result | Should -HaveCount 0
    }
    It 'Handles $null input' {
        $result = & $script:StripArgsAfterDoubleDash $null
        $result | Should -HaveCount 0
    }
}

Describe 'Get-PrimaryCommand' {
    It 'Finds build command' {
        $result = & $script:GetPrimaryCommand @('build', '--release')
        $result | Should -Be 'build'
    }
    It 'Skips flags to find command' {
        $result = & $script:GetPrimaryCommand @('--release', 'build')
        $result | Should -Be 'build'
    }
    It 'Skips toolchain override' {
        $result = & $script:GetPrimaryCommand @('+nightly', 'build')
        $result | Should -Be 'build'
    }
    It 'Returns $null when no command' {
        $result = & $script:GetPrimaryCommand @('--release', '--verbose')
        $result | Should -BeNullOrEmpty
    }
    It 'Returns $null for empty input' {
        $result = & $script:GetPrimaryCommand @()
        $result | Should -BeNullOrEmpty
    }
}

Describe 'Classify-Target' {
    It 'Classifies Windows target' {
        & $script:ClassifyTarget 'x86_64-pc-windows-msvc' | Should -Be 'windows'
    }
    It 'Classifies Linux GNU target' {
        & $script:ClassifyTarget 'x86_64-unknown-linux-gnu' | Should -Be 'linux'
    }
    It 'Classifies Linux musl target' {
        & $script:ClassifyTarget 'x86_64-unknown-linux-musl' | Should -Be 'linux'
    }
    It 'Classifies WASM target' {
        & $script:ClassifyTarget 'wasm32-unknown-unknown' | Should -Be 'wasm'
    }
    It 'Classifies Apple target' {
        & $script:ClassifyTarget 'aarch64-apple-darwin' | Should -Be 'apple'
    }
    It 'Returns unknown for empty string' {
        & $script:ClassifyTarget '' | Should -Be 'unknown'
    }
    It 'Returns unknown for $null' {
        & $script:ClassifyTarget $null | Should -Be 'unknown'
    }
    It 'Returns other for unrecognized target' {
        & $script:ClassifyTarget 'riscv64gc-unknown-none-elf' | Should -Be 'other'
    }
}

Describe 'GetTargetFromArgs' {
    It 'Extracts --target with space separator' {
        $result = & $script:GetTargetFromArgs @('build', '--target', 'x86_64-pc-windows-msvc')
        $result | Should -Be 'x86_64-pc-windows-msvc'
    }
    It 'Extracts --target= form' {
        $result = & $script:GetTargetFromArgs @('build', '--target=wasm32-unknown-unknown')
        $result | Should -Be 'wasm32-unknown-unknown'
    }
    It 'Returns $null when no target' {
        $result = & $script:GetTargetFromArgs @('build', '--release')
        if (-not $env:CARGO_BUILD_TARGET) {
            $result | Should -BeNullOrEmpty
        }
    }
}

Describe 'Ensure-RunArgSeparator' {
    It 'Inserts -- before positional args in cargo run' {
        $result = & $script:EnsureRunArgSeparator @('run', 'myarg')
        $result | Should -Contain '--'
    }
    It 'Does not modify non-run commands' {
        $result = & $script:EnsureRunArgSeparator @('build', '--release')
        $result | Should -Not -Contain '--'
        $result | Should -HaveCount 2
    }
    It 'Does not add -- if already present' {
        $result = & $script:EnsureRunArgSeparator @('run', '--', 'myarg')
        # Count number of -- entries
        $dashes = $result | Where-Object { $_ -eq '--' }
        $dashes | Should -HaveCount 1
    }
    It 'Handles empty input' {
        $result = & $script:EnsureRunArgSeparator @()
        $result | Should -HaveCount 0
    }
    It 'Preserves --release before --' {
        $result = & $script:EnsureRunArgSeparator @('run', '--release', 'myarg')
        $releaseIdx = [Array]::IndexOf($result, '--release')
        $dashIdx = [Array]::IndexOf($result, '--')
        $releaseIdx | Should -BeLessThan $dashIdx
    }
}

Describe 'Assert-AllowedValue' {
    It 'Returns $true for allowed value' {
        & $script:AssertAllowedValue -Name 'mode' -Value 'native' -Allowed @('native', 'shared') | Should -Be $true
    }
    It 'Returns $false for disallowed value' {
        & $script:AssertAllowedValue -Name 'mode' -Value 'invalid' -Allowed @('native', 'shared') 2>$null | Should -Be $false
    }
    It 'Returns $true for empty/null value' {
        & $script:AssertAllowedValue -Name 'mode' -Value '' -Allowed @('native', 'shared') | Should -Be $true
        & $script:AssertAllowedValue -Name 'mode' -Value $null -Allowed @('native', 'shared') | Should -Be $true
    }
}

Describe 'Assert-NotBoth' {
    It 'Returns $true when neither set' {
        & $script:AssertNotBoth -Name 'test' -A $false -B $false | Should -Be $true
    }
    It 'Returns $true when only A set' {
        & $script:AssertNotBoth -Name 'test' -A $true -B $false | Should -Be $true
    }
    It 'Returns $true when only B set' {
        & $script:AssertNotBoth -Name 'test' -A $false -B $true | Should -Be $true
    }
    It 'Returns $false when both set' {
        & $script:AssertNotBoth -Name 'test' -A $true -B $true 2>$null | Should -Be $false
    }
}

Describe 'Ensure-MessageFormatShort' {
    It 'Adds --message-format=short when not present' {
        $result = & $script:EnsureMessageFormatShort @('check')
        $result | Should -Contain '--message-format=short'
    }
    It 'Does not add when --message-format already present' {
        $result = & $script:EnsureMessageFormatShort @('check', '--message-format=json')
        $shortCount = ($result | Where-Object { $_ -eq '--message-format=short' }).Count
        $shortCount | Should -Be 0
    }
}
