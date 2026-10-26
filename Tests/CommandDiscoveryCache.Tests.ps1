#Requires -Version 5.1
# Owned filesystem command discovery only; the fixture command bytes are NEVER executed.
BeforeAll {
    $script:CacheSource = Join-Path $PSScriptRoot '../Private/Environment.ps1'
    $script:CacheModule = New-Module -ArgumentList $script:CacheSource -ScriptBlock {
        param($Source)
        . $Source
        function Initialize-CargoToolsCommandAcceleration { $script:CargoToolsAccelerationInitialized = $true; return $false }
        $script:CargoToolsUseProfileAccelerator = $false
        $PSModuleAutoLoadingPreference = 'None'
    }
    function New-CacheCommand {
        param([string]$Directory, [string]$Name = 'cargo-cache-control.cmd')
        [void][IO.Directory]::CreateDirectory($Directory)
        $path = Join-Path $Directory $Name
        [IO.File]::WriteAllText($path, '@exit /b 0')
        return $path
    }
    function Find-FixtureCommand {
        param([string]$Name = 'cargo-cache-control.cmd', [switch]$BypassCache)
        & $script:CacheModule { param($N, $Bypass) Find-CargoCommandPath -Name $N -BypassCache:$Bypass } $Name ([bool]$BypassCache)
    }
}

