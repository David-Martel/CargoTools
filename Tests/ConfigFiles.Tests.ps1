#Requires -Modules Pester
<#
.SYNOPSIS
Tests for TOML config infrastructure and Initialize-RustDefaults.
.DESCRIPTION
Tests Read-TomlSections, ConvertTo-TomlString, Merge-TomlConfig, Write-ConfigFile,
default config generators, and the Initialize-RustDefaults public function.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    $module = Get-Module CargoTools
    $script:ReadToml = & $module { ${function:Read-TomlSections} }
    $script:ToToml = & $module { ${function:ConvertTo-TomlString} }
    $script:MergeToml = & $module { ${function:Merge-TomlConfig} }
    $script:WriteConfig = & $module { ${function:Write-ConfigFile} }
    $script:GetDefaultCargo = & $module { ${function:Get-DefaultCargoConfig} }
    $script:GetDefaultRustfmt = & $module { ${function:Get-DefaultRustfmtConfig} }
    $script:GetDefaultClippy = & $module { ${function:Get-DefaultClippyConfig} }
    $script:GetDefaultRA = & $module { ${function:Get-DefaultRustAnalyzerConfig} }
    $script:FormatTomlValue = & $module { ${function:Format-TomlValue} }
    $script:ConvertFromTomlValue = & $module { ${function:ConvertFrom-TomlValue} }
    $script:NormalizeCargoEnvTables = & $module { ${function:Normalize-CargoConfigEnvTables} }
    $script:NormalizeCargoUnsupportedKeys = & $module { ${function:Normalize-CargoConfigUnsupportedKeys} }

    $script:TestDir = Join-Path $TestDrive 'ConfigTests'
    New-Item -ItemType Directory -Path $script:TestDir -Force | Out-Null
}

Describe 'ConvertFrom-TomlValue' {
    It 'Parses double-quoted strings' {
        & $script:ConvertFromTomlValue '"hello world"' | Should -Be 'hello world'
    }
    It 'Parses single-quoted strings' {
        & $script:ConvertFromTomlValue "'literal'" | Should -Be 'literal'
    }
    It 'Parses booleans' {
        & $script:ConvertFromTomlValue 'true' | Should -Be $true
        & $script:ConvertFromTomlValue 'false' | Should -Be $false
    }
    It 'Parses integers' {
        & $script:ConvertFromTomlValue '42' | Should -Be 42
    }
    It 'Strips inline comments from unquoted values' {
        & $script:ConvertFromTomlValue '42 # the answer' | Should -Be 42
    }
    It 'Preserves quoted strings with hash characters' {
        & $script:ConvertFromTomlValue '"has # inside"' | Should -Be 'has # inside'
    }
}

Describe 'Format-TomlValue' {
    It 'Formats booleans' {
        & $script:FormatTomlValue $true | Should -Be 'true'
        & $script:FormatTomlValue $false | Should -Be 'false'
    }
    It 'Formats integers' {
        & $script:FormatTomlValue 42 | Should -Be '42'
    }
    It 'Formats strings with double quotes' {
        & $script:FormatTomlValue 'hello' | Should -Be '"hello"'
    }
    It 'Escapes backslashes in paths' {
        $result = & $script:FormatTomlValue 'C:\Program Files\LLVM\bin\lld-link.exe'
        $result | Should -Be '"C:\\Program Files\\LLVM\\bin\\lld-link.exe"'
    }
}

