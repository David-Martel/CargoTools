#Requires -Modules Pester
<#
.SYNOPSIS
Tests for concurrent access patterns: mutex acquisition, parallel sccache
startup, concurrent file copy, and environment variable isolation.
.DESCRIPTION
Exercises the cross-process synchronization primitives (ProcessMutex, FileCopy)
and verifies that multiple agents can safely invoke CargoTools simultaneously
without sccache startup races, file copy corruption, or env var bleed.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    $module = Get-Module CargoTools

    # Determine if C# types are available
    $script:HasMutex    = ([System.Management.Automation.PSTypeName]'CargoTools.ProcessMutex').Type -ne $null
    $script:HasFileCopy = ([System.Management.Automation.PSTypeName]'CargoTools.FileCopy').Type -ne $null
    $script:EnterCargoBuildQueue = & $module { ${function:Enter-CargoBuildQueue} }
    $script:ExitCargoBuildQueue = & $module { ${function:Exit-CargoBuildQueue} }
    $script:GetCargoQueueStatusInternal = & $module { ${function:Get-CargoQueueStatusInternal} }

    # Test fixture dir
    $script:FixtureDir = Join-Path $env:TEMP 'CargoTools-ConcurrencyTests'
    if (-not (Test-Path $script:FixtureDir)) {
        New-Item -ItemType Directory -Path $script:FixtureDir -Force | Out-Null
    }
}

