#Requires -Version 5.1
# _WrapperHelpers.psm1 — CargoTools v0.9.0 shared wrapper logic
# Exported by all cargo/maturin/rust-analyzer wrappers.
# PS5.1 + Core compatible: no ??, no ?., no ternary ?:

$script:WrapperVersion = '0.9.0'

# --------------------------------------------------------------------------
# Internal: resolve .psd1 path for version reading
# --------------------------------------------------------------------------
function Get-CargoToolsPsd1Path {
    $candidates = @(
        $env:CARGOTOOLS_MANIFEST,
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules\CargoTools\CargoTools.psd1'),
        (Join-Path $env:LOCALAPPDATA 'PowerShell\Modules\CargoTools\CargoTools.psd1'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\Modules\CargoTools\CargoTools.psd1')
    ) | Where-Object { $_ }
    foreach ($c in $candidates) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

# --------------------------------------------------------------------------
# Get-CargoToolsVersion
# --------------------------------------------------------------------------
function Get-CargoToolsVersion {
    $psd1 = Get-CargoToolsPsd1Path
    if ($psd1) {
        try {
            $data = Import-PowerShellDataFile -Path $psd1 -ErrorAction SilentlyContinue
            if ($data -and $data.ModuleVersion) { return $data.ModuleVersion }
        } catch {}
    }
    return $script:WrapperVersion
}

# --------------------------------------------------------------------------
# Write-LlmEvent  — emits JSON to stderr; no-op when $EmitLlm is false
# --------------------------------------------------------------------------
function Write-LlmEvent {
    param(
        [Parameter(Mandatory)] [string]$Phase,
        [string]$Wrapper = '',
        [string[]]$Args = @(),
        [int]$ExitCode = 0,
        [int]$DurationMs = 0,
        [string]$Level = '',
        [string]$Code = '',
        [string]$Detail = '',
        [string]$Recovery = '',
        [string]$ActionName = '',
        [string[]]$ActionsTaken = @(),
        [bool]$EmitLlm = $false
    )
    if (-not $EmitLlm) { return }

    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $ver = Get-CargoToolsVersion

    $obj = [ordered]@{ phase = $Phase; timestamp = $ts }

    if ($Wrapper)      { $obj['wrapper']         = $Wrapper }
    if ($ver)          { $obj['wrapper_version']  = $ver }

    switch ($Phase) {
        'start' {
            $obj['args'] = $Args
        }
        'diagnostic' {
            if ($Level)    { $obj['level']    = $Level }
            if ($Code)     { $obj['code']     = $Code }
            if ($Detail)   { $obj['detail']   = $Detail }
            if ($Recovery) { $obj['recovery'] = $Recovery }
        }
        'action' {
            if ($ActionName) { $obj['name']   = $ActionName }
            if ($Detail)     { $obj['detail'] = $Detail }
        }
        'end' {
            $obj['exit_code']    = $ExitCode
            $obj['duration_ms']  = $DurationMs
            $obj['actions_taken'] = $ActionsTaken
        }
    }

    $json = $obj | ConvertTo-Json -Compress
    [Console]::Error.WriteLine($json)
}

# --------------------------------------------------------------------------
# Get-WrapperContext  — parse wrapper flags out of raw arg list
# Returns PSCustomObject with all flag booleans + PassThrough array
# --------------------------------------------------------------------------
function Get-WrapperContext {
    param(
        [string[]]$InvocationArgs,
        [string]$WrapperName = 'cargo'
    )

    $passThrough      = [System.Collections.Generic.List[string]]::new()
    $helpRequested    = $false
    $versionRequested = $false
    $doctorRequested  = $false
    $diagnoseRequested = $false
    $llmMode          = $false
    $listRequested    = $false
    $noWrapper        = $false

    if (-not $InvocationArgs) { $InvocationArgs = @() }

    for ($i = 0; $i -lt $InvocationArgs.Count; $i++) {
        $arg = $InvocationArgs[$i]
        switch ($arg) {
            '--help'          { $helpRequested    = $true }
            '-h'              { $helpRequested    = $true }
            '-?'              { $helpRequested    = $true }
            '/?'              { $helpRequested    = $true }
            '--version'       { $versionRequested = $true }
            '--doctor'        { $doctorRequested  = $true }
            '--diagnose'      { $diagnoseRequested = $true; $doctorRequested = $true; $llmMode = $true }
            '--llm'           { $llmMode          = $true }
            '--json-output'   { $llmMode          = $true }
            '--list-wrappers' { $listRequested    = $true }
            '--no-wrapper'    { $noWrapper        = $true }
            default           { $passThrough.Add($arg) }
        }
    }

    return [PSCustomObject]@{
        WrapperName       = $WrapperName
        PassThrough       = $passThrough.ToArray()
        HelpRequested     = $helpRequested
        VersionRequested  = $versionRequested
        DoctorRequested   = $doctorRequested
        DiagnoseRequested = $diagnoseRequested
        LlmMode           = $llmMode
        ListRequested     = $listRequested
        NoWrapper         = $noWrapper
    }
}

# --------------------------------------------------------------------------
# Resolve-Subcommand  — returns first non-flag arg (likely cargo subcommand)
# --------------------------------------------------------------------------
function Resolve-Subcommand {
    param([string[]]$ArgList)
    if (-not $ArgList) { return $null }
    foreach ($a in $ArgList) {
        if (-not $a.StartsWith('-')) { return $a }
    }
    return $null
}

# --------------------------------------------------------------------------
# Import-CargoToolsResilient
# Returns $true on success, writes diagnostics, exits on fatal errors.
# --------------------------------------------------------------------------
function Import-CargoToolsResilient {
    param([bool]$EmitLlm = $false)

    # Already loaded?
    if (Get-Module CargoTools -ErrorAction SilentlyContinue) { return $true }

    $candidates = @(
        $env:CARGOTOOLS_MANIFEST,
        (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1'),
        (Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules\CargoTools\CargoTools.psd1'),
        (Join-Path $env:LOCALAPPDATA 'PowerShell\Modules\CargoTools\CargoTools.psd1'),
        (Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\Modules\CargoTools\CargoTools.psd1')
    ) | Where-Object { $_ } | Select-Object -Unique

    $tried = [System.Collections.Generic.List[string]]::new()
    $loaded = $false
    $oneDriveLock = $false

    foreach ($path in $candidates) {
        if (-not (Test-Path $path -ErrorAction SilentlyContinue)) { continue }
        $tried.Add($path)

        # Detect OneDrive paths
        $isOneDrive = $path -like '*\OneDrive\*'

        $maxRetries = if ($isOneDrive) { 3 } else { 1 }
        for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
            try {
                Import-Module $path -ErrorAction Stop
                $loaded = $true

                if ($attempt -gt 1) {
                    Write-LlmEvent -Phase diagnostic -Level warn -Code ONEDRIVE_LOCK `
                        -Detail "Module loaded after $attempt attempts (OneDrive sync retry)" `
                        -EmitLlm:$EmitLlm
                    Write-Host '[WARN] CargoTools module loaded after OneDrive sync retry.' -ForegroundColor Yellow
                }
                break
            } catch {
                $errMsg = $_.Exception.Message
                $isLock = $errMsg -match 'in use|access denied|sharing violation' -or
                          $errMsg -match 'locked|cannot access'

                if ($isOneDrive -and $isLock -and $attempt -lt $maxRetries) {
                    $oneDriveLock = $true
                    Start-Sleep -Milliseconds 200
                    continue
                }

                if ($oneDriveLock -and $attempt -ge $maxRetries) {
                    Write-LlmEvent -Phase diagnostic -Level error -Code ONEDRIVE_LOCK `
                        -Detail "Module at '$path' is locked by OneDrive after $maxRetries attempts" `
                        -Recovery "Pause OneDrive sync or run: attrib -p `"$path`"" `
                        -EmitLlm:$EmitLlm
                    Write-Host "[ERROR] OneDrive lock on $path — pause sync or run: attrib -p `"$path`"" -ForegroundColor Red
                }
                break
            }
        }
        if ($loaded) { break }
    }

    # Last resort: Import-Module by name
    if (-not $loaded) {
        try {
            Import-Module CargoTools -ErrorAction Stop
            $loaded = $true
        } catch {}
    }

    if (-not $loaded) {
        $triedList = if ($tried.Count -gt 0) { $tried -join ', ' } else { '(none found)' }
        Write-LlmEvent -Phase diagnostic -Level error -Code MODULE_NOT_FOUND `
            -Detail "CargoTools module not found. Tried: $triedList" `
            -Recovery 'Install CargoTools or set $env:CARGOTOOLS_MANIFEST to the .psd1 path' `
            -EmitLlm:$EmitLlm
        Write-Host "[ERROR] MODULE_NOT_FOUND: CargoTools not found. Tried: $triedList" -ForegroundColor Red
        Write-Host '[ERROR] Recovery: Install CargoTools or set $env:CARGOTOOLS_MANIFEST' -ForegroundColor Red
        return $false
    }

    # PATH_SHADOWED check (advisory)
    _Test-PathShadowed -EmitLlm:$EmitLlm

    # RUSTUP check
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if (-not $rustup) {
        Write-LlmEvent -Phase diagnostic -Level error -Code RUSTUP_NOT_FOUND `
            -Detail 'rustup not found on PATH' `
            -Recovery 'Install from https://rustup.rs/' `
            -EmitLlm:$EmitLlm
        Write-Host '[ERROR] RUSTUP_NOT_FOUND: Install rustup from https://rustup.rs/' -ForegroundColor Red
        exit 3
    }

    return $true
}

# --------------------------------------------------------------------------
# Internal: PATH_SHADOWED advisory
# --------------------------------------------------------------------------
function _Test-PathShadowed {
    param([bool]$EmitLlm = $false)
    try {
        $mod = Get-Module CargoTools -ErrorAction SilentlyContinue
        if (-not $mod) { return }
        $getSanitized = & $mod { ${function:Get-SanitizedPath} }
        if (-not $getSanitized) { return }
        $sanitized = & $getSanitized -Path $env:PATH
        if ($sanitized -eq $env:PATH) { return }

        # Find removed entries
        $current = $env:PATH -split ';' | Where-Object { $_ }
        $clean   = $sanitized -split ';' | Where-Object { $_ }
        $stripped = $current | Where-Object { $clean -notcontains $_ }
        if ($stripped.Count -gt 0) {
            $detail = 'PATH entries stripped during build: ' + ($stripped -join '; ')
            Write-LlmEvent -Phase diagnostic -Level warn -Code PATH_SHADOWED `
                -Detail $detail -EmitLlm:$EmitLlm
        }
    } catch {}
}

# --------------------------------------------------------------------------
# _Check-StaleMutex  — advisory only
# --------------------------------------------------------------------------
function _Check-StaleMutex {
    param([bool]$EmitLlm = $false)
    try {
        $mutexNames = @('CargoTools.Sccache', 'CargoTools.RustAnalyzer')
        foreach ($name in $mutexNames) {
            $h = [System.Threading.Mutex]::OpenExisting($name)
            if ($h) {
                # If we can open it, it exists — can't reliably detect age from PS5
                # Emit advisory only
                Write-LlmEvent -Phase diagnostic -Level warn -Code STALE_MUTEX `
                    -Detail "Mutex '$name' is held — possible concurrent CargoTools process" `
                    -EmitLlm:$EmitLlm
                $h.Dispose()
            }
        }
    } catch {}
}

# --------------------------------------------------------------------------
# Show-WrapperHelp
# --------------------------------------------------------------------------
function Show-WrapperHelp {
    param(
        [string]$WrapperName = 'cargo',
        [string[]]$RemainingArgs = @()
    )

    $ver = Get-CargoToolsVersion

    # If a cargo subcommand is in RemainingArgs, run cargo help <subcmd>
    $subcmd = Resolve-Subcommand -ArgList $RemainingArgs
    if ($subcmd -and (Get-Command rustup -ErrorAction SilentlyContinue)) {
        Write-Host ''
        Write-Host "--- cargo help $subcmd ---" -ForegroundColor Cyan
        & rustup run stable cargo help $subcmd 2>&1
        Write-Host ''
    }

    Write-Host "CargoTools Wrapper: $WrapperName (v$ver)" -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'WRAPPER FLAGS (consumed before forwarding to cargo):' -ForegroundColor White
    Write-Host '  --help, -h, -?, /?       Print this help message' -ForegroundColor Gray
    Write-Host '  --version                Print wrapper + cargo + rustc versions' -ForegroundColor Gray
    Write-Host '  --doctor                 Run build environment diagnostics' -ForegroundColor Gray
    Write-Host '  --diagnose               Same as --doctor but JSON output only' -ForegroundColor Gray
    Write-Host '  --llm, --json-output     Emit JSON envelope events on stderr' -ForegroundColor Gray
    Write-Host '  --list-wrappers          List CargoTools wrappers found on PATH' -ForegroundColor Gray
    Write-Host '  --no-wrapper             Bypass module; run bare rustup run stable cargo' -ForegroundColor Gray
    Write-Host ''
    Write-Host 'ENVIRONMENT VARIABLES:' -ForegroundColor White
    Write-Host '  CARGOTOOLS_MANIFEST      Override path to CargoTools.psd1' -ForegroundColor Gray
    Write-Host '  CARGO_RAW=1              Bypass all wrapper behavior (same as --no-wrapper)' -ForegroundColor Gray
    Write-Host '  CARGO_ROUTE_DEFAULT      Routing: auto|windows|wsl|docker' -ForegroundColor Gray
    Write-Host '  CARGO_ROUTE_WASM         Route for wasm32 targets' -ForegroundColor Gray
    Write-Host '  CARGO_ROUTE_MACOS        Route for apple targets' -ForegroundColor Gray
    Write-Host '  CARGO_ROUTE_DISABLE      Disable routing, use direct wrapper' -ForegroundColor Gray
    Write-Host '  CARGO_WSL_CACHE          WSL cache mode: shared|native' -ForegroundColor Gray
    Write-Host '  CARGO_WSL_SCCACHE        Enable sccache in WSL builds' -ForegroundColor Gray
    Write-Host '  CARGO_DOCKER_SCCACHE     Enable sccache in Docker builds' -ForegroundColor Gray
    Write-Host '  CARGO_DOCKER_ZIGBUILD    Use zigbuild in Docker' -ForegroundColor Gray
    Write-Host '  CARGO_PREFLIGHT          Enable/disable preflight checks' -ForegroundColor Gray
    Write-Host '  CARGO_PREFLIGHT_MODE     check|clippy|fmt|deny|all' -ForegroundColor Gray
    Write-Host '  CARGO_PREFLIGHT_STRICT   Fail build on preflight warning' -ForegroundColor Gray
    Write-Host '  CARGO_USE_LLD            Force lld-link linker' -ForegroundColor Gray
    Write-Host '  CARGO_USE_NEXTEST        Enable cargo-nextest' -ForegroundColor Gray
    Write-Host '  CARGO_AUTO_COPY          Copy build outputs to local target/' -ForegroundColor Gray
    Write-Host '  CARGO_VERBOSITY          0-3 or llm — controls output detail' -ForegroundColor Gray
    Write-Host '  CARGO_QUICK_CHECK=1      Rewrite build to check (no binary)' -ForegroundColor Gray
    Write-Host '  CARGO_TIMINGS=1          HTML build timing report' -ForegroundColor Gray
    Write-Host '  CARGO_RELEASE_LTO=1      Thin LTO + codegen-units=1' -ForegroundColor Gray
    Write-Host '  RA_MEMORY_LIMIT_MB       Kill rust-analyzer if memory exceeds MB' -ForegroundColor Gray
    Write-Host ''
    Write-Host "All other flags are forwarded to cargo unchanged." -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# Show-WrapperVersion
# --------------------------------------------------------------------------
function Show-WrapperVersion {
    param([string]$WrapperName = 'cargo')

    $ver = Get-CargoToolsVersion
    Write-Host "CargoTools wrapper/$WrapperName v$ver"

    if (Get-Command rustup -ErrorAction SilentlyContinue) {
        $cargoVer = & rustup run stable cargo --version 2>&1
        if ($cargoVer) { Write-Host $cargoVer }
        $rustcVer = & rustup run stable rustc --version 2>&1
        if ($rustcVer) { Write-Host $rustcVer }
    } else {
        Write-Host '[WARN] rustup not on PATH — cannot query cargo/rustc versions' -ForegroundColor Yellow
    }
}

# --------------------------------------------------------------------------
# Invoke-WrapperDoctor
# --------------------------------------------------------------------------
function Invoke-WrapperDoctor {
    param(
        [string]$WrapperName = 'cargo',
        [bool]$AsJson = $false
    )

    $issues = [System.Collections.Generic.List[string]]::new()
    $checks = [ordered]@{}

    # 1. Module loadable?
    $modLoaded = $false
    if (Get-Module CargoTools -ErrorAction SilentlyContinue) {
        $modLoaded = $true
    } else {
        $psd1 = Get-CargoToolsPsd1Path
        if ($psd1) {
            try {
                Import-Module $psd1 -ErrorAction Stop
                $modLoaded = $true
            } catch {}
        }
    }
    $checks['CargoTools module'] = if ($modLoaded) { '[OK] loaded' } else { '[ERROR] not loadable' }
    if (-not $modLoaded) { $issues.Add('CargoTools module not loadable') }

    # 2. PSModulePath contains CargoTools?
    $modPath = $env:PSModulePath -split ';' | Where-Object {
        Test-Path (Join-Path $_ 'CargoTools\CargoTools.psd1') -ErrorAction SilentlyContinue
    }
    $checks['PSModulePath'] = if ($modPath) { "[OK] $($modPath[0])" } else { '[WARN] CargoTools not in PSModulePath' }
    if (-not $modPath) { $issues.Add('CargoTools directory not on PSModulePath') }

    # 3. Wrapper locations
    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    $userBin  = Join-Path $env:USERPROFILE 'bin'
    foreach ($dir in @($localBin, $userBin)) {
        $key = "Wrappers in $dir"
        $ps1 = Join-Path $dir 'cargo.ps1'
        if (Test-Path $ps1) {
            $checks[$key] = '[OK] deployed'
        } else {
            $checks[$key] = '[WARN] not found (run Install-Wrappers.ps1)'
            $issues.Add("cargo.ps1 not found in $dir")
        }
    }

    # 4. PATH contains wrapper dirs?
    $pathEntries = $env:PATH -split ';'
    foreach ($dir in @($localBin, $userBin)) {
        $key = "PATH includes $dir"
        $inPath = $pathEntries | Where-Object { $_.TrimEnd('\') -eq $dir.TrimEnd('\') }
        $checks[$key] = if ($inPath) { '[OK]' } else { '[WARN] not in PATH' }
        if (-not $inPath) { $issues.Add("$dir not in PATH") }
    }

    # 5. rustup
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    $checks['rustup'] = if ($rustup) { "[OK] $($rustup.Source)" } else { '[ERROR] not found' }
    if (-not $rustup) { $issues.Add('rustup not on PATH') }

    # 6. sccache running?
    $sccache = Get-Command sccache -ErrorAction SilentlyContinue
    if ($sccache) {
        try {
            $stats = & sccache --show-stats 2>&1
            $running = $stats -match 'Cache hits'
            $checks['sccache'] = if ($running) { '[OK] running' } else { '[WARN] installed but not running' }
        } catch {
            $checks['sccache'] = '[WARN] installed but query failed'
        }
    } else {
        $checks['sccache'] = '[WARN] not installed'
        $issues.Add('sccache not installed')
    }

    # 7. lld-link
    $lldLink = Get-Command lld-link -ErrorAction SilentlyContinue
    $checks['lld-link'] = if ($lldLink) { "[OK] $($lldLink.Source)" } else { '[WARN] not found (uses MSVC link.exe)' }

    # 8. OneDrive lock on .psd1?
    $psd1 = Get-CargoToolsPsd1Path
    if ($psd1 -like '*\OneDrive\*') {
        $checks['OneDrive .psd1'] = '[WARN] .psd1 is under OneDrive — may lock during sync'
        $issues.Add('.psd1 under OneDrive path — risk of sync lock')
    } else {
        $checks['OneDrive .psd1'] = '[OK]'
    }

    $exitCode = if ($issues.Count -gt 0) { 4 } else { 0 }

    if ($AsJson) {
        $obj = [ordered]@{
            wrapper       = $WrapperName
            checks        = $checks
            issues        = $issues.ToArray()
            exit_code     = $exitCode
            timestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }
        # Use Write-Host (Information stream 6) for the JSON line, NOT Write-Output:
        #  - Write-Output (stream 1) would pollute `exit (Invoke-WrapperDoctor ...)`
        #    in the wrapper call site, since that expression captures stream 1.
        #  - Write-Host (stream 6) doesn't reach the pipeline, so the function's
        #    `return $exitCode` is the only thing the caller sees.
        #  - At the .cmd shim layer (pwsh.exe -File ...), stream 6 is merged into
        #    stdout when output is piped to another process, so `cargo --diagnose | jq .`
        #    works in production. Pester tests capture it via `*>&1`.
        Write-Host ($obj | ConvertTo-Json -Depth 5 -Compress)
    } else {
        Write-Host ''
        Write-Host "=== CargoTools Doctor ($WrapperName) ===" -ForegroundColor Cyan
        foreach ($key in $checks.Keys) {
            $val = $checks[$key]
            $color = if ($val -like '*[OK]*') { 'Green' } `
                     elseif ($val -like '*[ERROR]*') { 'Red' } `
                     else { 'Yellow' }
            Write-Host "  $($key.PadRight(30)) $val" -ForegroundColor $color
        }
        if ($issues.Count -gt 0) {
            Write-Host ''
            Write-Host '  Issues:' -ForegroundColor Red
            foreach ($iss in $issues) { Write-Host "    - $iss" -ForegroundColor Red }
        } else {
            Write-Host ''
            Write-Host '  [OK] All checks passed.' -ForegroundColor Green
        }
        Write-Host ''
    }

    return $exitCode
}

# --------------------------------------------------------------------------
# Show-WrapperList
# --------------------------------------------------------------------------
function Show-WrapperList {
    $ver = Get-CargoToolsVersion
    $localBin = Join-Path $env:USERPROFILE '.local\bin'
    $userBin  = Join-Path $env:USERPROFILE 'bin'

    $searchDirs = [System.Collections.Generic.List[string]]::new()
    $searchDirs.Add($localBin)
    $searchDirs.Add($userBin)

    # Also search PSModulePath candidates
    $env:PSModulePath -split ';' | Where-Object { $_ } | ForEach-Object {
        $wdir = Join-Path $_ 'CargoTools\wrappers'
        if (Test-Path $wdir) { $searchDirs.Add($wdir) }
    }

    $wrapperNames = @('cargo', 'cargo-route', 'cargo-wrapper', 'cargo-wsl',
                      'cargo-docker', 'cargo-macos', 'maturin',
                      'rust-analyzer', 'rust-analyzer-wrapper')

    Write-Host ''
    Write-Host "CargoTools Wrappers (module v$ver)" -ForegroundColor Cyan
    Write-Host ($('Name').PadRight(28) + 'Path') -ForegroundColor White

    $found = $false
    foreach ($dir in ($searchDirs | Select-Object -Unique)) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($name in $wrapperNames) {
            $ps1 = Join-Path $dir "$name.ps1"
            if (Test-Path $ps1) {
                Write-Host ($name.PadRight(28) + $ps1)
                $found = $true
            }
        }
    }
    if (-not $found) {
        Write-Host '  (no wrappers found — run tools\Install-Wrappers.ps1)' -ForegroundColor Yellow
    }
    Write-Host ''
}

Export-ModuleMember -Function @(
    'Get-CargoToolsVersion',
    'Get-WrapperContext',
    'Import-CargoToolsResilient',
    'Invoke-WrapperDoctor',
    'Resolve-Subcommand',
    'Show-WrapperHelp',
    'Show-WrapperList',
    'Show-WrapperVersion',
    'Write-LlmEvent'
)
