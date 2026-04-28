function New-PreflightState {
    return [ordered]@{
        Enabled = $false
        Mode = $null
        Strict = $false
        RA = $false
        Blocking = $null
        IdeGuard = $true
        Force = $false
        JsonOutput = $false
    }
}

function Split-PreflightArgs {
    param([string[]]$InputArgs)
    $InputArgs = Normalize-ArgsList $InputArgs
    $state = New-PreflightState
    $remaining = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $InputArgs.Count; $i++) {
        $arg = $InputArgs[$i]
        switch ($arg) {
            '--preflight' { $state.Enabled = $true; continue }
            '--preflight-mode' {
                $i++
                if ($i -ge $InputArgs.Count) { Write-Error 'Missing value for --preflight-mode'; return $null }
                $state.Mode = $InputArgs[$i]
                $state.Enabled = $true
                continue
            }
            '--preflight-ra' { $state.RA = $true; continue }
            '--preflight-strict' { $state.Strict = $true; $state.Enabled = $true; continue }
            '--preflight-blocking' { $state.Blocking = $true; $state.Enabled = $true; continue }
            '--preflight-nonblocking' { $state.Blocking = $false; $state.Enabled = $true; continue }
            '--preflight-force' { $state.Force = $true; $state.Enabled = $true; continue }
            '--llm-output' { $state.JsonOutput = $true; continue }
            '--no-preflight' { $state.Enabled = $false; continue }
            default { $remaining.Add($arg); continue }
        }
    }

    return [pscustomobject]@{
        Remaining = $remaining.ToArray()
        State = $state
    }
}

function Apply-PreflightEnvDefaults {
    param([hashtable]$State)

    if (-not $State.Enabled -and $env:CARGO_PREFLIGHT -and $env:CARGO_PREFLIGHT -ne '0') {
        $State.Enabled = $true
    }
    if (-not $State.Mode -and $env:CARGO_PREFLIGHT_MODE) {
        $State.Mode = $env:CARGO_PREFLIGHT_MODE
    }
    if (-not $State.Strict -and $env:CARGO_PREFLIGHT_STRICT) {
        $State.Strict = Test-Truthy $env:CARGO_PREFLIGHT_STRICT
    }
    if (-not $State.RA -and $env:CARGO_RA_PREFLIGHT) {
        $State.RA = Test-Truthy $env:CARGO_RA_PREFLIGHT
    }
    if ($env:CARGO_PREFLIGHT_IDE_GUARD) {
        $State.IdeGuard = Test-Truthy $env:CARGO_PREFLIGHT_IDE_GUARD
    }
    if ($env:CARGO_PREFLIGHT_FORCE) {
        $State.Force = Test-Truthy $env:CARGO_PREFLIGHT_FORCE
    }
    if ($null -eq $State.Blocking) {
        if ($env:CARGO_PREFLIGHT_BLOCKING) { $State.Blocking = Test-Truthy $env:CARGO_PREFLIGHT_BLOCKING }
        else { $State.Blocking = $false }
    }
    if (-not $State.Mode) { $State.Mode = 'check' }

    # Mandatory quality-gate defaults (enabled unless explicitly disabled).
    # This enforces: autofix + lint + format checks before compilation.
    $enforceQuality = if ($env:CARGOTOOLS_ENFORCE_QUALITY) {
        Test-Truthy $env:CARGOTOOLS_ENFORCE_QUALITY
    } else {
        $true
    }
    if ($enforceQuality) {
        $State.Enabled = $true
        if ($env:CARGOTOOLS_PREFLIGHT_MODE) {
            $State.Mode = $env:CARGOTOOLS_PREFLIGHT_MODE
        } else {
            $State.Mode = 'all'
        }
        $State.Strict = $true
        $State.Blocking = $true
        $State.IdeGuard = $false
        $State.Force = $true
        if ($env:CARGOTOOLS_RA_PREFLIGHT) {
            $State.RA = Test-Truthy $env:CARGOTOOLS_RA_PREFLIGHT
        } else {
            $State.RA = $false
        }
    }

    return $State
}

