function Invoke-CargoWsl {
<#
.SYNOPSIS
Run cargo inside WSL with optional shared caches and preflight checks.
.PARAMETER ArgumentList
Raw cargo-wsl arguments.
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
        [string[]]$ArgumentList
    )

    $rawArgs = if ($ArgumentList) { @($ArgumentList) } else { @() }
    if ($rawArgs -isnot [System.Array]) { $rawArgs = @($rawArgs) }
    $selectedDistro = ''
    $remaining = New-Object System.Collections.Generic.List[string]
    $Native = $false
    $Shared = $false
    $Sccache = $false
    $NoSccache = $false

    function Show-Help {
        Write-Host 'cargo-wsl - Run cargo inside WSL' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  cargo-wsl [--distro <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-wsl --native [--distro <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-wsl --shared [--distro <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-wsl --sccache [--distro <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-wsl --no-sccache [--distro <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-wsl --preflight [--preflight-mode <check|clippy|fmt|all>]' -ForegroundColor Gray
        Write-Host '  cargo-wsl --preflight-ra [--preflight-strict]' -ForegroundColor Gray
        Write-Host '  cargo-wsl --preflight-blocking | --preflight-nonblocking' -ForegroundColor Gray
        Write-Host '  cargo-wsl --preflight-force' -ForegroundColor Gray
        Write-Host '  cargo-wsl --help' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Defaults:' -ForegroundColor Yellow
        Write-Host '  - Uses current directory mapped via wslpath' -ForegroundColor Gray
        Write-Host '  - Uses ~/.cargo and ~/.rustup (native cache mode)' -ForegroundColor Gray
        Write-Host '  - Use --native to keep caches in WSL home (~/.cargo, ~/.rustup)' -ForegroundColor Gray
        Write-Host '  - Use CARGO_WSL_CACHE=shared|native to set default (currently native)' -ForegroundColor Gray
        Write-Host '  - Use CARGO_WSL_SCCACHE=1 to default-enable sccache in WSL' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Wrappers:' -ForegroundColor Yellow
        Write-Host '  cargo-wsl.ps1 (direct)' -ForegroundColor Gray
        Write-Host '  cargo --route wsl [args...]' -ForegroundColor Gray
        Write-Host ''
    }

    foreach ($arg in $rawArgs) {
        if ($arg -eq '--help' -or $arg -eq '-h') { Show-Help; return 0 }
    }

    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $arg = $rawArgs[$i]
        if ($arg -eq '--distro' -or $arg -eq '-distro') {
            $i++
            if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --distro'; return 1 }
            $selectedDistro = $rawArgs[$i]
            continue
        }
        if ($arg -eq '--native') { $Native = $true; continue }
        if ($arg -eq '--shared') { $Shared = $true; continue }
        if ($arg -eq '--sccache') { $Sccache = $true; continue }
        if ($arg -eq '--no-sccache') { $NoSccache = $true; continue }
        $remaining.Add($arg)
    }

    if (-not (Assert-NotBoth -Name 'wsl cache mode' -A $Native -B $Shared)) { return 1 }
    if (-not (Assert-NotBoth -Name 'wsl sccache mode' -A $Sccache -B $NoSccache)) { return 1 }

    $preflightSplit = Split-PreflightArgs $remaining.ToArray()
    if (-not $preflightSplit) { return 1 }
    $remaining = New-Object System.Collections.Generic.List[string]
    $remaining.AddRange($preflightSplit.Remaining)
    $preflight = Apply-PreflightEnvDefaults $preflightSplit.State
    $preflight = Apply-PreflightIdeGuard $preflight

    $cacheMode = $null
    if ($Native) { $cacheMode = 'native' }
    if ($Shared) { $cacheMode = 'shared' }
    if (-not $cacheMode) {
        if ($env:CARGO_WSL_CACHE) { $cacheMode = $env:CARGO_WSL_CACHE }
    }
    if (-not $cacheMode) { $cacheMode = 'native' }

    if (-not (Assert-AllowedValue -Name 'wsl cache mode' -Value $cacheMode -Allowed @('native','shared'))) { return 1 }

    $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if (-not $wsl) { Write-Error 'wsl.exe not found. Install WSL or add it to PATH.'; return 1 }

    $cwd = (Get-Location).Path
    $wslArgs = @()
    if (-not [string]::IsNullOrWhiteSpace($selectedDistro)) { $wslArgs += @('-d', $selectedDistro) }
    $wslCwd = & wsl.exe @wslArgs wslpath -a $cwd 2>$null
    if (-not $wslCwd) {
        $wslCwd = & wsl.exe @wslArgs wslpath -u $cwd 2>$null
    }
    if (-not $wslCwd) {
        $driveMatch = [regex]::Match($cwd, '^(?<drive>[A-Za-z]):\\(?<rest>.*)$')
        if ($driveMatch.Success) {
            $drive = $driveMatch.Groups['drive'].Value.ToLowerInvariant()
            $rest = $driveMatch.Groups['rest'].Value -replace '\\','/'
            $wslCwd = "/mnt/$drive/$rest"
        }
    }
    if (-not $wslCwd) { Write-Error "Failed to map path to WSL: $cwd"; return 1 }

    $useSccache = $false
    if ($NoSccache) { $useSccache = $false }
    elseif ($Sccache) { $useSccache = $true }
    elseif ($env:CARGO_WSL_SCCACHE) { $useSccache = $true }

    $envBlock = New-Object System.Collections.Generic.List[string]
    if ($env:LD_LIBRARY_PATH -and ($env:LD_LIBRARY_PATH -match ':\' -or $env:LD_LIBRARY_PATH -match ';')) {
        $envBlock.Add('LD_LIBRARY_PATH=')
    }
    if ($cacheMode -eq 'native') {
        $envBlock.Add('CARGO_HOME=$HOME/.cargo')
        $envBlock.Add('RUSTUP_HOME=$HOME/.rustup')
        $envBlock.Add("CARGO_TARGET_DIR=$wslCwd/target")
    } else {
        $envBlock.Add('CARGO_HOME=/mnt/t/RustCache/wsl-cargo-home')
        $envBlock.Add('RUSTUP_HOME=/mnt/t/RustCache/wsl-rustup')
        $envBlock.Add('CARGO_TARGET_DIR=/mnt/t/RustCache/cargo-target')
    }

    if ($useSccache) {
        $envBlock.Add('RUSTC_WRAPPER=sccache')
        if ($cacheMode -eq 'native') {
            $envBlock.Add('SCCACHE_DIR=$HOME/.cache/sccache')
        } else {
            $envBlock.Add('SCCACHE_DIR=/mnt/t/RustCache/sccache')
        }
        $envBlock.Add('SCCACHE_CACHE_SIZE=30G')
        $envBlock.Add('SCCACHE_CACHE_COMPRESSION=zstd')
        $envBlock.Add('SCCACHE_LOG=warn')
        $envBlock.Add('SCCACHE_DIRECT=true')
        $envBlock.Add('SCCACHE_IDLE_TIMEOUT=1800')
    }

    if ($env:RA_DIAGNOSTICS_FLAGS) { $envBlock.Add("RA_DIAGNOSTICS_FLAGS=$env:RA_DIAGNOSTICS_FLAGS") }

    $joinedArgs = $remaining -join ' '
    $exportEnv = $envBlock -join ' '
    $preEnv = 'unset LD_LIBRARY_PATH CARGO_TARGET_DIR; '
    $sccacheStart = ''
    if ($useSccache) { $sccacheStart = 'command -v sccache >/dev/null 2>&1 && sccache --start-server >/dev/null 2>&1; ' }

    $preflightCmd = Build-PreflightShellCommand -Args $remaining.ToArray() -State $preflight
    $raCmd = Build-RaDiagnosticsShellCommand -WorkDir $wslCwd -Args $remaining.ToArray() -State $preflight
    $command = "cd '$wslCwd' && $preEnv$sccacheStart export $exportEnv && $preflightCmd$raCmd cargo $joinedArgs"

    $envBackup = @{}
    $envToClear = @(
        'CARGO_TARGET_DIR',
        'CARGO_HOME',
        'RUSTUP_HOME',
        'RUSTC_WRAPPER',
        'SCCACHE_DIR',
        'SCCACHE_CACHE_SIZE',
        'SCCACHE_LOG',
        'SCCACHE_ERROR_LOG',
        'SCCACHE_DIRECT',
        'SCCACHE_NO_DAEMON',
        'SCCACHE_SERVER_PORT',
        'SCCACHE_IDLE_TIMEOUT',
        'SCCACHE_CACHE_COMPRESSION',
        'SCCACHE_STARTUP_TIMEOUT',
        'SCCACHE_REQUEST_TIMEOUT'
    )
    foreach ($name in $envToClear) {
        if (Test-Path "Env:$name") {
            $envBackup[$name] = (Get-Item -Path "Env:$name").Value
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    try {
        & wsl.exe @wslArgs -e bash -lc $command
        return $LASTEXITCODE
    } catch {
        Write-Error "WSL cargo invocation failed: $_"
        return 1
    } finally {
        foreach ($entry in $envBackup.GetEnumerator()) {
            Set-Item -Path ("Env:" + $entry.Key) -Value $entry.Value
        }
    }
}
