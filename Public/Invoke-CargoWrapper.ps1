function Invoke-CargoWrapper {
<#
.SYNOPSIS
Centralized cargo wrapper with sccache and diagnostics support.
.DESCRIPTION
Sets sccache defaults, optional linkers, and runs preflight diagnostics before cargo builds.
.PARAMETER ArgumentList
Raw cargo arguments to pass through.
.EXAMPLE
Invoke-CargoWrapper --wrapper-help
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
        [string[]]$ArgumentList
    )

    $rawArgs = if ($ArgumentList) { @($ArgumentList) } else { @() }
    Write-CargoDebug "[DEBUG] Entry rawArgs: $($rawArgs -join '|')"

    if ($rawArgs -isnot [System.Array]) { $rawArgs = @($rawArgs) }
    $passThrough = New-Object System.Collections.Generic.List[string]
    $helpRequested = $false
    $wrapperOnly = $false
    $useLld = $null
    $useNative = $null
    $useFastlink = $null
    $llmDebug = $false
    $autoCopy = $null

    function Show-WrapperHelp {
        Write-Host 'cargo-wrapper.ps1 - Centralized Rust build wrapper' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  cargo [cargo-args]' -ForegroundColor Gray
        Write-Host '  cargo --help | -h              Show wrapper + cargo help' -ForegroundColor Gray
        Write-Host '  cargo --wrapper-help           Show wrapper help only' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Defaults enforced:' -ForegroundColor Yellow
        Write-Host '  - sccache enabled (RUSTC_WRAPPER=sccache)' -ForegroundColor Gray
        Write-Host '  - cache dir: T:\RustCache\sccache' -ForegroundColor Gray
        Write-Host '  - cargo target dir: T:\RustCache\cargo-target' -ForegroundColor Gray
        Write-Host '  - sccache port: 4226' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Optional accelerators (wrapper-only flags):' -ForegroundColor Yellow
        Write-Host '  --use-lld | --no-lld            Toggle lld-link (LLVM linker)' -ForegroundColor Gray
        Write-Host '  --use-native | --no-native      Toggle -C target-cpu=native' -ForegroundColor Gray
        Write-Host '  --fastlink | --no-fastlink      Toggle MSVC /DEBUG:FASTLINK' -ForegroundColor Gray
        Write-Host '  --llm-debug                     Enable LLM-friendly debug defaults' -ForegroundColor Gray
        Write-Host '  --preflight                     Run pre-build diagnostics (cargo check)' -ForegroundColor Gray
        Write-Host '  --preflight-mode <check|clippy|fmt|all>' -ForegroundColor Gray
        Write-Host '  --preflight-ra                  Run rust-analyzer diagnostics before build' -ForegroundColor Gray
        Write-Host '  --preflight-strict              Treat warnings as errors for clippy' -ForegroundColor Gray
        Write-Host '  --preflight-blocking            Fail build on preflight errors' -ForegroundColor Gray
        Write-Host '  --preflight-nonblocking         Continue build on preflight errors' -ForegroundColor Gray
        Write-Host '  --preflight-force               Force preflight even in IDE contexts' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Env toggles (for blank cargo invocations):' -ForegroundColor Yellow
        Write-Host '  CARGO_USE_LLD=1|0, CARGO_USE_NATIVE=1|0, CARGO_USE_FASTLINK=1|0' -ForegroundColor Gray
        Write-Host '  CARGO_LLD_PATH=C:\Program Files\LLVM\bin\lld-link.exe' -ForegroundColor Gray
        Write-Host '  CARGO_PREFLIGHT=1, CARGO_PREFLIGHT_MODE=check|clippy|fmt|all' -ForegroundColor Gray
        Write-Host '  CARGO_PREFLIGHT_STRICT=1, CARGO_RA_PREFLIGHT=1' -ForegroundColor Gray
        Write-Host '  CARGO_PREFLIGHT_BLOCKING=1      Fail build on preflight errors' -ForegroundColor Gray
        Write-Host '  CARGO_PREFLIGHT_IDE_GUARD=1     Disable preflight in IDE contexts' -ForegroundColor Gray
        Write-Host '  CARGO_PREFLIGHT_FORCE=1         Force preflight even in IDE contexts' -ForegroundColor Gray
        Write-Host '  RA_DIAGNOSTICS_FLAGS="--disable-build-scripts --disable-proc-macros"' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Common helpers:' -ForegroundColor Yellow
        Write-Host '  sccache --show-stats' -ForegroundColor Gray
        Write-Host '  sccache --zero-stats' -ForegroundColor Gray
        Write-Host '  sccache --stop-server' -ForegroundColor Gray
        Write-Host '  sccache --start-server' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Build output auto-copy:' -ForegroundColor Yellow
        Write-Host '  Executables are auto-copied to ./target/{profile}/ after builds' -ForegroundColor Gray
        Write-Host '  Disable with: $env:CARGO_AUTO_COPY=0' -ForegroundColor Gray
        Write-Host '  --no-auto-copy          Disable local output copy for this run' -ForegroundColor Gray
        Write-Host '  --auto-copy             Force local output copy for this run' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Verbosity control:' -ForegroundColor Yellow
        Write-Host '  -q, --quiet             Suppress non-error output' -ForegroundColor Gray
        Write-Host '  -v, --verbose           Show detailed progress and sccache stats' -ForegroundColor Gray
        Write-Host '  -vv, --debug            Show debug-level diagnostics' -ForegroundColor Gray
        Write-Host '  CARGO_VERBOSITY=0|1|2|3 Set via environment (0=quiet, 1=normal, 2=verbose, 3=debug)' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Docker/WSL helpers (if installed):' -ForegroundColor Yellow
        Write-Host '  cargo-docker [args...]    Run cargo inside Docker' -ForegroundColor Gray
        Write-Host '  cargo-wsl [args...]       Run cargo inside WSL' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Wrappers:' -ForegroundColor Yellow
        Write-Host '  PowerShell: cargo.ps1 (preferred) -> cargo-route.ps1' -ForegroundColor Gray
        Write-Host '  Direct wrapper: cargo-wrapper.ps1' -ForegroundColor Gray
        Write-Host '  cmd.exe: cargo.cmd / cargo.bat -> cargo.ps1 (pwsh)' -ForegroundColor Gray
        Write-Host ''
    }

    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $arg = $rawArgs[$i]
        switch ($arg) {
            '--wrapper-help' { $wrapperOnly = $true; continue }
            '--use-lld' { $useLld = $true; continue }
            '--lld' { $useLld = $true; continue }
            '--no-lld' { $useLld = $false; continue }
            '--use-native' { $useNative = $true; continue }
            '--no-native' { $useNative = $false; continue }
            '--fastlink' { $useFastlink = $true; continue }
            '--use-fastlink' { $useFastlink = $true; continue }
            '--no-fastlink' { $useFastlink = $false; continue }
            '--llm-debug' { $llmDebug = $true; continue }
            '--auto-copy' { $autoCopy = $true; continue }
            '--no-auto-copy' { $autoCopy = $false; continue }
            '--help' { $helpRequested = $true; $passThrough.Add($arg); continue }
            '-h' { $helpRequested = $true; $passThrough.Add($arg); continue }
            'help' { $helpRequested = $true; $passThrough.Add($arg); continue }
            default { $passThrough.Add($arg); continue }
        }
    }

    # Initialize verbosity from arguments
    $verbosity = Initialize-CargoVerbosity $passThrough.ToArray()
    $passThroughFiltered = @(Get-VerbosityArgs $passThrough.ToArray())
    $passThrough = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $passThroughFiltered) {
        if ($null -ne $arg) { $passThrough.Add([string]$arg) }
    }

    $primaryCmd = Get-PrimaryCommand $passThrough.ToArray()
    if ($primaryCmd -eq 'test') {
        $env:CARGO_RA_PREFLIGHT = '0'
    }

    $preflightSplit = Split-PreflightArgs $passThrough.ToArray()
    if (-not $preflightSplit) { return 1 }

    $passThrough = New-Object System.Collections.Generic.List[string]
    foreach ($arg in @($preflightSplit.Remaining)) {
        if ($null -ne $arg) { $passThrough.Add([string]$arg) }
    }
    $preflight = Apply-PreflightEnvDefaults $preflightSplit.State
    $preflight = Apply-PreflightIdeGuard $preflight

    if ($wrapperOnly -or $helpRequested) {
        Show-WrapperHelp
        if ($wrapperOnly -and -not $helpRequested) {
            return 0
        }
    }

    if ($llmDebug -or ($env:CARGO_LLM_DEBUG -and $env:CARGO_LLM_DEBUG -ne '0')) {
        $env:RUST_BACKTRACE = 'full'
        if (-not $env:CARGO_TERM_COLOR) { $env:CARGO_TERM_COLOR = 'always' }
        Add-RustFlags '-C debuginfo=1'
        Set-CargoVerbosity 3
    }

    # Environment setup phase
    Write-CargoBuildPhase -Phase 'Environment' -Starting
    Initialize-CargoEnv
    Write-CargoDebug "CARGO_TARGET_DIR: $env:CARGO_TARGET_DIR"
    Write-CargoDebug "SCCACHE_DIR: $env:SCCACHE_DIR"

    $lldPath = Resolve-LldLinker
    if ($null -eq $useLld) {
        if ($env:CARGO_USE_LLD) { $useLld = Test-Truthy $env:CARGO_USE_LLD }
        else { $useLld = $false }
    }

    $useLld = Apply-LinkerSettings -UseLld $useLld -LldPath $lldPath

    if ($null -eq $useNative) {
        if ($env:CARGO_USE_NATIVE) { $useNative = Test-Truthy $env:CARGO_USE_NATIVE }
        else { $useNative = $false }
    }
    Apply-NativeCpuFlag -UseNative $useNative

    if ($null -eq $useFastlink) {
        if ($env:CARGO_USE_FASTLINK) { $useFastlink = Test-Truthy $env:CARGO_USE_FASTLINK }
        else { $useFastlink = $false }
    }
    if ($useFastlink -and -not $useLld) { Add-RustFlags '-C link-arg=/DEBUG:FASTLINK' }

    Start-SccacheServer | Out-Null
    Write-CargoStatus -Phase 'Environment' -Message 'sccache server started' -Type 'Success' -MinVerbosity 2

    $rustupPath = Get-RustupPath
    if (Test-Path $rustupPath) {
        $buildStartTime = Get-Date

        try {
            # Preflight phase
            if ($preflight.Enabled) {
                Write-CargoBuildPhase -Phase 'Preflight' -Starting
                $preflightExit = Invoke-PreflightLocal -RustupPath $rustupPath -PassThroughArgs $passThrough.ToArray() -State $preflight
                if ($preflightExit -ne 0) {
                    Write-CargoBuildPhase -Phase 'Preflight' -Failed
                    if ($preflight.Blocking) {
                        Write-CargoStatus -Phase 'Preflight' -Message "Failed with exit code $preflightExit (blocking)" -Type 'Error'
                        return $preflightExit
                    }
                    Write-CargoStatus -Phase 'Preflight' -Message 'Failed (non-blocking, continuing)' -Type 'Warning'
                } else {
                    Write-CargoBuildPhase -Phase 'Preflight' -Complete
                }
            }

            # Rust-analyzer diagnostics
            if ($preflight.RA) {
                $raExit = Invoke-RaDiagnosticsLocal -State $preflight -PassThroughArgs $passThrough.ToArray()
                if ($raExit -ne 0 -and $preflight.Blocking) {
                    Write-CargoStatus -Phase 'Preflight' -Message 'rust-analyzer diagnostics failed (blocking)' -Type 'Error'
                    return $raExit
                }
            }

            # Build phase
            Write-CargoBuildPhase -Phase 'Build' -Starting
            $passThroughBuild = Ensure-RunArgSeparator $passThrough.ToArray()

            # TRACE: Log exactly what is being passed
            $traceBuild = @($passThroughBuild)
            Write-Host "  [TRACE] Argument Count: $($traceBuild.Count)" -ForegroundColor Cyan
            for ($i = 0; $i -lt $traceBuild.Count; $i++) {
                $arg = $traceBuild[$i]
                if ($null -eq $arg) {
                    Write-Host "  [TRACE] Arg[$i]: NULL" -ForegroundColor Red
                } else {
                    $hex = [BitConverter]::ToString([System.Text.Encoding]::UTF8.GetBytes($arg))
                    Write-Host "  [TRACE] Arg[$i]: '$arg' (Len: $($arg.Length), Hex: $hex)" -ForegroundColor Cyan
                }
            }

            Write-CargoStatus -Phase 'Build' -Message "Running: cargo $($traceBuild -join ' ')" -Type 'Info' -MinVerbosity 2

                        Write-CargoDebug "Executing: $rustupPath run stable cargo $($traceBuild -join ' ')"
            $primary = Get-PrimaryCommand $traceBuild
            if (@('build', 'check', 'test', 'run', 'clippy', 'bench') -contains $primary) {
                $diagnostics = Invoke-CargoWithJson -RustupPath $rustupPath -CargoArgs $traceBuild
                # Need to handle LASTEXITCODE manually if we want it here, but & inside Invoke-CargoWithJson sets it.
                $cargoExitCode = $LASTEXITCODE
            } else {
                & $rustupPath run stable cargo @traceBuild
                $cargoExitCode = $LASTEXITCODE
            }
            $cargoExitCode = $LASTEXITCODE
            $buildElapsed = (Get-Date) - $buildStartTime

            if ($cargoExitCode -ne 0) {
                Write-CargoBuildPhase -Phase 'Build' -Failed

                # Enhanced error diagnostics
                $diagnostics = Format-CargoDiagnostics -ExitCode $cargoExitCode -Command 'cargo' -Arguments $passThrough.ToArray() -StartTime $buildStartTime
                Write-Host $diagnostics -ForegroundColor Red

                # Show sccache stats on failure for debugging
                Show-SccacheStatus -Compact

                return $cargoExitCode
            }

            Write-CargoBuildPhase -Phase 'Build' -Complete
            Write-CargoStatus -Phase 'Build' -Message "Completed in $([Math]::Round($buildElapsed.TotalSeconds, 2))s" -Type 'Success' -MinVerbosity 2

            # Show sccache stats in verbose mode
            Show-SccacheStatus -Compact

            # Auto-copy phase
            $shouldAutoCopy = if ($null -ne $autoCopy) { $autoCopy } else { Test-AutoCopyEnabled }

            if ($shouldAutoCopy -and (Test-IsBuildCommand $primaryCmd)) {
                Write-CargoBuildPhase -Phase 'AutoCopy' -Starting
                $profile = Get-BuildProfile $passThrough.ToArray()
                $copied = Copy-BuildOutputToLocal -Profile $profile -ProjectRoot (Get-Location).Path
                if ($copied) {
                    Write-CargoBuildPhase -Phase 'AutoCopy' -Complete
                }
            }

            return $cargoExitCode
        } catch {
            Write-CargoBuildPhase -Phase 'Build' -Failed
            Write-Error "cargo wrapper failed: $($_.Exception.Message)"
            if ($_.ScriptStackTrace) {
                Write-Host "  [STACK] $($_.ScriptStackTrace)" -ForegroundColor DarkGray
            }

            # Enhanced error output
            $diagnostics = Format-CargoDiagnostics -ExitCode 1 -Command 'cargo' -Arguments $passThrough.ToArray() -StartTime $buildStartTime
            Write-Host $diagnostics -ForegroundColor Red

            Write-Host 'Try: rustup update stable' -ForegroundColor Yellow
            Write-Host 'Or run: cargo --version' -ForegroundColor Yellow
            return 1
        }
    }

    Write-Error "Error: rustup.exe not found at $rustupPath"
    Write-Host 'Install Rust using rustup or add rustup.exe to PATH.' -ForegroundColor Yellow
    return 1
}