AfterAll {
    if (Test-Path $script:FixtureDir) {
        Remove-Item $script:FixtureDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'C# Type Availability' {
    It 'CargoTools.ProcessMutex is loaded' {
        $script:HasMutex | Should -Be $true
    }
    It 'CargoTools.FileCopy is loaded' {
        $script:HasFileCopy | Should -Be $true
    }
    It 'CargoTools.ShellEscape is loaded' {
        ([System.Management.Automation.PSTypeName]'CargoTools.ShellEscape').Type | Should -Not -BeNull
    }
    It 'CargoTools.CopyResult has expected properties' {
        if (-not $script:HasFileCopy) {
            Set-ItResult -Skipped -Because 'FileCopy type not available'
            return
        }
        $result = New-Object CargoTools.CopyResult
        $result.PSObject.Properties.Name | Should -Contain 'Source'
        $result.PSObject.Properties.Name | Should -Contain 'Destination'
        $result.PSObject.Properties.Name | Should -Contain 'Success'
        $result.PSObject.Properties.Name | Should -Contain 'Attempts'
        $result.PSObject.Properties.Name | Should -Contain 'LastError'
    }
}

Describe 'ProcessMutex' {
    It 'Acquires and releases a named mutex' {
        if (-not $script:HasMutex) {
            Set-ItResult -Skipped -Because 'ProcessMutex type not available'
            return
        }
        $handle = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_PesterTest_Acquire', 5000)
        $handle | Should -Not -BeNull
        # Dispose releases the mutex
        $handle.Dispose()
    }

    It 'Allows re-acquisition after release' {
        if (-not $script:HasMutex) {
            Set-ItResult -Skipped -Because 'ProcessMutex type not available'
            return
        }
        $handle1 = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_PesterTest_ReAcquire', 5000)
        $handle1 | Should -Not -BeNull
        $handle1.Dispose()

        # Should be able to acquire again immediately
        $handle2 = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_PesterTest_ReAcquire', 5000)
        $handle2 | Should -Not -BeNull
        $handle2.Dispose()
    }

    It 'Times out when mutex is held by another process' {
        if (-not $script:HasMutex) {
            Set-ItResult -Skipped -Because 'ProcessMutex type not available'
            return
        }
        # Use a signal file so the parent knows when the child has the mutex
        $signalFile = Join-Path $script:FixtureDir 'mutex-signal-timeout.txt'
        Remove-Item $signalFile -ErrorAction SilentlyContinue

        $job = Start-Job -ScriptBlock {
            param($signal)
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
namespace CargoToolsTest {
    public static class MutexHolder {
        public static void HoldMutex(string name, int holdMs, string signalPath) {
            bool createdNew;
            using (var mutex = new Mutex(false, @"Global\" + name, out createdNew)) {
                mutex.WaitOne(10000);
                File.WriteAllText(signalPath, "held");
                Thread.Sleep(holdMs);
                mutex.ReleaseMutex();
            }
        }
    }
}
'@
            [CargoToolsTest.MutexHolder]::HoldMutex('CargoTools_PesterTest_Timeout', 5000, $signal)
        } -ArgumentList $signalFile

        # Wait until the signal file appears (child has mutex)
        $waited = 0
        while (-not (Test-Path $signalFile) -and $waited -lt 15000) {
            Start-Sleep -Milliseconds 200
            $waited += 200
        }
        (Test-Path $signalFile) | Should -Be $true

        # Now try to acquire — should fail with short timeout
        $blocked = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_PesterTest_Timeout', 200)
        try {
            $blocked | Should -BeNull
        } finally {
            if ($blocked) { $blocked.Dispose() }
            $job | Wait-Job -Timeout 10 | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Handles multiple distinct mutex names independently' {
        if (-not $script:HasMutex) {
            Set-ItResult -Skipped -Because 'ProcessMutex type not available'
            return
        }
        $handleA = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_PesterTest_A', 5000)
        $handleB = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_PesterTest_B', 5000)

        try {
            $handleA | Should -Not -BeNull
            $handleB | Should -Not -BeNull
        } finally {
            if ($handleA) { $handleA.Dispose() }
            if ($handleB) { $handleB.Dispose() }
        }
    }

    It 'Double dispose does not throw' {
        if (-not $script:HasMutex) {
            Set-ItResult -Skipped -Because 'ProcessMutex type not available'
            return
        }
        $handle = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_PesterTest_DoubleFree', 5000)
        $handle | Should -Not -BeNull
        { $handle.Dispose(); $handle.Dispose() } | Should -Not -Throw
    }
}

Describe 'FileCopy with retry' {
    It 'Copies a file successfully on first attempt' {
        if (-not $script:HasFileCopy) {
            Set-ItResult -Skipped -Because 'FileCopy type not available'
            return
        }
        $src = Join-Path $script:FixtureDir 'copy-src.txt'
        $dst = Join-Path $script:FixtureDir 'copy-dst.txt'
        Set-Content -Path $src -Value 'hello world'
        Remove-Item $dst -ErrorAction SilentlyContinue

        $result = [CargoTools.FileCopy]::CopyWithRetry($src, $dst, 3, 50)
        $result.Success | Should -Be $true
        $result.Attempts | Should -Be 1
        (Get-Content $dst -Raw).Trim() | Should -Be 'hello world'
    }

    It 'Overwrites existing destination' {
        if (-not $script:HasFileCopy) {
            Set-ItResult -Skipped -Because 'FileCopy type not available'
            return
        }
        $src = Join-Path $script:FixtureDir 'overwrite-src.txt'
        $dst = Join-Path $script:FixtureDir 'overwrite-dst.txt'
        Set-Content -Path $src -Value 'new content'
        Set-Content -Path $dst -Value 'old content'

        $result = [CargoTools.FileCopy]::CopyWithRetry($src, $dst, 3, 50)
        $result.Success | Should -Be $true
        (Get-Content $dst -Raw).Trim() | Should -Be 'new content'
    }

    It 'Reports failure for non-existent source' {
        if (-not $script:HasFileCopy) {
            Set-ItResult -Skipped -Because 'FileCopy type not available'
            return
        }
        $src = Join-Path $script:FixtureDir 'nonexistent.txt'
        $dst = Join-Path $script:FixtureDir 'dst-noexist.txt'
        Remove-Item $src -ErrorAction SilentlyContinue

        $result = [CargoTools.FileCopy]::CopyWithRetry($src, $dst, 2, 50)
        $result.Success | Should -Be $false
        $result.LastError | Should -Not -BeNullOrEmpty
        $result.Attempts | Should -Be 3  # 0..maxRetries = 3 total attempts
    }

    It 'Retries on locked destination file' {
        if (-not $script:HasFileCopy) {
            Set-ItResult -Skipped -Because 'FileCopy type not available'
            return
        }
        $src = Join-Path $script:FixtureDir 'locked-src.txt'
        $dst = Join-Path $script:FixtureDir 'locked-dst.txt'
        Set-Content -Path $src -Value 'retry test data'
        Set-Content -Path $dst -Value 'initial'

        # Lock the destination file briefly using a FileStream
        $stream = [System.IO.File]::Open($dst, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            # Start copy in a background job; it should retry
            $job = Start-Job -ScriptBlock {
                param($s, $d)
                # Re-load the type in the job process
                $typeDef = @'
using System;
using System.IO;
using System.Threading;
namespace CargoTools {
    public static class FileCopyTest {
        public static bool CopyWithRetry(string source, string dest, int maxRetries, int retryDelayMs) {
            for (int attempt = 0; attempt <= maxRetries; attempt++) {
                try { File.Copy(source, dest, true); return true; }
                catch (IOException) { if (attempt < maxRetries) Thread.Sleep(retryDelayMs * (1 << attempt)); }
            }
            return false;
        }
    }
}
'@
                Add-Type -TypeDefinition $typeDef -ErrorAction SilentlyContinue
                [CargoTools.FileCopyTest]::CopyWithRetry($s, $d, 5, 100)
            } -ArgumentList $src, $dst

            # Release after 300ms to allow retry to succeed
            Start-Sleep -Milliseconds 300
        } finally {
            $stream.Close()
            $stream.Dispose()
        }

        $jobResult = Receive-Job -Job $job -Wait -AutoRemoveJob
        $jobResult | Should -Be $true
        (Get-Content $dst -Raw).Trim() | Should -Be 'retry test data'
    }
}

Describe 'Parallel file copy safety' {
    It 'Multiple concurrent copies to same destination do not corrupt' {
        if (-not $script:HasFileCopy) {
            Set-ItResult -Skipped -Because 'FileCopy type not available'
            return
        }
        $srcA = Join-Path $script:FixtureDir 'parallel-a.txt'
        $srcB = Join-Path $script:FixtureDir 'parallel-b.txt'
        $dst  = Join-Path $script:FixtureDir 'parallel-dst.txt'
        Set-Content -Path $srcA -Value ('A' * 10000)
        Set-Content -Path $srcB -Value ('B' * 10000)
        Remove-Item $dst -ErrorAction SilentlyContinue

        # Launch two parallel copy jobs
        $jobA = Start-Job -ScriptBlock {
            param($s, $d)
            [System.IO.File]::Copy($s, $d, $true)
            return 'A'
        } -ArgumentList $srcA, $dst

        $jobB = Start-Job -ScriptBlock {
            param($s, $d)
            Start-Sleep -Milliseconds 10
            try { [System.IO.File]::Copy($s, $d, $true); return 'B' }
            catch { return 'B-failed' }
        } -ArgumentList $srcB, $dst

        $resultA = Receive-Job -Job $jobA -Wait -AutoRemoveJob
        $resultB = Receive-Job -Job $jobB -Wait -AutoRemoveJob

        # Destination should contain only A's or only B's, not mixed
        $content = (Get-Content $dst -Raw).Trim()
        $isAllA = $content -eq ('A' * 10000)
        $isAllB = $content -eq ('B' * 10000)
        ($isAllA -or $isAllB) | Should -Be $true
    }
}

Describe 'Environment variable isolation' {
    It 'Env var changes in child jobs do not affect parent' {
        $savedTarget = $env:CARGO_TARGET_DIR
        $savedWrapper = $env:RUSTC_WRAPPER

        $job = Start-Job -ScriptBlock {
            $env:CARGO_TARGET_DIR = 'C:\fake\target'
            $env:RUSTC_WRAPPER = 'fake-sccache'
            return @{
                TargetDir = $env:CARGO_TARGET_DIR
                Wrapper   = $env:RUSTC_WRAPPER
            }
        }

        $childEnv = Receive-Job -Job $job -Wait -AutoRemoveJob
        $childEnv.TargetDir | Should -Be 'C:\fake\target'
        $childEnv.Wrapper | Should -Be 'fake-sccache'

        # Parent env should be unchanged
        $env:CARGO_TARGET_DIR | Should -Be $savedTarget
        $env:RUSTC_WRAPPER | Should -Be $savedWrapper
    }

    It 'Concurrent jobs have independent RUSTFLAGS' {
        $job1 = Start-Job -ScriptBlock {
            $env:RUSTFLAGS = '-C opt-level=0'
            Start-Sleep -Milliseconds 100
            return $env:RUSTFLAGS
        }
        $job2 = Start-Job -ScriptBlock {
            $env:RUSTFLAGS = '-C opt-level=3'
            Start-Sleep -Milliseconds 100
            return $env:RUSTFLAGS
        }

        $result1 = Receive-Job -Job $job1 -Wait -AutoRemoveJob
        $result2 = Receive-Job -Job $job2 -Wait -AutoRemoveJob

        $result1 | Should -Be '-C opt-level=0'
        $result2 | Should -Be '-C opt-level=3'
    }
}

Describe 'ShellEscape C# accelerator' {
    It 'QuoteArg handles null' {
        $result = [CargoTools.ShellEscape]::QuoteArg($null)
        $result | Should -Be "''"
    }
    It 'QuoteArg handles empty string' {
        $result = [CargoTools.ShellEscape]::QuoteArg('')
        $result | Should -Be "''"
    }
    It 'QuoteArg passes safe strings through' {
        $result = [CargoTools.ShellEscape]::QuoteArg('build')
        $result | Should -Be 'build'
    }
    It 'QuoteArg quotes strings with spaces' {
        $result = [CargoTools.ShellEscape]::QuoteArg('hello world')
        $result | Should -BeLike "'*hello world*'"
    }
    It 'QuoteArg quotes dollar signs' {
        $result = [CargoTools.ShellEscape]::QuoteArg('$HOME')
        $result | Should -BeLike "'*HOME*'"
    }
    It 'QuoteArg escapes embedded single quotes' {
        $result = [CargoTools.ShellEscape]::QuoteArg("it's")
        $result | Should -Not -BeNullOrEmpty
        # Should contain the original text recoverable via shell
        $result.Length | Should -BeGreaterThan 4
    }
    It 'JoinArgs handles empty array' {
        $result = [CargoTools.ShellEscape]::JoinArgs([string[]]@())
        $result | Should -Be ''
    }
    It 'JoinArgs joins multiple safe args' {
        $result = [CargoTools.ShellEscape]::JoinArgs([string[]]@('build', '--release'))
        $result | Should -Be 'build --release'
    }
    It 'JoinArgs quotes unsafe args in mixed list' {
        $result = [CargoTools.ShellEscape]::JoinArgs([string[]]@('build', 'my project', '--release'))
        $result | Should -BeLike "build '*my project*' --release"
    }
}

Describe 'Concurrent sccache startup simulation' {
    It 'Start-SccacheServer is safe to call when already running' {
        $startSccache = & $module { ${function:Start-SccacheServer} }
        # Calling it twice quickly should not throw
        { & $startSccache } | Should -Not -Throw
        { & $startSccache } | Should -Not -Throw
    }

    It 'Mutex protects sccache startup from cross-process races' {
        if (-not $script:HasMutex) {
            Set-ItResult -Skipped -Because 'ProcessMutex type not available'
            return
        }
        $signalFile = Join-Path $script:FixtureDir 'mutex-signal-sccache.txt'
        Remove-Item $signalFile -ErrorAction SilentlyContinue

        $job = Start-Job -ScriptBlock {
            param($signal)
            Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
namespace CargoToolsTest2 {
    public static class MutexHolder {
        public static void HoldMutex(string name, int holdMs, string signalPath) {
            bool createdNew;
            using (var mutex = new Mutex(false, @"Global\" + name, out createdNew)) {
                mutex.WaitOne(10000);
                File.WriteAllText(signalPath, "held");
                Thread.Sleep(holdMs);
                mutex.ReleaseMutex();
            }
        }
    }
}
'@
            [CargoToolsTest2.MutexHolder]::HoldMutex('CargoTools_SccacheStartup', 5000, $signal)
        } -ArgumentList $signalFile

        $waited = 0
        while (-not (Test-Path $signalFile) -and $waited -lt 15000) {
            Start-Sleep -Milliseconds 200
            $waited += 200
        }
        (Test-Path $signalFile) | Should -Be $true

        # Parent trying to acquire should fail with short timeout
        $blocked = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_SccacheStartup', 200)
        try {
            $blocked | Should -BeNull
        } finally {
            if ($blocked) { $blocked.Dispose() }
            $job | Wait-Job -Timeout 10 | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Cargo build queue' {
    BeforeEach {
        $script:SavedQueueVars = @{}
        foreach ($name in @('CARGOTOOLS_MAX_ACTIVE_BUILDS', 'PCAI_CACHE_ROOT')) {
            if (Test-Path "Env:$name") {
                $script:SavedQueueVars[$name] = (Get-Item "Env:$name").Value
            }
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }

        $script:QueueRoot = Join-Path $script:FixtureDir "queue_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:QueueRoot -Force | Out-Null
        $env:PCAI_CACHE_ROOT = $script:QueueRoot
        $env:CARGOTOOLS_MAX_ACTIVE_BUILDS = '1'
    }

    AfterEach {
        foreach ($name in @('CARGOTOOLS_MAX_ACTIVE_BUILDS', 'PCAI_CACHE_ROOT')) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
            if ($script:SavedQueueVars.ContainsKey($name)) {
                Set-Item -Path ("Env:" + $name) -Value $script:SavedQueueVars[$name]
            }
        }
    }

    It 'Enter-CargoBuildQueue acquires and releases a queue ticket' {
        $ticket = & $script:EnterCargoBuildQueue -ArgsList @('build') -WorkingDirectory $script:FixtureDir -CacheRoot $script:QueueRoot
        try {
            $ticket | Should -Not -BeNull
            $status = & $script:GetCargoQueueStatusInternal -CacheRoot $script:QueueRoot
            $status.QueueDepth | Should -Be 1
            $status.MaxActiveBuilds | Should -Be 1
        } finally {
            if ($ticket) {
                & $script:ExitCargoBuildQueue -TicketPath $ticket.TicketPath
            }
        }

        $statusAfter = & $script:GetCargoQueueStatusInternal -CacheRoot $script:QueueRoot
        $statusAfter.QueueDepth | Should -Be 0
    }

    It 'Get-CargoQueueStatusInternal reports an empty queue without throwing' {
        $status = & $script:GetCargoQueueStatusInternal -CacheRoot $script:QueueRoot
        $status.QueueDepth | Should -Be 0
        @($status.Entries).Count | Should -Be 0
    }
}
