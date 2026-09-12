#Requires -Modules Pester
# All lifecycle calls use mocked external boundaries. Only the listener tests
# bind real sockets, on ephemeral ports owned and closed by this test process.
BeforeAll {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1') -Force
    $module = Get-Module CargoTools
    $script:Health = & $module { ${function:Test-SccacheHealth} }
    $script:Control = & $module { ${function:Invoke-SccacheControl} }
    $script:Port = & $module { ${function:Get-SccacheServerPort} }
}

Describe 'Selected sccache endpoint lifecycle' {
    BeforeEach {
        $script:SavedPort = $env:SCCACHE_SERVER_PORT
        $script:SavedDisable = $env:SCCACHE_DISABLE
        $env:SCCACHE_SERVER_PORT = '43123'
        $env:SCCACHE_DISABLE = '0'
        Mock Get-Process -ModuleName CargoTools {
            [pscustomobject]@{ Id = 101; WorkingSet64 = 8GB }
            [pscustomobject]@{ Id = 202; WorkingSet64 = 8GB }
        } -ParameterFilter { $Name -eq 'sccache' }
        Mock Stop-Process -ModuleName CargoTools { throw 'Shared process kill attempted' }
        Mock Resolve-UserScript -ModuleName CargoTools { throw 'External manager invoked' }
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { if ($Port -ne 43123) { throw 'Unexpected endpoint' }; $true }
        Mock Invoke-SccacheControl -ModuleName CargoTools {
            if ($Command -ne '--show-stats' -or $Port -ne 43123) { throw "Unexpected command: $Command on $Port" }
            [pscustomobject]@{ ExitCode = 0; Error = '' }
        }
    }
    AfterEach {
        [Environment]::SetEnvironmentVariable('SCCACHE_SERVER_PORT', $script:SavedPort)
        [Environment]::SetEnvironmentVariable('SCCACHE_DISABLE', $script:SavedDisable)
        Should -Invoke Stop-Process -ModuleName CargoTools -Times 0 -Exactly
        Should -Invoke Resolve-UserScript -ModuleName CargoTools -Times 0 -Exactly
    }

    It 'Does not consolidate compiler clients or restart for aggregate memory' {
        Start-SccacheServer -MaxMemoryMB 1 | Should -BeTrue
        Start-SccacheServer -MaxMemoryMB 1 | Should -BeTrue
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 2 -Exactly
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly -ParameterFilter { $Command -ne '--show-stats' }
    }
    It 'Rejects an absent endpoint even with processes and successful synthetic stats available' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
        $health = & $script:Health
        $health.Running | Should -BeFalse
        $health.Healthy | Should -BeFalse
        $health.ProcessCount | Should -Be 2
        $health.Port | Should -Be 43123
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Rejects stats success if the listener disappeared while stats ran' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $true }
        Mock Invoke-SccacheControl -ModuleName CargoTools {
            Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
            [pscustomobject]@{ ExitCode = 0; Error = '' }
        }
        $health = & $script:Health
        $health.Running | Should -BeFalse
        $health.Healthy | Should -BeFalse
        $health.Error | Should -Match 'disappeared'
    }
    It 'Reports failed stats and leaves a listening endpoint intact' {
        Mock Invoke-SccacheControl -ModuleName CargoTools { [pscustomobject]@{ ExitCode = 7; Error = 'fixture EOF' } }
        $health = & $script:Health
        $health.Running | Should -BeTrue
        $health.Healthy | Should -BeFalse
        $health.Error | Should -Match 'exit code 7: fixture EOF'
        Start-SccacheServer -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly -ParameterFilter { $Command -ne '--show-stats' }
    }
    It 'Does not start when passive endpoint inspection fails' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { throw 'fixture network enumeration failed' }
        Start-SccacheServer -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Starts only the absent selected endpoint and validates the resulting listener' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
        Mock Invoke-SccacheControl -ModuleName CargoTools {
            Mock Test-SccacheEndpointListening -ModuleName CargoTools { if ($Port -ne 43123) { throw 'Unexpected endpoint' }; $true }
            [pscustomobject]@{ ExitCode = 0; Error = '' }
        } -ParameterFilter { $Command -eq '--start-server' -and $Port -eq 43123 }
        Start-SccacheServer | Should -BeTrue
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--start-server' -and $Port -eq 43123 }
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--show-stats' -and $Port -eq 43123 }
    }
    It 'Rejects successful startup exit without a listener' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
        Mock Invoke-SccacheControl -ModuleName CargoTools { [pscustomobject]@{ ExitCode = 0; Error = '' } }
        Start-SccacheServer -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--start-server' -and $Port -eq 43123 }
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly -ParameterFilter { $Command -eq '--show-stats' }
    }
    It 'Rejects unrelated processes when the startup mutex is unavailable' {
        Mock Get-SccacheStartupLock -ModuleName CargoTools { $null }
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
        Start-SccacheServer | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Accepts a healthy selected endpoint when the startup mutex is unavailable' {
        Mock Get-SccacheStartupLock -ModuleName CargoTools { $null }
        Start-SccacheServer | Should -BeTrue
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--show-stats' -and $Port -eq 43123 }
    }
    It 'Refuses explicit restart without the startup lock' {
        Mock Get-SccacheStartupLock -ModuleName CargoTools { $null }
        Start-SccacheServer -Force | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Gracefully restarts only the selected endpoint on explicit Force' {
        Mock Invoke-SccacheControl -ModuleName CargoTools {
            Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
            [pscustomobject]@{ ExitCode = 0; Error = '' }
        } -ParameterFilter { $Command -eq '--stop-server' -and $Port -eq 43123 }
        Mock Invoke-SccacheControl -ModuleName CargoTools {
            Mock Test-SccacheEndpointListening -ModuleName CargoTools { if ($Port -ne 43123) { throw 'Unexpected endpoint' }; $true }
            [pscustomobject]@{ ExitCode = 0; Error = '' }
        } -ParameterFilter { $Command -eq '--start-server' -and $Port -eq 43123 }
        Start-SccacheServer -Force | Should -BeTrue
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--stop-server' -and $Port -eq 43123 }
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--start-server' -and $Port -eq 43123 }
    }
    It 'Does not restart or kill when graceful shutdown fails' {
        Mock Invoke-SccacheControl -ModuleName CargoTools { [pscustomobject]@{ ExitCode = 9; Error = 'fixture stop refused' } }
        { Stop-SccacheServer } | Should -Throw '*exit 9*fixture stop refused*'
        Start-SccacheServer -Force -WarningAction SilentlyContinue | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly -ParameterFilter { $Command -eq '--start-server' }
    }
    It 'Does not start over an endpoint that remains after graceful shutdown' {
        Mock Invoke-SccacheControl -ModuleName CargoTools { [pscustomobject]@{ ExitCode = 0; Error = '' } }
        Start-SccacheServer -Force | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--stop-server' }
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly -ParameterFilter { $Command -eq '--start-server' }
    }
    It 'Does not stop other endpoints when the selected endpoint is absent' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
        Stop-SccacheServer
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Rejects invalid explicit ports without any control command' {
        $env:SCCACHE_SERVER_PORT = '65536'
        Start-SccacheServer -WarningAction SilentlyContinue | Should -BeFalse
        (& $script:Health).Error | Should -Match 'between 1 and 65535'
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Uses the native default when no port is configured' {
        $env:SCCACHE_SERVER_PORT = $null
        & $script:Port | Should -Be 4226
    }
    It 'Rejects out-of-range explicit endpoint arguments before external calls' {
        { & $script:Health -Port 65536 } | Should -Throw '*65535*'
        { Stop-SccacheServer -Port -1 } | Should -Throw '*0*'
        { & $script:Control -Command '--show-stats' -Port 0 } | Should -Throw '*1*'
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Honors WhatIf for explicit stop and restart without sending a control command' {
        Stop-SccacheServer -WhatIf
        Start-SccacheServer -Force -WhatIf | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
    It 'Honors WhatIf when the selected endpoint needs startup' {
        Mock Test-SccacheEndpointListening -ModuleName CargoTools { $false }
        Start-SccacheServer -WhatIf | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
}

Describe 'Passive listener health checks against owned TCP fixtures' {
    BeforeEach {
        Mock Get-Process -ModuleName CargoTools { @() } -ParameterFilter { $Name -eq 'sccache' }
        Mock Invoke-SccacheControl -ModuleName CargoTools { [pscustomobject]@{ ExitCode = 0; Error = '' } }
        $script:Listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $script:Listener.Start()
        $script:FixturePort = $script:Listener.LocalEndpoint.Port
    }
    AfterEach { $script:Listener.Stop() }
    It 'Requires the exact live listener even when global process discovery is empty' {
        $health = & $script:Health -Port $script:FixturePort
        $health.Healthy | Should -BeTrue
        $health.Running | Should -BeTrue
        $health.ProcessCount | Should -Be 0
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 1 -Exactly -ParameterFilter { $Command -eq '--show-stats' -and $Port -eq $script:FixturePort }
    }
    It 'Does not pass for a closed selected port while another endpoint is listening' {
        $closed = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        try { $closed.Start(); $closedPort = $closed.LocalEndpoint.Port } finally { $closed.Stop() }
        $health = & $script:Health -Port $closedPort
        $health.Running | Should -BeFalse
        $health.Healthy | Should -BeFalse
        Should -Invoke Invoke-SccacheControl -ModuleName CargoTools -Times 0 -Exactly
    }
}

Describe 'Bounded native sccache control client' {
    It 'Preserves an actual native failure without launching sccache' {
        Mock Resolve-Sccache -ModuleName CargoTools { (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source }
        $result = & $script:Control -Command '--show-stats' -Port 43123
        $result.ExitCode | Should -Not -Be 0
        ($result.Output + $result.Error) | Should -Match 'show-stats'
    }
    It 'Pins the child endpoint and kills only the owned timed-out client' {
        Mock Resolve-Sccache -ModuleName CargoTools { 'fixture-sccache.exe' }
        $script:ProcessFixture = [pscustomobject]@{
            StartInfo = $null; Killed = 0; KillArgumentCount = -1; Disposed = $false
            StandardOutput = [pscustomobject]@{}; StandardError = [pscustomobject]@{}
        }
        $script:ProcessFixture.StandardOutput | Add-Member ScriptMethod ReadToEndAsync { [System.Threading.Tasks.Task]::FromResult([string]'') }
        $script:ProcessFixture.StandardError | Add-Member ScriptMethod ReadToEndAsync { [System.Threading.Tasks.Task]::FromResult([string]'fixture') }
        $script:ProcessFixture | Add-Member ScriptMethod Start { $true }
        $script:ProcessFixture | Add-Member ScriptMethod WaitForExit { $false }
        $script:ProcessFixture | Add-Member ScriptMethod Kill { $this.Killed++; $this.KillArgumentCount = $args.Count }
        $script:ProcessFixture | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        Mock New-Object -ModuleName CargoTools { $script:ProcessFixture } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }
        $beforePort = $env:SCCACHE_SERVER_PORT
        $beforeSocket = $env:SCCACHE_SERVER_UDS
        try {
            $env:SCCACHE_SERVER_UDS = 'fixture-unrelated.sock'
            { & $script:Control -Command '--show-stats' -Port 43123 -TimeoutMilliseconds 1 } | Should -Throw '*timed out*port 43123*'
            $script:ProcessFixture.StartInfo.EnvironmentVariables.ContainsKey('SCCACHE_SERVER_UDS') | Should -BeFalse
            $env:SCCACHE_SERVER_UDS | Should -Be 'fixture-unrelated.sock'
        } finally {
            [Environment]::SetEnvironmentVariable('SCCACHE_SERVER_UDS', $beforeSocket)
        }
        $script:ProcessFixture.StartInfo.FileName | Should -Be 'fixture-sccache.exe'
        $script:ProcessFixture.StartInfo.Arguments | Should -Be '--show-stats'
        $script:ProcessFixture.StartInfo.EnvironmentVariables['SCCACHE_SERVER_PORT'] | Should -Be '43123'
        $script:ProcessFixture.StartInfo.UseShellExecute | Should -BeFalse
        $script:ProcessFixture.StartInfo.CreateNoWindow | Should -BeTrue
        $script:ProcessFixture.Killed | Should -Be 1
        $script:ProcessFixture.KillArgumentCount | Should -Be 0
        $script:ProcessFixture.Disposed | Should -BeTrue
        $env:SCCACHE_SERVER_PORT | Should -Be $beforePort
    }
    It 'Uses one deadline for process exit and inherited output pipes' {
        Mock Resolve-Sccache -ModuleName CargoTools { 'fixture-sccache.exe' }
        $script:ProcessFixture = [pscustomobject]@{
            StartInfo = $null; ExitCode = 0; Disposed = $false; Killed = 0
            StandardOutput = [pscustomobject]@{}; StandardError = [pscustomobject]@{}
        }
        # These pipes close after the total deadline, but within a second full
        # timeout. Resetting the budget after WaitForExit incorrectly succeeds.
        $script:ProcessFixture.StandardOutput | Add-Member ScriptMethod ReadToEndAsync { [System.Threading.Tasks.Task]::Delay(600) }
        $script:ProcessFixture.StandardError | Add-Member ScriptMethod ReadToEndAsync { [System.Threading.Tasks.Task]::Delay(600) }
        $script:ProcessFixture | Add-Member ScriptMethod Start { $true }
        $script:ProcessFixture | Add-Member ScriptMethod WaitForExit { [System.Threading.Thread]::Sleep(300); $true }
        $script:ProcessFixture | Add-Member ScriptMethod Kill { $this.Killed++ }
        $script:ProcessFixture | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
        Mock New-Object -ModuleName CargoTools { $script:ProcessFixture } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }
        { & $script:Control -Command '--start-server' -Port 43123 -TimeoutMilliseconds 450 } | Should -Throw '*output did not close*'
        $script:ProcessFixture.Killed | Should -Be 0
        $script:ProcessFixture.Disposed | Should -BeTrue
    }
}
