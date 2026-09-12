#Requires -Modules Pester

BeforeAll {
    $script:ModuleRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:ModuleRoot 'CargoTools.psd1') -Force
    $script:CargoModule = Get-Module CargoTools
    # Extract the maintained reader without running the installer deployment.
    $installerAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:ModuleRoot 'tools/Install-Wrappers.ps1'), [ref]$null, [ref]$null)
    $reader = $installerAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'Read-CargoToolsDataFile'
    }, $true)
    . ([scriptblock]::Create($reader.Extent.Text))
}

Describe 'Persisted sccache port scope' {
    BeforeEach {
        Mock netsh -ModuleName CargoTools { '60000 60010' }
        Mock Test-SccachePortAvailable -ModuleName CargoTools { $true }
        $script:PortRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:PortRoot 'sccache') -Force | Out-Null
    }

    It 'retains an explicit desired port when persistence was not requested' {
        Mock Get-SccachePortStateFile -ModuleName CargoTools { throw 'Unrequested machine state access' }
        $actual = & $script:CargoModule { Resolve-FreeSccachePort -DesiredPort '4500' }
        $actual | Should -Be '4500'
        Should -Invoke Get-SccachePortStateFile -ModuleName CargoTools -Times 0 -Exactly
    }

    It 'reuses valid state from the explicitly supplied cache root' {
        Set-Content -LiteralPath (Join-Path $script:PortRoot 'sccache/resolved-port.txt') -Value '4369'
        $actual = & $script:CargoModule { param($root) Resolve-FreeSccachePort -DesiredPort '4500' -CacheRoot $root } $script:PortRoot
        $actual | Should -Be '4369'
    }

    It 'ignores out-of-range persisted ports' {
        Set-Content -LiteralPath (Join-Path $script:PortRoot 'sccache/resolved-port.txt') -Value '70000'
        $actual = & $script:CargoModule { param($root) Resolve-FreeSccachePort -DesiredPort '4500' -CacheRoot $root } $script:PortRoot
        $actual | Should -Be '4500'
        Should -Invoke Test-SccachePortAvailable -ModuleName CargoTools -Times 0 -Exactly -ParameterFilter { $Port -eq 70000 }
    }

    It 'bounds invalid desired ports' {
        $actual = & $script:CargoModule { Resolve-FreeSccachePort -DesiredPort '70000' }
        $actual | Should -Be '4400'
    }

    It 'persists the selected port even when Windows has no excluded ranges' {
        Mock netsh -ModuleName CargoTools { @() }
        $actual = & $script:CargoModule { param($root) Resolve-FreeSccachePort -DesiredPort '4500' -CacheRoot $root } $script:PortRoot
        $actual | Should -Be '4500'
        (Get-Content -LiteralPath (Join-Path $script:PortRoot 'sccache/resolved-port.txt') -Raw).Trim() | Should -Be '4500'
    }
}

Describe 'Active sccache opt-out' {
    BeforeEach {
        $script:SavedEnvironment = @{}
        Get-ChildItem Env: | ForEach-Object { $script:SavedEnvironment[$_.Name] = $_.Value }
        $env:CARGOTOOLS_DISABLE_GLOBAL_RUSTFMT_SYNC = '1'
        $env:CARGO_HOME = Join-Path $TestDrive 'cargo'
        $env:RUSTUP_HOME = Join-Path $TestDrive 'rustup'
        $env:SCCACHE_DISABLE = '1'
        Mock Ensure-MsvcEnv -ModuleName CargoTools {}
        Mock Ensure-Directory -ModuleName CargoTools {}
        Mock Resolve-Sccache -ModuleName CargoTools { 'sccache-fixture.exe' }
        Mock Resolve-CacheRoot -ModuleName CargoTools { $TestDrive }
        Mock Get-MachineConfig -ModuleName CargoTools { @{ CacheRoot = $TestDrive } }
        Mock Resolve-FreeSccachePort -ModuleName CargoTools { throw 'Disabled cache must not be contacted' }
    }
    AfterEach {
        foreach ($item in @(Get-ChildItem Env:)) {
            if (-not $script:SavedEnvironment.ContainsKey($item.Name)) {
                [Environment]::SetEnvironmentVariable($item.Name, $null)
            }
        }
        foreach ($item in $script:SavedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($item.Key, $item.Value)
        }
    }

    It 'does not reinstall the sccache compiler wrapper or probe its server' {
        $env:RUSTC_WRAPPER = 'sccache'
        Initialize-CargoEnv -CacheRoot $TestDrive
        $env:RUSTC_WRAPPER | Should -BeNullOrEmpty
        $env:SCCACHE_DISABLE | Should -Be '1'
        Should -Invoke Resolve-FreeSccachePort -ModuleName CargoTools -Times 0 -Exactly
    }

    It 'preserves an unrelated explicitly configured compiler wrapper' {
        $env:RUSTC_WRAPPER = 'custom-wrapper.exe'
        Initialize-CargoEnv -CacheRoot $TestDrive
        $env:RUSTC_WRAPPER | Should -Be 'custom-wrapper.exe'
    }

    It 'does not start or manage a disabled server even with Force' {
        Mock Resolve-UserScript -ModuleName CargoTools { throw 'Disabled cache manager was invoked' }
        Start-SccacheServer -Force | Should -BeFalse
        Should -Invoke Resolve-UserScript -ModuleName CargoTools -Times 0 -Exactly
        Should -Invoke Resolve-Sccache -ModuleName CargoTools -Times 0 -Exactly
    }
}

