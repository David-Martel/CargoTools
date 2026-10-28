#Requires -Modules Pester
<#
.SYNOPSIS
Pester tests for the machine cache-drive selection and the unavailable-cache-drive fallback.
.DESCRIPTION
Why this file exists: DTM-P1GEN9 keeps its Cargo caches on the T:\ Dev Drive (T:\RustCache). Two
things must hold on every host.
 1. Drive selection must only pick a local filesystem. Mapped rclone/FUSE drives report
    DriveType 'Fixed', so the drive type alone does not tell a local cache drive from a remote one.
 2. When a persisted CARGO_HOME / RUSTUP_HOME / SCCACHE_DIR points into a RustCache folder on a
    drive that is not present (the Dev Drive is not mounted), the process falls back to a usable
    location instead of failing every build. A path the caller chose for themselves must be left
    alone, and a present drive must never be touched.
Real drives are never unmounted. "Missing" is simulated with an injected root probe and with a
drive letter that is verified to be unused; "mapped" uses a temporary subst drive.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force
    $script:module = Get-Module CargoTools

    $script:savedEnv = @{}
    foreach ($name in 'CARGO_HOME', 'RUSTUP_HOME', 'SCCACHE_DIR') {
        $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    # A drive letter nothing is mounted on, found without touching any real drive.
    $script:freeLetter = (68..90 | ForEach-Object { [char]$_ } |
        Where-Object { -not (Test-Path -LiteralPath "${_}:\") } | Select-Object -Last 1)
}

AfterAll {
    foreach ($name in $script:savedEnv.Keys) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name], 'Process')
    }
}