Describe 'Read-TomlSections' {
    It 'Returns empty hashtable for non-existent file' {
        $result = & $script:ReadToml -Path (Join-Path $script:TestDir 'nonexistent.toml')
        $result.Count | Should -Be 0
    }

    It 'Parses simple sections' {
        $tomlPath = Join-Path $script:TestDir 'simple.toml'
        Set-Content -Path $tomlPath -Value @'
[build]
jobs = 4

[term]
color = "auto"
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['build']['jobs'] | Should -Be 4
        $result['term']['color'] | Should -Be 'auto'
    }

    It 'Parses dotted section names' {
        $tomlPath = Join-Path $script:TestDir 'dotted.toml'
        Set-Content -Path $tomlPath -Value @'
[registries.crates-io]
protocol = "sparse"

[target.x86_64-pc-windows-msvc]
linker = "lld-link"
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['registries.crates-io']['protocol'] | Should -Be 'sparse'
        $result['target.x86_64-pc-windows-msvc']['linker'] | Should -Be 'lld-link'
    }

    It 'Skips comments' {
        $tomlPath = Join-Path $script:TestDir 'comments.toml'
        Set-Content -Path $tomlPath -Value @'
# This is a comment
[build]
# Another comment
jobs = 4
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['build']['jobs'] | Should -Be 4
        $result['build'].Count | Should -Be 1
    }

    It 'Handles quoted strings with equals signs' {
        $tomlPath = Join-Path $script:TestDir 'equals.toml'
        Set-Content -Path $tomlPath -Value @'
[env]
key = "value=with=equals"
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['env']['key'] | Should -Be 'value=with=equals'
    }

    It 'Handles Windows backslash paths' {
        $tomlPath = Join-Path $script:TestDir 'paths.toml'
        Set-Content -Path $tomlPath -Value @'
[target.x86_64-pc-windows-msvc]
linker = "C:\\Program Files\\LLVM\\bin\\lld-link.exe"
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['target.x86_64-pc-windows-msvc']['linker'] | Should -Be 'C:\Program Files\LLVM\bin\lld-link.exe'
    }

    It 'Handles empty values' {
        $tomlPath = Join-Path $script:TestDir 'empty.toml'
        Set-Content -Path $tomlPath -Value @'
[section]
key = ""
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['section']['key'] | Should -Be ''
    }

    It 'Handles boolean values' {
        $tomlPath = Join-Path $script:TestDir 'bools.toml'
        Set-Content -Path $tomlPath -Value @'
[procMacro]
enable = true
debug = false
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['procMacro']['enable'] | Should -Be $true
        $result['procMacro']['debug'] | Should -Be $false
    }

    It 'Handles top-level keys before any section' {
        $tomlPath = Join-Path $script:TestDir 'toplevel.toml'
        Set-Content -Path $tomlPath -Value @'
edition = "2021"
max_width = 100

[section]
key = "value"
'@
        $result = & $script:ReadToml -Path $tomlPath
        $result['']['edition'] | Should -Be '2021'
        $result['']['max_width'] | Should -Be 100
        $result['section']['key'] | Should -Be 'value'
    }
}

Describe 'ConvertTo-TomlString' {
    It 'Serializes simple sections' {
        $data = [ordered]@{
            'build' = [ordered]@{
                jobs = 4
            }
            'term' = [ordered]@{
                color = 'auto'
            }
        }
        $result = & $script:ToToml -Data $data
        $result | Should -Match '\[build\]'
        $result | Should -Match 'jobs = 4'
        $result | Should -Match '\[term\]'
        $result | Should -Match 'color = "auto"'
    }

    It 'Serializes dotted section names' {
        $data = [ordered]@{
            'registries.crates-io' = [ordered]@{
                protocol = 'sparse'
            }
        }
        $result = & $script:ToToml -Data $data
        $result | Should -Match '\[registries\.crates-io\]'
        $result | Should -Match 'protocol = "sparse"'
    }

    It 'Includes header comment' {
        $data = [ordered]@{
            'build' = [ordered]@{ jobs = 4 }
        }
        $result = & $script:ToToml -Data $data -Header 'Generated by CargoTools'
        $result | Should -Match '# Generated by CargoTools'
    }

    It 'Serializes top-level keys' {
        $data = [ordered]@{
            '' = [ordered]@{
                edition = '2021'
                max_width = 100
            }
        }
        $result = & $script:ToToml -Data $data
        $result | Should -Match 'edition = "2021"'
        $result | Should -Match 'max_width = 100'
        # Should NOT have a section header for top-level
        $result | Should -Not -Match '^\[\]'
    }
}

Describe 'Round-trip: ConvertTo-TomlString -> Read-TomlSections' {
    It 'Produces identical data after round-trip' {
        $original = [ordered]@{
            'registries.crates-io' = [ordered]@{
                protocol = 'sparse'
            }
            'build' = [ordered]@{
                jobs = 4
                'rustc-wrapper' = 'sccache'
            }
            'term' = [ordered]@{
                color = 'auto'
            }
        }
        $toml = & $script:ToToml -Data $original
        $tomlPath = Join-Path $script:TestDir 'roundtrip.toml'
        Set-Content -Path $tomlPath -Value $toml -NoNewline

        $parsed = & $script:ReadToml -Path $tomlPath

        $parsed['registries.crates-io']['protocol'] | Should -Be 'sparse'
        $parsed['build']['jobs'] | Should -Be 4
        $parsed['build']['rustc-wrapper'] | Should -Be 'sccache'
        $parsed['term']['color'] | Should -Be 'auto'
    }
}

