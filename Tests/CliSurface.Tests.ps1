#Requires -Modules Pester
<#
.SYNOPSIS
Smoke tests for exported CargoTools command surface.
.DESCRIPTION
Validates that every exported function has command metadata and that wrapper
entrypoints can handle their documented help/version paths without bootstrapping
full builds.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force
}

Describe 'Exported command surface' {
    It 'All exported commands resolve through Get-Command and expose syntax' {
        $module = Get-Module CargoTools
        $module.ExportedFunctions.Keys.Count | Should -BeGreaterThan 0

        foreach ($name in $module.ExportedFunctions.Keys) {
            $command = Get-Command $name -Module CargoTools -ErrorAction Stop
            $command.CommandType | Should -Be 'Function'
            (Get-Command $name -Syntax) | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'CLI wrapper help paths' {
    It 'Invoke-CargoWrapper shows wrapper help' {
        $output = Invoke-CargoWrapper --wrapper-help 6>&1 2>&1
        ($output -join "`n") | Should -Match 'cargo-wrapper.ps1'
    }

    It 'Invoke-CargoRoute shows route help' {
        $output = Invoke-CargoRoute --help 6>&1 2>&1
        ($output -join "`n") | Should -Match 'Usage:'
    }

    It 'Invoke-CargoWsl shows WSL help' {
        $output = Invoke-CargoWsl --help 6>&1 2>&1
        ($output -join "`n") | Should -Match 'cargo-wsl'
    }

    It 'Invoke-CargoDocker shows Docker help' {
        $output = Invoke-CargoDocker --help 6>&1 2>&1
        ($output -join "`n") | Should -Match 'cargo-docker'
    }

    It 'Invoke-CargoMacos shows macOS help' {
        $output = Invoke-CargoMacos --help 6>&1 2>&1
        ($output -join "`n") | Should -Match 'cargo-macos'
    }

    It 'Invoke-RustAnalyzerWrapper shows rust-analyzer help' {
        $output = Invoke-RustAnalyzerWrapper --help 6>&1 2>&1
        ($output -join "`n") | Should -Match 'rust-analyzer-wrapper'
    }
}