function Apply-PreflightIdeGuard {
    param([hashtable]$State)

    if (-not $State.Enabled -and -not $State.RA) { return $State }
    if (-not $State.IdeGuard -or $State.Force) { return $State }

    $ideVars = @(
        'VSCODE_PID',
        'VSCODE_IPC_HOOK_CLI',
        'TERM_PROGRAM',
        'JETBRAINS_IDE',
        'IDEA_INITIAL_DIRECTORY',
        'RUST_ANALYZER_INTERNAL'
    )
    foreach ($ideVar in $ideVars) {
        $val = Get-EnvValue $ideVar
        if ($val) {
            if ($ideVar -eq 'TERM_PROGRAM' -and $val -ne 'vscode') { continue }
            Write-Host "Preflight suppressed in IDE context ($ideVar)." -ForegroundColor DarkYellow
            $State.Enabled = $false
            $State.RA = $false
            break
        }
    }

    return $State
}

function Invoke-PreflightLocal {
    param(
        [string]$RustupPath,
        [string]$Toolchain,
        [string[]]$PassThroughArgs,
        [hashtable]$State
    )

    if (-not $State.Enabled) { return 0 }
    if (-not $Toolchain) { $Toolchain = Resolve-CargoToolchain -RustupPath $RustupPath }

    $preflightArgs = Normalize-ArgsList (Strip-ArgsAfterDoubleDash $PassThroughArgs)
    $primary = Get-PrimaryCommand $preflightArgs
    if (-not $primary -or @('build','test','bench','run','check') -notcontains $primary) { return 0 }
    if ($primary -in @('test','run')) { return 0 }

    $preArgs = Normalize-ArgsList $preflightArgs
    if ($preArgs -isnot [System.Array]) { $preArgs = @($preArgs) }
    for ($j = 0; $j -lt $preArgs.Count; $j++) {
        if (-not $preArgs[$j].StartsWith('-') -and -not $preArgs[$j].StartsWith('+')) {
            $preArgs[$j] = $State.Mode
            break
        }
    }

    switch ($State.Mode) {
        'check' {
            $preArgs = Ensure-MessageFormatShort $preArgs
            & $RustupPath run $Toolchain cargo @preArgs
            if ($LASTEXITCODE -ne 0) {
                if ($State.Blocking) { return $LASTEXITCODE }
                Write-Warning 'Preflight check failed (non-blocking).'
            }
        }
        'clippy' {
            $preArgs = Ensure-MessageFormatShort $preArgs
            if ($State.Strict) { $preArgs += @('--', '-D', 'warnings') }
            & $RustupPath run $Toolchain cargo @preArgs
            if ($LASTEXITCODE -ne 0) {
                if ($State.Blocking) { return $LASTEXITCODE }
                Write-Warning 'Preflight clippy failed (non-blocking).'
            }
        }
        'fmt' {
            & $RustupPath run $Toolchain cargo fmt --all -- --check
            if ($LASTEXITCODE -ne 0) {
                if ($State.Blocking) { return $LASTEXITCODE }
                Write-Warning 'Preflight fmt failed (non-blocking).'
            }
        }
        'deny' {
            if (-not (Test-CargoCommand -Name 'cargo-deny')) {
                Write-Warning 'cargo-deny not found; skipping. Install: cargo install cargo-deny'
                return 0
            }
            & $RustupPath run $Toolchain cargo deny check 2>&1
            if ($LASTEXITCODE -ne 0) {
                if ($State.Blocking) { return $LASTEXITCODE }
                Write-Warning 'Preflight deny check failed (non-blocking).'
            }
        }
        'all' {
            $checkArgs = Normalize-ArgsList $preflightArgs
            if ($checkArgs -isnot [System.Array]) { $checkArgs = @($checkArgs) }
            for ($k = 0; $k -lt $checkArgs.Count; $k++) {
                if (-not $checkArgs[$k].StartsWith('-') -and -not $checkArgs[$k].StartsWith('+')) {
                    $checkArgs[$k] = 'check'
                    break
                }
            }
            $checkArgs = Ensure-MessageFormatShort $checkArgs
            & $RustupPath run $Toolchain cargo @checkArgs
            if ($LASTEXITCODE -ne 0) {
                if ($State.Blocking) { return $LASTEXITCODE }
                Write-Warning 'Preflight check failed (non-blocking).'
            }

            $clippyArgs = Normalize-ArgsList $preflightArgs
            if ($clippyArgs -isnot [System.Array]) { $clippyArgs = @($clippyArgs) }
            for ($k = 0; $k -lt $clippyArgs.Count; $k++) {
                if (-not $clippyArgs[$k].StartsWith('-') -and -not $clippyArgs[$k].StartsWith('+')) {
                    $clippyArgs[$k] = 'clippy'
                    break
                }
            }
            $clippyArgs = Ensure-MessageFormatShort $clippyArgs
            if ($State.Strict) { $clippyArgs += @('--', '-D', 'warnings') }
            & $RustupPath run $Toolchain cargo @clippyArgs
            if ($LASTEXITCODE -ne 0) {
                if ($State.Blocking) { return $LASTEXITCODE }
                Write-Warning 'Preflight clippy failed (non-blocking).'
            }

            & $RustupPath run $Toolchain cargo fmt --all -- --check
            if ($LASTEXITCODE -ne 0) {
                if ($State.Blocking) { return $LASTEXITCODE }
                Write-Warning 'Preflight fmt failed (non-blocking).'
            }

            # Optional deny check in 'all' mode (off by default).
            if ($env:CARGOTOOLS_ENABLE_DENY -and (Test-Truthy $env:CARGOTOOLS_ENABLE_DENY)) {
                if (Test-CargoCommand -Name 'cargo-deny') {
                    & $RustupPath run $Toolchain cargo deny check 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        if ($State.Blocking) { return $LASTEXITCODE }
                        Write-Warning 'Preflight deny check failed (non-blocking).'
                    }
                }
            }
        }
        default {
            Write-Warning "Unknown preflight mode '$($State.Mode)'. Skipping preflight."
        }
    }

    return 0
}