Describe 'Merge-TomlConfig' {
    It 'Adds missing keys from defaults' {
        $existing = [ordered]@{
            'build' = [ordered]@{
                jobs = 8
            }
        }
        $defaults = [ordered]@{
            'build' = [ordered]@{
                jobs = 4
                'rustc-wrapper' = 'sccache'
            }
            'term' = [ordered]@{
                color = 'auto'
            }
        }
        $result = & $script:MergeToml -Existing $existing -Defaults $defaults
        # Existing value preserved
        $result.Config['build']['jobs'] | Should -Be 8
        # New key added
        $result.Config['build']['rustc-wrapper'] | Should -Be 'sccache'
        # New section added
        $result.Config['term']['color'] | Should -Be 'auto'
    }

    It 'Preserves existing values by default' {
        $existing = [ordered]@{
            'build' = [ordered]@{
                jobs = 8
            }
        }
        $defaults = [ordered]@{
            'build' = [ordered]@{
                jobs = 4
            }
        }
        $result = & $script:MergeToml -Existing $existing -Defaults $defaults
        $result.Config['build']['jobs'] | Should -Be 8
    }

    It 'Overwrites with -Force' {
        $existing = [ordered]@{
            'build' = [ordered]@{
                jobs = 8
            }
        }
        $defaults = [ordered]@{
            'build' = [ordered]@{
                jobs = 4
            }
        }
        $result = & $script:MergeToml -Existing $existing -Defaults $defaults -Force
        $result.Config['build']['jobs'] | Should -Be 4
    }

    It 'Reports additions' {
        $existing = [ordered]@{
            'build' = [ordered]@{
                jobs = 8
            }
        }
        $defaults = [ordered]@{
            'build' = [ordered]@{
                'rustc-wrapper' = 'sccache'
            }
            'term' = [ordered]@{
                color = 'auto'
            }
        }
        $result = & $script:MergeToml -Existing $existing -Defaults $defaults
        $result.Additions | Should -Not -BeNullOrEmpty
        ($result.Additions -join ' ') | Should -Match 'rustc-wrapper'
        ($result.Additions -join ' ') | Should -Match '\[term\]'
    }

    It 'Creates new sections from defaults' {
        $existing = [ordered]@{}
        $defaults = [ordered]@{
            'build' = [ordered]@{
                jobs = 4
            }
        }
        $result = & $script:MergeToml -Existing $existing -Defaults $defaults
        $result.Config['build']['jobs'] | Should -Be 4
    }
}

Describe 'Write-ConfigFile' {
    It 'Creates backup before overwriting' {
        $filePath = Join-Path $script:TestDir 'backup-test.toml'
        Set-Content -Path $filePath -Value 'original content'

        & $script:WriteConfig -Path $filePath -Content 'new content'

        Test-Path "$filePath.bak" | Should -Be $true
        Get-Content "$filePath.bak" -Raw | Should -Match 'original content'
        Get-Content $filePath -Raw | Should -Match 'new content'
    }

    It 'Creates parent directory if needed' {
        $filePath = Join-Path $script:TestDir 'subdir\deep\config.toml'
        & $script:WriteConfig -Path $filePath -Content 'test content'

        Test-Path $filePath | Should -Be $true
        Get-Content $filePath -Raw | Should -Match 'test content'
    }

    It 'Skips backup with -NoBackup' {
        $filePath = Join-Path $script:TestDir 'nobackup-test.toml'
        Set-Content -Path $filePath -Value 'original'

        & $script:WriteConfig -Path $filePath -Content 'updated' -NoBackup

        Test-Path "$filePath.bak" | Should -Be $false
        Get-Content $filePath -Raw | Should -Match 'updated'
    }

    It 'Supports -WhatIf' {
        $filePath = Join-Path $script:TestDir 'whatif-test.toml'
        Set-Content -Path $filePath -Value 'should not change'

        & $script:WriteConfig -Path $filePath -Content 'new value' -WhatIf

        Get-Content $filePath -Raw | Should -Match 'should not change'
    }
}