Describe 'Test-CargoToolsLocalCacheDrive' {
    It 'accepts a ready fixed local drive' {
        $info = [pscustomobject]@{ IsReady = $true; DriveType = [System.IO.DriveType]::Fixed; DriveFormat = 'ReFS' }
        & $script:module { param($i) Test-CargoToolsLocalCacheDrive -DriveInfo $i } $info | Should -BeTrue
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a FUSE/rclone mount that reports Fixed'; Ready = $true; Type = 'Fixed'; Format = 'FUSE-rclone' }
        @{ Case = 'a network drive'; Ready = $true; Type = 'Network'; Format = 'NTFS' }
        @{ Case = 'a removable drive'; Ready = $true; Type = 'Removable'; Format = 'NTFS' }
        @{ Case = 'a drive that is not ready'; Ready = $false; Type = 'Fixed'; Format = $null }
    ) {
        $info = [pscustomobject]@{ IsReady = $Ready; DriveType = [System.IO.DriveType]$Type; DriveFormat = $Format }
        & $script:module { param($i) Test-CargoToolsLocalCacheDrive -DriveInfo $i } $info | Should -BeFalse
    }

    It 'rejects a null drive description' {
        & $script:module { Test-CargoToolsLocalCacheDrive -DriveInfo $null } | Should -BeFalse
    }

    It 'matches the real T: drive on this host when it is a local fixed drive (positive control)' -Skip:(-not (Test-Path 'T:\')) {
        $real = [System.IO.DriveInfo]'T:'
        $expected = $real.IsReady -and $real.DriveType -eq 'Fixed' -and $real.DriveFormat -notmatch 'FUSE|rclone|WinFsp|Dokan|WebDAV|NFS|9p|vboxsf|vmhgfs'
        & $script:module { param($i) Test-CargoToolsLocalCacheDrive -DriveInfo $i } $real | Should -Be $expected
    }
}

Describe 'Get-DefaultMachineConfig cache root' {
    BeforeEach {
        Mock Get-GpuInfo -ModuleName CargoTools { @() }
        Mock Get-CudaToolkitInfo -ModuleName CargoTools { $null }
        Mock Get-MsvcInfo -ModuleName CargoTools { $null }
        Mock Get-LlvmInfo -ModuleName CargoTools { $null }
        Mock Get-WindowsSdkInfo -ModuleName CargoTools { $null }
    }

    It 'prefers T:\RustCache when T: is a local cache drive' {
        Mock Test-Path -ModuleName CargoTools { $true } -ParameterFilter { $Path -eq 'T:\' }
        Mock Test-CargoToolsLocalCacheDrive -ModuleName CargoTools { $true } -ParameterFilter { $DriveInfo.Name -eq 'T:\' }
        (& $script:module { Get-DefaultMachineConfig })['CacheRoot'] | Should -Be 'T:\RustCache'
    }

    It 'skips a T: that exists but is not a local cache drive' {
        Mock Test-Path -ModuleName CargoTools { $true } -ParameterFilter { $Path -eq 'T:\' -or $Path -eq 'D:\' }
        Mock Test-CargoToolsLocalCacheDrive -ModuleName CargoTools { $false }
        (& $script:module { Get-DefaultMachineConfig })['CacheRoot'] | Should -Be (Join-Path $env:LOCALAPPDATA 'RustCache')
    }

    It 'falls back to D:\RustCache when only D: is a local cache drive' {
        Mock Test-Path -ModuleName CargoTools { $true } -ParameterFilter { $Path -eq 'T:\' -or $Path -eq 'D:\' }
        Mock Test-CargoToolsLocalCacheDrive -ModuleName CargoTools { $DriveInfo.Name -eq 'D:\' }
        (& $script:module { Get-DefaultMachineConfig })['CacheRoot'] | Should -Be 'D:\RustCache'
    }
}

Describe 'Resolve-CargoToolsUnavailableCacheValue' {
    BeforeAll {
        $script:fallback = 'C:\Users\fixture\.cargo'
        # Only C:\ and the persisted user's E:\ exist; everything else is "not mounted".
        $script:present = { param($root) $root -in @('C:\', 'E:\') }
        function Resolve-Value {
            param($Value, $Persisted = $null)
            & $script:module {
                param($v, $p, $f, $probe)
                Resolve-CargoToolsUnavailableCacheValue -Value $v -PersistedValue $p -Fallback $f -TestRoot $probe
            } $Value $Persisted $script:fallback $script:present
        }
    }

    It 'leaves an owned path alone while its drive is present' {
        Resolve-Value -Value 'C:\RustCache\cargo-home' | Should -BeNullOrEmpty
    }

    It 'falls back when an owned path is on a drive that is not present' {
        Resolve-Value -Value 'T:\RustCache\cargo-home' | Should -Be $script:fallback
    }

    It 'matches the owned layout case-insensitively and for the cache folder itself' -ForEach @(
        @{ Value = 't:\rustcache\sccache' }
        @{ Value = 'T:\RustCache' }
    ) {
        Resolve-Value -Value $Value | Should -Be $script:fallback
    }

    It 'prefers the persisted user value when its drive is present' {
        Resolve-Value -Value 'T:\RustCache\cargo-home' -Persisted 'E:\cargo' | Should -Be 'E:\cargo'
    }

    It 'ignores a persisted user value that is itself on a missing drive' {
        Resolve-Value -Value 'T:\RustCache\cargo-home' -Persisted 'T:\RustCache\cargo-home' | Should -Be $script:fallback
    }

    It 'accepts a persisted user value with no drive root' {
        Resolve-Value -Value 'T:\RustCache\cargo-home' -Persisted '\\server\share\cargo' | Should -Be '\\server\share\cargo'
    }

    It 'keeps an explicit caller choice outside the RustCache layout even if its drive is missing' -ForEach @(
        @{ Value = 'Z:\my-own-cargo' }
        @{ Value = 'Z:\RustCacheBackup\cargo-home' }
    ) {
        Resolve-Value -Value $Value | Should -BeNullOrEmpty
    }

    It 'ignores values with no drive letter root' -ForEach @(
        @{ Value = '\\server\share\RustCache\cargo-home' }
        @{ Value = 'relative\RustCache\cargo-home' }
        @{ Value = '' }
        @{ Value = $null }
    ) {
        Resolve-Value -Value $Value | Should -BeNullOrEmpty
    }
}

Describe 'Repair-CargoToolsCacheEnvironment' {
    BeforeEach {
        foreach ($name in 'CARGO_HOME', 'RUSTUP_HOME', 'SCCACHE_DIR') {
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
    }

    It 'rewrites only the process variables that point into a missing RustCache drive' {
        $missing = "$($script:freeLetter):\RustCache"
        $env:CARGO_HOME = "$missing\cargo-home"
        $env:RUSTUP_HOME = "$missing\rustup"
        $env:SCCACHE_DIR = Join-Path $TestDrive 'sccache'   # present drive, left alone
        & $script:module { Repair-CargoToolsCacheEnvironment -GetPersistedValue { param($n) $null } } | Out-Null
        $env:CARGO_HOME | Should -Be (Join-Path $HOME '.cargo')
        $env:RUSTUP_HOME | Should -Be (Join-Path $HOME '.rustup')
        $env:SCCACHE_DIR | Should -Be (Join-Path $TestDrive 'sccache')
    }

    It 'uses the sccache fallback under LOCALAPPDATA' {
        $env:SCCACHE_DIR = "$($script:freeLetter):\RustCache\sccache"
        & $script:module { Repair-CargoToolsCacheEnvironment -GetPersistedValue { param($n) $null } } | Out-Null
        $env:SCCACHE_DIR | Should -Be (Join-Path $env:LOCALAPPDATA 'RustCache\sccache')
    }

    It 'preserves an explicit caller choice on a missing drive' {
        $env:CARGO_HOME = "$($script:freeLetter):\my-own-cargo"
        & $script:module { Repair-CargoToolsCacheEnvironment -GetPersistedValue { param($n) $null } } | Out-Null
        $env:CARGO_HOME | Should -Be "$($script:freeLetter):\my-own-cargo"
    }

    It 'does nothing when the variables are unset' {
        $changes = @(& $script:module { Repair-CargoToolsCacheEnvironment -GetPersistedValue { param($n) $null } })
        $changes.Count | Should -Be 0
        $env:CARGO_HOME | Should -BeNullOrEmpty
    }

    It 'reports each change' {
        $env:CARGO_HOME = "$($script:freeLetter):\RustCache\cargo-home"
        $changes = @(& $script:module { Repair-CargoToolsCacheEnvironment -GetPersistedValue { param($n) $null } })
        $changes.Count | Should -Be 1
        $changes[0].Name | Should -Be 'CARGO_HOME'
        $changes[0].Value | Should -Be (Join-Path $HOME '.cargo')
    }

    Context 'with a mapped (subst) drive' {
        BeforeEach {
            $script:mapped = $null
            $letter = $script:freeLetter
            if ($letter) {
                & subst "${letter}:" $TestDrive 2>&1 | Out-Null
                if (Test-Path -LiteralPath "${letter}:\") { $script:mapped = $letter }
            }
        }
        AfterEach {
            if ($script:mapped) { & subst "$($script:mapped):" /d 2>&1 | Out-Null }
        }

        It 'treats a present mapped root as present and disconnects as missing' {
            if (-not $script:mapped) { Set-ItResult -Skipped -Because 'subst is not available'; return }
            $root = "$($script:mapped):\RustCache\cargo-home"
            $env:CARGO_HOME = $root
            & $script:module { Repair-CargoToolsCacheEnvironment -GetPersistedValue { param($n) $null } } | Out-Null
            $env:CARGO_HOME | Should -Be $root -Because 'the mapped drive is present'

            & subst "$($script:mapped):" /d 2>&1 | Out-Null
            & $script:module { Repair-CargoToolsCacheEnvironment -GetPersistedValue { param($n) $null } } | Out-Null
            $env:CARGO_HOME | Should -Be (Join-Path $HOME '.cargo') -Because 'the mapped drive is gone'
            $script:mapped = $null
        }
    }
}

Describe 'Tracked machine registry (Config/machines-cargo.json)' {
    BeforeAll {
        $script:registry = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'Config\machines-cargo.json') -Raw | ConvertFrom-Json
    }

    It 'names every machine by its own Hostname (no null or mismatched entries)' {
        foreach ($entry in $script:registry.PSObject.Properties) {
            $entry.Value.Hostname | Should -Be $entry.Name -Because "entry $($entry.Name) must carry its own hostname"
        }
    }

    It 'keeps every BuildJobs value positive and within the 16-job cap of the default derivation' {
        foreach ($entry in $script:registry.PSObject.Properties) {
            [int]$entry.Value.BuildJobs | Should -BeGreaterThan 0
            [int]$entry.Value.BuildJobs | Should -BeLessOrEqual 16
        }
    }

    It 'places every DTM-P1GEN9 cache path under the T:\RustCache Dev Drive' {
        $gen9 = $script:registry.'DTM-P1GEN9'
        $gen9 | Should -Not -BeNullOrEmpty
        $gen9.CacheRoot | Should -Be 'T:\RustCache'
        foreach ($name in 'CargoHome', 'RustupHome', 'CargoTargetDir', 'SccacheDir') {
            $gen9.$name | Should -BeLike 'T:\RustCache\*'
        }
    }

    It 'is what Get-MachineConfig returns on DTM-P1GEN9' {
        Mock Get-MachineIdentity -ModuleName CargoTools { 'DTM-P1GEN9' }
        Mock Get-DefaultMachineConfig -ModuleName CargoTools { @{ CacheRoot = 'C:\default' } }
        Mock Register-CurrentMachine -ModuleName CargoTools { throw 'a known machine must not be re-registered' }
        try {
            $config = & $script:module { Get-MachineConfig -Force }
            $config['CacheRoot'] | Should -Be 'T:\RustCache'
            $config['CargoHome'] | Should -Be 'T:\RustCache\cargo-home'
        } finally {
            & $script:module { $script:MachineConfig = $null }
        }
    }
}

Describe 'Get-MachineConfig with the registered Dev Drive unmounted' {
    BeforeEach {
        $script:localRoot = Join-Path $TestDrive 'local\RustCache'
        Mock Get-MachineIdentity -ModuleName CargoTools { 'DTM-P1GEN9' }
        $root = $script:localRoot   # closures capture locals, not $script: variables
        Mock Get-DefaultMachineConfig -ModuleName CargoTools {
            @{
                CacheRoot = $root; CargoHome = "$root\cargo-home"; RustupHome = "$root\rustup"
                CargoTargetDir = "$root\cargo-target"; SccacheDir = "$root\sccache"; BuildJobs = 4
            }
        }.GetNewClosure()
        Mock Register-CurrentMachine -ModuleName CargoTools { throw 'a known machine must not be re-registered' }
    }
    AfterEach { & $script:module { $script:MachineConfig = $null } }

    It 'keeps the usable local defaults for every path when T: is not mounted' {
        Mock Test-Path -ModuleName CargoTools { $false } -ParameterFilter { $LiteralPath -eq 'T:\' }
        $config = & $script:module { Get-MachineConfig -Force }
        $config['CacheRoot'] | Should -Be $script:localRoot
        $config['CargoHome'] | Should -Be "$script:localRoot\cargo-home"
        $config['RustupHome'] | Should -Be "$script:localRoot\rustup"
        $config['CargoTargetDir'] | Should -Be "$script:localRoot\cargo-target"
        $config['SccacheDir'] | Should -Be "$script:localRoot\sccache"
        $config['BuildJobs'] | Should -Be 16 -Because 'only the unavailable paths fall back; other registry values still apply'
    }

    It 'uses the registered T:\RustCache paths when T: is mounted (positive control)' {
        Mock Test-Path -ModuleName CargoTools { $true } -ParameterFilter { $LiteralPath -eq 'T:\' }
        $config = & $script:module { Get-MachineConfig -Force }
        $config['CacheRoot'] | Should -Be 'T:\RustCache'
        $config['CargoHome'] | Should -Be 'T:\RustCache\cargo-home'
        $config['SccacheDir'] | Should -Be 'T:\RustCache\sccache'
    }
}

Describe 'Test-BuildEnvironment cargo home' {
    BeforeAll { $script:savedCargoHome = $env:CARGO_HOME }
    AfterAll { $env:CARGO_HOME = $script:savedCargoHome }
    BeforeEach { Mock Resolve-CargoToolsFastCargoHome -ModuleName CargoTools { Join-Path $TestDrive 'resolved' } }

    It 'keeps an explicit CARGO_HOME authoritative even when it does not exist yet' {
        $env:CARGO_HOME = Join-Path $TestDrive 'explicit-but-missing'
        $null = Test-BuildEnvironment -Detailed *>&1
        Should -Invoke Resolve-CargoToolsFastCargoHome -ModuleName CargoTools -Times 0 -Exactly
    }

    It 'resolves a cargo home through the fallback chain when CARGO_HOME is unset (positive control)' {
        Remove-Item Env:CARGO_HOME -ErrorAction SilentlyContinue
        $null = Test-BuildEnvironment -Detailed *>&1
        Should -Invoke Resolve-CargoToolsFastCargoHome -ModuleName CargoTools -Times 1 -Exactly
    }
}
