#Requires -Modules Pester

# Why this file exists: the documented build gate is
#   pwsh -NoLogo -NoProfile -c "Import-Module CargoTools -Force; Invoke-CargoWrapper check; ..."
# `pwsh -Command` derives the process exit code from `$?` (or an explicit `exit`), never from
# `$LASTEXITCODE`. Invoke-CargoWrapper used to publish the cargo exit code only through
# `$LASTEXITCODE` and its output stream, so a failing build or test run still exited 0 and the
# gate could not fail. These tests run the module in a CHILD pwsh process, which is the only
# place the process exit code can be observed, against real cargo invocations. The wrapper's
# in-process status contract is covered in Invoke-CargoWrapper.Contract.Tests.ps1.

BeforeDiscovery {
    # Only the external Rust toolchain is required. Skip (rather than fail) on a machine without
    # rustup, because a missing toolchain would make the wrapper exit non-zero for the wrong reason
    # and turn the failing-build assertions below into false positives.
    $modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1'
    $module = Import-Module $modulePath -Force -PassThru
    $rustupPath = & $module { Get-RustupPath }
    $script:hasRustup = [bool]($rustupPath -and (Test-Path -LiteralPath $rustupPath))
}

BeforeAll {
    $script:modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1'
    $script:pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
    $script:savedRustcWrapper = $env:RUSTC_WRAPPER
    $script:savedTargetDir = $env:CARGO_TARGET_DIR
    # Raw mode bypasses the wrapper's environment setup, so keep a stray sccache requirement and
    # the shared target directory out of the throwaway builds.
    $env:RUSTC_WRAPPER = ''
    $env:CARGO_TARGET_DIR = Join-Path $TestDrive 'target'

    function New-ThrowawayCrate {
        param([string]$Name, [string]$TestBody)
        $dir = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Join-Path $dir 'src') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'Cargo.toml') -Value "[package]`nname = `"$Name`"`nversion = `"0.1.0`"`nedition = `"2021`"`n"
        Set-Content -LiteralPath (Join-Path $dir 'src\lib.rs') -Value "#[test]`nfn probe() { $TestBody }`n"
        $dir
    }

    # Runs a command string in a fresh pwsh -Command process from $Directory and returns the
    # process exit code plus the merged output, the way an agent or CI step would see it.
    function Invoke-ChildPwsh {
        param([string]$Directory, [string]$Command)
        $ErrorActionPreference = 'Continue'
        Push-Location -LiteralPath $Directory
        try {
            $output = & $script:pwsh -NoLogo -NoProfile -NonInteractive -Command $Command 2>&1 | ForEach-Object { "$_" }
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = @($output) }
        } finally {
            Pop-Location
        }
    }

    $script:import = "Import-Module '$script:modulePath' -Force"
    $script:failingCrate = New-ThrowawayCrate -Name 'failing_crate' -TestBody 'assert!(false, "deliberate failure");'
    $script:passingCrate = New-ThrowawayCrate -Name 'passing_crate' -TestBody 'assert!(true);'
}

AfterAll {
    $env:RUSTC_WRAPPER = $script:savedRustcWrapper
    $env:CARGO_TARGET_DIR = $script:savedTargetDir
}

Describe 'Invoke-CargoWrapper process exit status' -Skip:(-not $script:hasRustup) {
    Context 'pwsh -Command reflects the cargo result' {
        It 'exits non-zero when a test fails' {
            $r = Invoke-ChildPwsh -Directory $script:failingCrate -Command "$script:import; Invoke-CargoWrapper --raw test"
            # Cargo reports a failing test as 101; the wrapper echoing it proves cargo (not a
            # missing toolchain) caused the failure.
            $r.Output | Should -Contain '101'
            $r.ExitCode | Should -Not -Be 0
        }

        It 'exits non-zero when the build fails' {
            $empty = Join-Path $TestDrive 'no_manifest'
            New-Item -ItemType Directory -Path $empty -Force | Out-Null
            $r = Invoke-ChildPwsh -Directory $empty -Command "$script:import; Invoke-CargoWrapper --raw build"
            $r.Output | Should -Contain '101'
            $r.ExitCode | Should -Not -Be 0
        }

        It 'exits zero when the tests pass (positive control)' {
            $r = Invoke-ChildPwsh -Directory $script:passingCrate -Command "$script:import; Invoke-CargoWrapper --raw test"
            ($r.Output -join "`n") | Should -Match 'test result: ok'
            $r.ExitCode | Should -Be 0
        }

        It 'lets "; exit $LASTEXITCODE" carry the exact cargo code' {
            $r = Invoke-ChildPwsh -Directory $script:failingCrate -Command "$script:import; Invoke-CargoWrapper --raw test; exit `$LASTEXITCODE"
            $r.ExitCode | Should -Be 101
        }
    }

    Context 'gate chains' {
        It 'does not run the second command after "&&" when the first fails' {
            $r = Invoke-ChildPwsh -Directory $script:failingCrate -Command "$script:import; Invoke-CargoWrapper --raw test && Write-Output 'SECOND-RAN'"
            ($r.Output -join "`n") | Should -Not -Match 'SECOND-RAN'
            $r.ExitCode | Should -Not -Be 0
        }

        It 'runs the second command after "&&" when the first passes (positive control)' {
            $r = Invoke-ChildPwsh -Directory $script:passingCrate -Command "$script:import; Invoke-CargoWrapper --raw test && Write-Output 'SECOND-RAN'"
            ($r.Output -join "`n") | Should -Match 'SECOND-RAN'
            $r.ExitCode | Should -Be 0
        }

        It 'documents that a plain ";" chain reflects only the LAST command' {
            # PowerShell, not the wrapper: -Command exits on the status of the final statement.
            # This is why docs/Invoke-CargoWrapper.md prescribes "&&" or an explicit exit check.
            $r = Invoke-ChildPwsh -Directory $script:failingCrate -Command "$script:import; Invoke-CargoWrapper --raw test; Write-Output 'SECOND-RAN'"
            ($r.Output -join "`n") | Should -Match 'SECOND-RAN'
            $r.ExitCode | Should -Be 0
        }
    }

    Context 'callers that set $ErrorActionPreference = Stop' {
        It 'still receives the exit code instead of an exception' {
            # cargo-wrapper.ps1 and cargo-route.ps1 run with Stop and read the returned code. Raw
            # mode also streams cargo's stdout to the pipeline, so the code is the last item.
            $cmd = "$script:import; `$ErrorActionPreference = 'Stop'; try { `$code = @(Invoke-CargoWrapper --raw test)[-1]; Write-Output `"CODE=`$code`" } catch { Write-Output 'THREW' }"
            $r = Invoke-ChildPwsh -Directory $script:failingCrate -Command $cmd
            ($r.Output -join "`n") | Should -Match 'CODE=101'
            ($r.Output -join "`n") | Should -Not -Match 'THREW'
        }

        It 'throws when the caller explicitly passes -ErrorAction Stop' {
            $cmd = "$script:import; try { Invoke-CargoWrapper --raw test -ErrorAction Stop | Out-Null; Write-Output 'NOTHROW' } catch { Write-Output 'THREW' }"
            $r = Invoke-ChildPwsh -Directory $script:failingCrate -Command $cmd
            ($r.Output -join "`n") | Should -Match 'THREW'
        }
    }
}