Describe 'Get-DefaultCargoConfig' {
    It 'Returns expected sections' {
        $config = & $script:GetDefaultCargo
        $config.Keys | Should -Contain 'registries.crates-io'
        $config.Keys | Should -Contain 'build'
        $config.Keys | Should -Contain 'target.x86_64-pc-windows-msvc'
        $config.Keys | Should -Contain 'env'
        $config.Keys | Should -Contain 'term'
    }
    It 'Has sparse registry protocol' {
        $config = & $script:GetDefaultCargo
        $config['registries.crates-io']['protocol'] | Should -Be 'sparse'
    }
    It 'Has sccache as rustc-wrapper' {
        $config = & $script:GetDefaultCargo
        $config['build']['rustc-wrapper'] | Should -Be 'sccache'
    }
    It 'Has lld-link as linker' {
        $config = & $script:GetDefaultCargo
        $config['target.x86_64-pc-windows-msvc']['linker'] | Should -Match 'lld-link(\.exe)?$'
    }
    It 'Writes managed Cargo env values as inline tables' {
        $config = & $script:GetDefaultCargo
        $config['env']['SCCACHE_REQUEST_TIMEOUT'] | Should -Match '^\{ value = "180", force = true \}$'
        $config['env']['CARGO_INCREMENTAL'] | Should -Match '^\{ value = "0", force = true \}$'
    }
    It 'Normalizes legacy scalar Cargo env values to inline tables' {
        $existing = [ordered]@{
            env = [ordered]@{
                SCCACHE_REQUEST_TIMEOUT = '180'
                CARGO_INCREMENTAL = '0'
            }
        }

        $normalized = & $script:NormalizeCargoEnvTables -Config $existing
        $normalized.Config['env']['SCCACHE_REQUEST_TIMEOUT'] | Should -Be '{ value = "180", force = true }'
        $normalized.Config['env']['CARGO_INCREMENTAL'] | Should -Be '{ value = "0", force = true }'
        $normalized.Changes.Count | Should -Be 2
    }
    It 'Removes unsupported cargo-new.edition key' {
        $existing = [ordered]@{
            'cargo-new' = [ordered]@{
                vcs = 'git'
                edition = '2024'
            }
        }

        $normalized = & $script:NormalizeCargoUnsupportedKeys -Config $existing
        $normalized.Config['cargo-new'].Contains('vcs') | Should -BeTrue
        $normalized.Config['cargo-new'].Contains('edition') | Should -BeFalse
        $normalized.Changes | Should -Contain 'Removed unsupported cargo-new.edition key'
    }
    It 'Removes alias.fix because Cargo has a built-in fix command' {
        $existing = [ordered]@{
            alias = [ordered]@{
                fix = 'fmt --all'
                c = 'check'
            }
        }

        $normalized = & $script:NormalizeCargoUnsupportedKeys -Config $existing
        $normalized.Config['alias'].Contains('c') | Should -BeTrue
        $normalized.Config['alias'].Contains('fix') | Should -BeFalse
        $normalized.Changes | Should -Contain 'Removed alias.fix because it is shadowed by Cargo built-in command'
    }
}

Describe 'Get-DefaultRustfmtConfig' {
    It 'Returns edition and max_width' {
        $config = & $script:GetDefaultRustfmt
        $config['']['edition'] | Should -Be '2021'
        $config['']['max_width'] | Should -Be 100
    }
    It 'Has reorder_imports enabled' {
        $config = & $script:GetDefaultRustfmt
        $config['']['reorder_imports'] | Should -Be $true
    }
}

Describe 'Get-DefaultClippyConfig' {
    It 'Returns msrv and thresholds' {
        $config = & $script:GetDefaultClippy
        $config['']['msrv'] | Should -Be '1.75.0'
        $config['']['too-many-arguments-threshold'] | Should -Be 8
        $config['']['type-complexity-threshold'] | Should -Be 500
    }
}