function Invoke-RaDiagnosticsLocal {
    param(
        [hashtable]$State,
        [string[]]$PassThroughArgs
    )

    if (-not $State.RA) { return 0 }

    $raArgs = Strip-ArgsAfterDoubleDash $PassThroughArgs
    $primary = Get-PrimaryCommand $raArgs
    if (-not $primary -or @('build','test','bench','check') -notcontains $primary) { return 0 }

    $raPath = Resolve-RustAnalyzerPath
    if (-not $raPath) {
        Write-Warning 'rust-analyzer not found; skipping RA diagnostics preflight.'
        return 0
    }

    $raFlags = @()
    if ($env:RA_DIAGNOSTICS_FLAGS) {
        $raFlags = $env:RA_DIAGNOSTICS_FLAGS -split '\s+' | Where-Object { $_ }
    }

    if ($State.JsonOutput) {
        $cacheDir = Join-Path "." ".cache"
        if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory $cacheDir -ErrorAction SilentlyContinue | Out-Null }
        $outputPath = Join-Path $cacheDir "ra-diagnostics.json"
        
        Write-CargoStatus -Phase 'Preflight' -Message "Exporting RA diagnostics to $outputPath..." -Type 'Info'
        # Run RA and filter out the noisy internal logs
        & $raPath diagnostics '.' @raFlags 2>&1 |
            Where-Object { $_ -notmatch 'ERROR inference diagnostic in desugared expr' } |
            Out-File -FilePath $outputPath -Encoding utf8
    } else {
        & $raPath diagnostics '.' @raFlags 2>&1 |
            Where-Object { $_ -notmatch 'ERROR inference diagnostic in desugared expr' }
    }
    if ($LASTEXITCODE -ne 0) {
        if ($State.Blocking) { return $LASTEXITCODE }
        Write-Warning 'Preflight rust-analyzer diagnostics failed (non-blocking).'
    }

    return 0
}