Describe 'Installer data fallback' {
    BeforeEach {
        Mock Get-Command { $null } -ParameterFilter { $Name -eq 'Import-PowerShellDataFile' }
        $script:DataPath = Join-Path $TestDrive 'fixture.psd1'
    }

    It 'reads literal manifest data without the optional import command' {
        Set-Content -LiteralPath $script:DataPath -Value "@{ ModuleVersion = '1.2.3'; Nested = @{ Enabled = `$true }; Names = @('a','b') }"
        $actual = Read-CargoToolsDataFile -Path $script:DataPath
        $actual.ModuleVersion | Should -Be '1.2.3'
        $actual.Nested.Enabled | Should -BeTrue
        $actual.Names | Should -Be @('a','b')
    }

    It 'rejects executable expressions without running them' {
        Set-Content -LiteralPath $script:DataPath -Value '@{ Value = (Get-Date) }'
        { Read-CargoToolsDataFile -Path $script:DataPath } | Should -Throw
    }

    It 'rejects environment-variable reads in fallback data' {
        Set-Content -LiteralPath $script:DataPath -Value '@{ Value = $env:USERPROFILE }'
        { Read-CargoToolsDataFile -Path $script:DataPath } | Should -Throw
    }
}

Describe 'Rust analyzer watchdog job contract' {
    BeforeAll {
        $sourceAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:ModuleRoot 'Public/Invoke-RustAnalyzerWrapper.ps1'), [ref]$null, [ref]$null)
        $jobCommand = $sourceAst.Find({ param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Job'
        }, $true)
        $jobBlock = $jobCommand.CommandElements | Where-Object { $_ -is [Management.Automation.Language.ScriptBlockExpressionAst] } | Select-Object -First 1
        $script:WatchdogBody = [scriptblock]::Create($jobBlock.ScriptBlock.Extent.Text.Trim().TrimStart('{').TrimEnd('}'))
    }

    It 'binds the fixture PID in a real job and stops only that process above the limit' {
        $job = Start-Job -ScriptBlock $script:WatchdogBody -ArgumentList 424242, 1MB -InitializationScript {
            [Console]::SetError([IO.StringWriter]::new())
            Set-Item Function:global:Start-Sleep -Value { param($Seconds)
                if ($Seconds -ne 60) { throw 'Wrong polling interval' }
            }
            Set-Item Function:global:Get-Process -Value { param($Id, $ErrorAction)
                if ($ErrorAction -ne 'Stop') { throw 'Wrong lookup error behavior' }
                [pscustomobject]@{ Id = $Id; WorkingSet64 = 2MB }
            }
            Set-Item Function:global:Stop-Process -Value { param($Id, [switch]$Force)
                [pscustomobject]@{ StoppedId = $Id; Forced = $Force.IsPresent }
            }
        }
        try {
            $job | Wait-Job -Timeout 30 | Out-Null
            $job.State | Should -Be 'Completed'
            $result = @(Receive-Job -Job $job -ErrorAction Stop)
            $result.Count | Should -Be 1
            $result[0].StoppedId | Should -Be 424242
            $result[0].Forced | Should -BeTrue
        } finally {
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -Force
        }
    }

    It 'leaves a process below the limit running and exits when it disappears' {
        $job = Start-Job -ScriptBlock $script:WatchdogBody -ArgumentList 424243, 2MB -InitializationScript {
            $script:ProcessQueries = 0
            Set-Item Function:global:Start-Sleep -Value { param($Seconds)
                if ($Seconds -ne 60) { throw 'Wrong polling interval' }
                if ($script:ProcessQueries -eq 1) { 'SECOND_POLL' }
            }
            Set-Item Function:global:Get-Process -Value { param($Id, $ErrorAction)
                if ($ErrorAction -ne 'Stop') { throw 'Wrong lookup error behavior' }
                $script:ProcessQueries++
                if ($Id -ne 424243) { throw 'Wrong process queried' }
                if ($script:ProcessQueries -gt 1) {
                    throw [Microsoft.PowerShell.Commands.ProcessCommandException]::new('Fixture process exited')
                }
                [pscustomobject]@{ Id = $Id; WorkingSet64 = 1MB }
            }
            Set-Item Function:global:Stop-Process -Value { param($Id, [switch]$Force)
                [pscustomobject]@{ UnexpectedStop = $Id; Forced = $Force.IsPresent }
            }
        }
        try {
            $job | Wait-Job -Timeout 30 | Out-Null
            $job.State | Should -Be 'Completed'
            $result = @(Receive-Job -Job $job -ErrorAction Stop)
            $result.Count | Should -Be 1
            $result[0] | Should -Be 'SECOND_POLL'
        } finally {
            $job | Stop-Job -ErrorAction SilentlyContinue
            $job | Remove-Job -Force
        }
    }
}