Describe 'Initialize-RustDefaults' {
    BeforeAll {
        $script:FakeHome = Join-Path $TestDrive 'FakeHome'
        $script:FakeCargo = Join-Path $script:FakeHome '.cargo'
        New-Item -ItemType Directory -Path $script:FakeCargo -Force | Out-Null
        # Save original env vars
        $script:SavedCargoHome = $env:CARGO_HOME
        $script:SavedHomeDrive = $env:HOMEDRIVE
        $script:SavedHomePath = $env:HOMEPATH
        $script:SavedUserProfile = $env:USERPROFILE
    }

    BeforeEach {
        # Clean up test files
        Remove-Item (Join-Path $script:FakeCargo 'config.toml') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:FakeCargo 'config.toml.bak') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:FakeHome 'rustfmt.toml') -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $script:FakeHome '.clippy.toml') -ErrorAction SilentlyContinue
        # Redirect HOME via CARGO_HOME (for cargo config) — Initialize-RustDefaults
        # uses $HOME for rustfmt/clippy paths and $CARGO_HOME for cargo config
        $env:CARGO_HOME = $script:FakeCargo
    }

    AfterAll {
        if ($script:SavedCargoHome) { $env:CARGO_HOME = $script:SavedCargoHome }
        else { Remove-Item Env:CARGO_HOME -ErrorAction SilentlyContinue }
    }

    It 'Creates cargo config when missing' {
        Initialize-RustDefaults -Scope Cargo
        Test-Path (Join-Path $script:FakeCargo 'config.toml') | Should -Be $true
    }

    It 'Creates rustfmt.toml in HOME' {
        # Initialize-RustDefaults uses $HOME for rustfmt/clippy
        # Since $HOME is read-only in PS Core, test via the real HOME path
        $expectedPath = Join-Path $HOME 'rustfmt.toml'
        $hadExisting = Test-Path $expectedPath
        $savedContent = if ($hadExisting) { Get-Content $expectedPath -Raw } else { $null }
        try {
            Initialize-RustDefaults -Scope Rustfmt
            Test-Path $expectedPath | Should -Be $true
        } finally {
            if ($hadExisting -and $savedContent) {
                Set-Content -Path $expectedPath -Value $savedContent -NoNewline
            } elseif (-not $hadExisting) {
                Remove-Item $expectedPath -ErrorAction SilentlyContinue
            }
        }
    }

    It 'Creates clippy.toml in HOME' {
        $expectedPath = Join-Path $HOME '.clippy.toml'
        $hadExisting = Test-Path $expectedPath
        $savedContent = if ($hadExisting) { Get-Content $expectedPath -Raw } else { $null }
        try {
            Initialize-RustDefaults -Scope Clippy
            Test-Path $expectedPath | Should -Be $true
        } finally {
            if ($hadExisting -and $savedContent) {
                Set-Content -Path $expectedPath -Value $savedContent -NoNewline
            } elseif (-not $hadExisting) {
                Remove-Item $expectedPath -ErrorAction SilentlyContinue
            }
        }
    }

    It 'Preserves existing values on merge' {
        $configPath = Join-Path $script:FakeCargo 'config.toml'
        Set-Content -Path $configPath -Value @'
[build]
jobs = 16
'@
        Initialize-RustDefaults -Scope Cargo
        $content = Get-Content $configPath -Raw
        # Should preserve jobs = 16, not overwrite with 4
        $content | Should -Match 'jobs = 16'
    }

    It 'Overwrites values with -Force' {
        $configPath = Join-Path $script:FakeCargo 'config.toml'
        Set-Content -Path $configPath -Value @'
[build]
jobs = 16
'@
        Initialize-RustDefaults -Scope Cargo -Force
        $content = Get-Content $configPath -Raw
        $content | Should -Match 'jobs = 4'
    }

    It 'Returns objects with -PassThru' {
        $result = Initialize-RustDefaults -Scope Cargo -PassThru
        $result | Should -Not -BeNull
        $result.PSObject.Properties.Name | Should -Contain 'CargoConfig'
    }

    It 'Supports -WhatIf without writing files' {
        $configPath = Join-Path $script:FakeCargo 'config.toml'
        Remove-Item $configPath -ErrorAction SilentlyContinue
        Initialize-RustDefaults -Scope Cargo -WhatIf
        # File should NOT have been created
        Test-Path $configPath | Should -Be $false
    }

    It 'Creates backup of existing config' {
        $configPath = Join-Path $script:FakeCargo 'config.toml'
        Set-Content -Path $configPath -Value '[build]'
        Initialize-RustDefaults -Scope Cargo
        Test-Path "$configPath.bak" | Should -Be $true
    }

    It 'Cargo config contains sparse registry protocol' {
        Initialize-RustDefaults -Scope Cargo
        $content = Get-Content (Join-Path $script:FakeCargo 'config.toml') -Raw
        $content | Should -Match 'protocol = "sparse"'
    }
}

Describe 'Get-DefaultRustAnalyzerConfig' {
    It 'Returns check command as clippy' {
        $config = & $script:GetDefaultRA
        $config['check']['command'] | Should -Be 'clippy'
    }
    It 'Has procMacro enabled' {
        $config = & $script:GetDefaultRA
        $config['procMacro']['enable'] | Should -Be $true
    }
    It 'Has cachePriming numThreads' {
        $config = & $script:GetDefaultRA
        $config['cachePriming']['numThreads'] | Should -Be 1
    }
}