Describe 'Command discovery context and bounded cache on actual owned Windows paths' -Tag 'Unit','CommandCache' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    BeforeEach {
        $script:SavedPath = $env:PATH
        $script:SavedPathExt = $env:PATHEXT
        $script:SavedLocation = Get-Location
        $script:CacheRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:RootA = Join-Path $script:CacheRoot 'a'
        $script:RootB = Join-Path $script:CacheRoot 'b'
        [void][IO.Directory]::CreateDirectory($script:RootA)
        [void][IO.Directory]::CreateDirectory($script:RootB)
        $env:PATH = $script:RootA
        $env:PATHEXT = '.COM;.EXE;.BAT;.CMD'
        & $script:CacheModule {
            $script:CargoToolsCommandPathCache = @{}
            $script:CargoToolsCommandCacheContext = $null
            $script:CargoToolsUseProfileAccelerator = $false
        }
    }
    AfterEach {
        $env:PATH = $script:SavedPath
        $env:PATHEXT = $script:SavedPathExt
        Set-Location -LiteralPath $script:SavedLocation.Path
    }

    # Protects: a long-lived shell follows the user's current toolchain PATH.
    # Detects: a successful old lookup masking a different physical command.
    # Needs: real Get-Command and owned files, no executable invocation.
    # Breadcrumb: Find-CargoCommandPath outer cache context.
    It 'resolves a different command immediately after PATH changes' {
        $first = New-CacheCommand $script:RootA
        $second = New-CacheCommand $script:RootB
        Find-FixtureCommand | Should -BeExactly $first
        $env:PATH = $script:RootB
        Find-FixtureCommand | Should -BeExactly $second
    }

    It 'does not retain a negative lookup across PATH changes' {
        Find-FixtureCommand | Should -BeNullOrEmpty
        $second = New-CacheCommand $script:RootB
        $env:PATH = $script:RootB
        Find-FixtureCommand | Should -BeExactly $second
    }

    It 'rechecks the selected executable extensions after PATHEXT changes' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $cmd = New-CacheCommand $script:RootA
        $bat = New-CacheCommand $script:RootA 'cargo-cache-control.bat'
        $env:PATHEXT = '.CMD'
        Find-FixtureCommand -Name cargo-cache-control | Should -BeExactly $cmd
        $env:PATHEXT = '.BAT'
        Find-FixtureCommand -Name cargo-cache-control | Should -BeExactly $bat
    }

    It 'resolves relative PATH entries against the current filesystem location' {
        $first = New-CacheCommand (Join-Path $script:RootA 'bin')
        $second = New-CacheCommand (Join-Path $script:RootB 'bin')
        $env:PATH = './bin'
        Set-Location -LiteralPath $script:RootA
        Find-FixtureCommand | Should -BeExactly $first
        Set-Location -LiteralPath $script:RootB
        Find-FixtureCommand | Should -BeExactly $second
    }

    It 'retains filesystem context when only the provider location changes' -Skip:([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        $first = New-CacheCommand (Join-Path $script:RootA 'bin')
        $env:PATH = './bin'
        Set-Location -LiteralPath $script:RootA
        Find-FixtureCommand | Should -BeExactly $first
        Push-Location 'Registry::HKEY_CURRENT_USER'
        try { Find-FixtureCommand -BypassCache | Should -BeExactly $first } finally { Pop-Location }
    }

    It 'does not return a cached executable that has been removed' {
        $first = New-CacheCommand $script:RootA
        Find-FixtureCommand | Should -BeExactly $first
        [IO.File]::Delete($first)
        Find-FixtureCommand | Should -BeNullOrEmpty
    }

    It 'never caches explicit relative paths across filesystem locations' {
        $first = New-CacheCommand $script:RootA
        $second = New-CacheCommand $script:RootB
        Set-Location -LiteralPath $script:RootA
        Find-FixtureCommand -Name './cargo-cache-control.cmd' | Should -BeExactly $first
        Set-Location -LiteralPath $script:RootB
        Find-FixtureCommand -Name './cargo-cache-control.cmd' | Should -BeExactly $second
    }

    It 'finds a newly created command after the negative entry expires without sleeping' {
        Find-FixtureCommand | Should -BeNullOrEmpty
        $first = New-CacheCommand $script:RootA
        & $script:CacheModule { $script:CargoToolsCommandPathCache['exe::cargo-cache-control.cmd'].ExpiresUtc = [DateTime]::UtcNow.AddSeconds(-1) }
        Find-FixtureCommand | Should -BeExactly $first
    }

    It 'rediscovers a higher-priority newly created command after positive expiry' {
        $second = New-CacheCommand $script:RootB
        $env:PATH = $script:RootA + [IO.Path]::PathSeparator + $script:RootB
        Find-FixtureCommand | Should -BeExactly $second
        $first = New-CacheCommand $script:RootA
        & $script:CacheModule { $script:CargoToolsCommandPathCache['exe::cargo-cache-control.cmd'].ExpiresUtc = [DateTime]::UtcNow.AddSeconds(-1) }
        Find-FixtureCommand | Should -BeExactly $first
    }

    It 'bypasses both accelerator and outer cache without writing either cache' {
        $first = New-CacheCommand $script:RootA
        Find-FixtureCommand | Should -BeExactly $first
        & $script:CacheModule {
            $script:CargoToolsUseProfileAccelerator = $true
            $script:FixtureBypass = $false
            function script:Find-CommandCached {
                param($Name,[switch]$BypassCache)
                $script:FixtureBypass = [bool]$BypassCache
                if ($BypassCache) { return $script:FreshFixturePath }
                return $script:StaleFixturePath
            }
            $script:StaleFixturePath = 'stale accelerator sentinel'
        }
        $second = New-CacheCommand $script:RootB
        & $script:CacheModule {param($P) $script:FreshFixturePath = $P} $second
        Find-FixtureCommand -BypassCache | Should -BeExactly $second
        (& $script:CacheModule {$script:FixtureBypass}) | Should -BeTrue
        # The bypass result must not replace the valid preexisting outer entry.
        Find-FixtureCommand | Should -BeExactly $first
    }

    It 'preserves PowerShell <Kind> precedence in any-command mode without using an application-only accelerator' -ForEach @(
        @{Kind='function';Name='cargo-cache-function'},@{Kind='alias';Name='cargo-cache-alias'},@{Kind='cmdlet';Name='Write-Output'}
    ) {
        $application = New-CacheCommand $script:RootA ($Name + '.cmd')
        $env:PATH = './bin' + [IO.Path]::PathSeparator + $script:RootA
        & $script:CacheModule {
            function script:cargo-cache-function { throw 'Fixture functions must never be invoked.' }
            Set-Alias -Name cargo-cache-alias -Value cargo-cache-function -Scope Script
            $script:CargoToolsUseProfileAccelerator = $true
            function script:Find-CommandCached { param($Name,[switch]$BypassCache) $script:AnyAcceleratorCalls++; $script:AnyApplicationPath }
            function script:Find-CommandNative { param($Name) $script:AnyAcceleratorCalls++; $script:AnyApplicationPath }
        }
        & $script:CacheModule {param($P) $script:AnyApplicationPath=$P;$script:AnyAcceleratorCalls=0} $application
        $expected = & $script:CacheModule {param($N) Select-CargoCommandPathCandidate (Get-Command $N -ErrorAction Stop)} $Name
        $expected | Should -Not -BeNullOrEmpty
        $actual = & $script:CacheModule {param($N) Find-CargoCommandPath -Name $N -AllowNonExternal} $Name
        $actual | Should -BeExactly $expected
        (& $script:CacheModule {$script:AnyAcceleratorCalls}) | Should -Be 0
        $actual | Should -Not -BeExactly $application
        if ($Kind -ne 'cmdlet') {
            $external = & $script:CacheModule {param($N) Find-CargoCommandPath -Name $N} $Name
            # Windows application identity is case-insensitive; PATHEXT may use uppercase suffixes.
            ([StringComparer]::OrdinalIgnoreCase).Equals($external, $application) | Should -BeTrue
            [IO.File]::Exists($external) | Should -BeTrue
        }
    }


    It 'admits a newly introduced <Kind> after the same application was previously resolved' -ForEach @(
        @{Kind='function'},@{Kind='alias'}
    ) {
        $name = 'cargo-cache-introduced-' + $Kind
        $application = New-CacheCommand $script:RootA ($name + '.cmd')
        (& $script:CacheModule {param($N) Find-CargoCommandPath -Name $N -AllowNonExternal} $name) | Should -BeExactly $application
        (& $script:CacheModule {param($N) Find-CargoCommandPath -Name $N} $name) | Should -BeExactly $application
        & $script:CacheModule {
            param($Kind)
            if ($Kind -eq 'function') {
                function script:cargo-cache-introduced-function { throw 'Fixture command must never execute.' }
            } else {
                Set-Alias -Name cargo-cache-introduced-alias -Value Write-Output -Scope Script
            }
        } $Kind
        $expected = & $script:CacheModule {param($N) Select-CargoCommandPathCandidate (Get-Command $N -ErrorAction Stop)} $name
        (& $script:CacheModule {param($N) Find-CargoCommandPath -Name $N -AllowNonExternal} $name) | Should -BeExactly $expected
        (& $script:CacheModule {param($N) Find-CargoCommandPath -Name $N} $name) | Should -BeExactly $application
    }

    It 'treats a bracket-bearing <Mode> directory literally during relative PATH discovery' -ForEach @(
        @{Mode='cwd'},@{Mode='PATH'}
    ) {
        $literal = Join-Path $script:RootA 'literal[ab]'
        $decoy = Join-Path $script:RootA 'literala'
        if ($Mode -eq 'cwd') {
            $expected = New-CacheCommand (Join-Path $literal 'bin')
            $null = New-CacheCommand (Join-Path $decoy 'bin')
            Set-Location -LiteralPath $literal
            $env:PATH = './bin'
        } else {
            $expected = New-CacheCommand $literal
            $null = New-CacheCommand $decoy
            Set-Location -LiteralPath $script:RootA
            $env:PATH = './literal[ab]'
        }
        Find-FixtureCommand | Should -BeExactly $expected
    }


    It 'matches PowerShell bare-name application selection for <Mode>' -ForEach @(
        @{Mode='extensionless-only';Competing=$false},@{Mode='PATHEXT-competition';Competing=$true}
    ) {
        $bin = Join-Path $script:RootA 'bin'
        $name = 'cargo-cache-bare-' + $Mode
        $expected = New-CacheCommand $bin $name
        if ($Competing) { $expected = New-CacheCommand $bin ($name + '.cmd') }
        Set-Location -LiteralPath $script:RootA
        $env:PATH = './bin'
        $env:PATHEXT = '.CMD;.EXE'
        $actual = Find-FixtureCommand -Name $name
        ([StringComparer]::OrdinalIgnoreCase).Equals($actual, $expected) | Should -BeTrue
        [IO.File]::Exists($actual) | Should -BeTrue
    }


    It 'skips a malformed <Kind> PATH entry while finding the actual valid command' -ForEach @(
        @{Kind='embedded-quote';Bad='bad"entry'},@{Kind='carriage-return';Bad=("bad"+[char]13+"entry")}
    ) {
        $expected=New-CacheCommand $script:RootA
        $env:PATH=$Bad+[IO.Path]::PathSeparator+$script:RootA
        $output=@(Find-FixtureCommand 2>&1)
        $output.Count | Should -Be 1
        $output[0] | Should -BeExactly $expected
        @($output|Where-Object{$_-is[Management.Automation.ErrorRecord]}).Count | Should -Be 0
    }

    It 'skips an unmounted PATH drive without emitting errors or losing the valid relative entry' {
        $bin=Join-Path $script:RootA 'bin';$expected=New-CacheCommand $bin
        Set-Location -LiteralPath $script:RootA
        $unused=@('Z','Y','X','W'|Where-Object{-not(Get-PSDrive -Name $_ -ErrorAction SilentlyContinue)})[0]
        $env:PATH=$unused+':\not-mounted;./bin'
        $output=@(& $script:CacheModule {$ErrorActionPreference='Continue';Find-CargoCommandPath -Name cargo-cache-control.cmd} 2>&1)
        $output.Count | Should -Be 1
        $output[0] | Should -BeExactly $expected
        @($output|Where-Object{$_-is[Management.Automation.ErrorRecord]}).Count | Should -Be 0
    }

    # These retain the actual outer resolver. The accelerator command signature
    # matches installed ProfileAccelerator0.4.1; only that boundary is injected.
    # No native DLL or fake command is executed, and the seam stays enabled.
    It 'accepts a verified accelerator candidate without reaching the native or PowerShell fallback' {
        $expected=New-CacheCommand $script:RootA
        & $script:CacheModule {param($P)
            $script:CargoToolsUseProfileAccelerator=$true;$script:LayerCandidate=$P;$script:CachedCalls=0;$script:NativeCalls=0
            function script:Find-CommandCached {param([Parameter(Mandatory)][string]$Name,[switch]$BypassCache)$script:CachedCalls++;$script:LayerCandidate}
            function script:Find-CommandNative {param($Name)$script:NativeCalls++;$null}
        } $expected
        Find-FixtureCommand | Should -BeExactly $expected
        (& $script:CacheModule {$script:CachedCalls}) | Should -Be 1
        (& $script:CacheModule {$script:NativeCalls}) | Should -Be 0
    }

    It 'does not re-admit a deleted path returned by both enabled accelerator layers' {
        $expected=New-CacheCommand $script:RootA
        & $script:CacheModule {param($P)
            $script:CargoToolsUseProfileAccelerator=$true;$script:LayerCandidate=$P
            function script:Find-CommandCached {param([Parameter(Mandatory)][string]$Name,[switch]$BypassCache)$script:LayerCandidate}
            function script:Find-CommandNative {param($Name)$script:LayerCandidate}
        } $expected
        Find-FixtureCommand | Should -BeExactly $expected
        [IO.File]::Delete($expected)
        Find-FixtureCommand | Should -BeNullOrEmpty
    }

    It 'refreshes an expired outer positive through the actual cache-bypass signature' {
        $second=New-CacheCommand $script:RootB
        $env:PATH=$script:RootA+[IO.Path]::PathSeparator+$script:RootB
        & $script:CacheModule {param($P)
            $script:CargoToolsUseProfileAccelerator=$true;$script:InnerCached=$P;$script:InnerFresh=$P;$script:LastBypass=$false
            function script:Find-CommandCached {param([Parameter(Mandatory)][string]$Name,[switch]$BypassCache)$script:LastBypass=[bool]$BypassCache;if($BypassCache){$script:InnerFresh}else{$script:InnerCached}}
            function script:Find-CommandNative {param($Name)$script:InnerFresh}
        } $second
        Find-FixtureCommand | Should -BeExactly $second
        $first=New-CacheCommand $script:RootA
        & $script:CacheModule {param($P)$script:InnerFresh=$P;$script:CargoToolsCommandPathCache['exe::cargo-cache-control.cmd'].ExpiresUtc=[DateTime]::UtcNow.AddSeconds(-1)} $first
        Find-FixtureCommand | Should -BeExactly $first
        (& $script:CacheModule {$script:LastBypass}) | Should -BeTrue
    }

    It 'rejects an existing wrong-name accelerator candidate and returns the actual requested application' {
        $expected=New-CacheCommand $script:RootA
        $wrong=New-CacheCommand $script:RootA 'wrong-command.cmd'
        & $script:CacheModule {param($P)
            $script:CargoToolsUseProfileAccelerator=$true;$script:WrongCandidate=$P;$script:CachedCalls=0;$script:NativeCalls=0
            function script:Find-CommandCached {param([Parameter(Mandatory)][string]$Name,[switch]$BypassCache)$script:CachedCalls++;$script:WrongCandidate}
            function script:Find-CommandNative {param($Name)$script:NativeCalls++;$script:WrongCandidate}
        } $wrong
        Find-FixtureCommand | Should -BeExactly $expected
        (& $script:CacheModule {$script:CachedCalls}) | Should -Be 1
        (& $script:CacheModule {$script:NativeCalls}) | Should -Be 1
    }

    It 'preserves directory priority before extension priority across relative and absolute PATH entries' {
        $bin=Join-Path $script:RootA 'bin';$expected=New-CacheCommand $bin
        $null=New-CacheCommand $script:RootB 'cargo-cache-control.exe'
        Set-Location -LiteralPath $script:RootA
        $env:PATH='./bin'+[IO.Path]::PathSeparator+$script:RootB;$env:PATHEXT='.EXE;.CMD'
        Find-FixtureCommand | Should -BeExactly $expected
    }

}