function Build-PreflightShellCommand {
    param(
        [string[]]$Args,
        [hashtable]$State,
        [switch]$UseShellEscaping
    )

    if (-not $State.Enabled) { return '' }

    $preflightArgs = Strip-ArgsAfterDoubleDash $Args
    $primary = Get-PrimaryCommand $preflightArgs
    if (-not $primary -or @('build','test','bench','run','check') -notcontains $primary) { return '' }
    if ($primary -eq 'run') { return '' }

    $preArgs = $preflightArgs
    for ($j = 0; $j -lt $preArgs.Count; $j++) {
        if (-not $preArgs[$j].StartsWith('-') -and -not $preArgs[$j].StartsWith('+')) {
            $preArgs[$j] = $State.Mode
            break
        }
    }

    $fmtArgs = $null
    switch ($State.Mode) {
        'check' { $preArgs = Ensure-MessageFormatShort $preArgs }
        'clippy' {
            $preArgs = Ensure-MessageFormatShort $preArgs
            if ($State.Strict) { $preArgs += @('--', '-D', 'warnings') }
        }
        'fmt' { $fmtArgs = @('fmt','--all','--','--check') }
        'deny' {
            if ($UseShellEscaping) {
                if ($State.Blocking) {
                    return "command -v cargo-deny >/dev/null 2>&1 && cargo deny check && "
                }
                return "command -v cargo-deny >/dev/null 2>&1 && { cargo deny check || echo 'Preflight deny check failed (non-blocking).'; }; "
            }
            if ($State.Blocking) {
                return 'cargo deny check && '
            }
            return "if ! cargo deny check; then echo 'Preflight deny check failed (non-blocking).'; fi; "
        }
        'all' {
            $checkArgs = $preflightArgs
            for ($k = 0; $k -lt $checkArgs.Count; $k++) {
                if (-not $checkArgs[$k].StartsWith('-') -and -not $checkArgs[$k].StartsWith('+')) {
                    $checkArgs[$k] = 'check'
                    break
                }
            }
            $checkArgs = Ensure-MessageFormatShort $checkArgs

            $clippyArgs = $preflightArgs
            for ($k = 0; $k -lt $clippyArgs.Count; $k++) {
                if (-not $clippyArgs[$k].StartsWith('-') -and -not $clippyArgs[$k].StartsWith('+')) {
                    $clippyArgs[$k] = 'clippy'
                    break
                }
            }
            $clippyArgs = Ensure-MessageFormatShort $clippyArgs
            if ($State.Strict) { $clippyArgs += @('--', '-D', 'warnings') }

            if ($UseShellEscaping) {
                if ($State.Blocking) {
                    return "cargo $(Convert-ArgsToShell $checkArgs) && cargo $(Convert-ArgsToShell $clippyArgs) && cargo fmt --all -- --check && "
                }
                return "if ! cargo $(Convert-ArgsToShell $checkArgs); then echo 'Preflight check failed (non-blocking).'; fi; " +
                       "if ! cargo $(Convert-ArgsToShell $clippyArgs); then echo 'Preflight clippy failed (non-blocking).'; fi; " +
                       "if ! cargo fmt --all -- --check; then echo 'Preflight fmt failed (non-blocking).'; fi; "
            }

            if ($State.Blocking) {
                return "cargo $($checkArgs -join ' ') && cargo $($clippyArgs -join ' ') && cargo fmt --all -- --check && "
            }
            return "if ! cargo $($checkArgs -join ' '); then echo 'Preflight check failed (non-blocking).'; fi; " +
                   "if ! cargo $($clippyArgs -join ' '); then echo 'Preflight clippy failed (non-blocking).'; fi; " +
                   "if ! cargo fmt --all -- --check; then echo 'Preflight fmt failed (non-blocking).'; fi; "
        }
        default { return '' }
    }

    if ($fmtArgs) {
        if ($State.Blocking) { return 'cargo fmt --all -- --check && ' }
        return "if ! cargo fmt --all -- --check; then echo 'Preflight fmt failed (non-blocking).'; fi; "
    }

    if ($UseShellEscaping) {
        if ($State.Blocking) {
            return "cargo $(Convert-ArgsToShell $preArgs) && "
        }
        $label = if ($State.Mode -eq 'clippy') { 'clippy' } else { 'check' }
        return "if ! cargo $(Convert-ArgsToShell $preArgs); then echo 'Preflight $label failed (non-blocking).'; fi; "
    }

    if ($State.Blocking) {
        return "cargo $($preArgs -join ' ') && "
    }
    $label = if ($State.Mode -eq 'clippy') { 'clippy' } else { 'check' }
    return "if ! cargo $($preArgs -join ' '); then echo 'Preflight $label failed (non-blocking).'; fi; "
}

function Build-RaDiagnosticsShellCommand {
    param(
        [string]$WorkDir,
        [string[]]$Args,
        [hashtable]$State
    )

    if (-not $State.RA) { return '' }

    $preflightArgs = Strip-ArgsAfterDoubleDash $Args
    $primary = Get-PrimaryCommand $preflightArgs
    if (-not $primary -or @('build','test','bench','check') -notcontains $primary) { return '' }

    $raFlags = $env:RA_DIAGNOSTICS_FLAGS
    if ([string]::IsNullOrWhiteSpace($raFlags)) { $raFlags = '' }

    if ($State.Blocking) {
        return "command -v rust-analyzer >/dev/null 2>&1 && rust-analyzer diagnostics '$WorkDir' $raFlags && "
    }
    return "command -v rust-analyzer >/dev/null 2>&1 && rust-analyzer diagnostics '$WorkDir' $raFlags || echo 'Preflight rust-analyzer diagnostics failed (non-blocking).'; "
}


