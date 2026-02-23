function Invoke-CargoDocker {
<#
.SYNOPSIS
Run cargo inside Docker with shared caches.
.PARAMETER ArgumentList
Raw cargo-docker arguments.
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
        [string[]]$ArgumentList
    )

    $rawArgs = if ($ArgumentList) { @($ArgumentList) } else { @() }
    if ($rawArgs -isnot [System.Array]) { $rawArgs = @($rawArgs) }
    $selectedImage = ''
    $remaining = New-Object System.Collections.Generic.List[string]
    $Sccache = $false
    $NoSccache = $false
    $Zigbuild = $false
    $BootstrapSccache = $false
    $NoConfig = $false
    $NoTty = $false

    function Show-Help {
        Write-Host 'cargo-docker - Run cargo inside Docker' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  cargo-docker [--image <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-docker --sccache [--image <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-docker --zigbuild [--image <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-docker --bootstrap-sccache [--image <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-docker --no-sccache [--image <name>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-docker --preflight [--preflight-mode <check|clippy|fmt|all>]' -ForegroundColor Gray
        Write-Host '  cargo-docker --preflight-ra [--preflight-strict]' -ForegroundColor Gray
        Write-Host '  cargo-docker --preflight-blocking | --preflight-nonblocking' -ForegroundColor Gray
        Write-Host '  cargo-docker --preflight-force' -ForegroundColor Gray
        Write-Host '  cargo-docker --help' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Defaults:' -ForegroundColor Yellow
        Write-Host '  - Mounts current directory to /work' -ForegroundColor Gray
        Write-Host '  - Uses T:\RustCache\cargo-home as CARGO_HOME' -ForegroundColor Gray
        Write-Host '  - Uses T:\RustCache\cargo-target as CARGO_TARGET_DIR' -ForegroundColor Gray
        Write-Host '  - Picks an existing rust:* image if available, otherwise rust:latest' -ForegroundColor Gray
        Write-Host '  - Optional: --sccache mounts T:\RustCache\sccache to /sccache' -ForegroundColor Gray
        Write-Host '  - Optional: mounts C:\Users\david\.cargo\config.toml into /cargo/config.toml' -ForegroundColor Gray
        Write-Host '  - --zigbuild selects ghcr.io/rust-cross/cargo-zigbuild when no --image is specified' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Notes:' -ForegroundColor Yellow
        Write-Host '  --bootstrap-sccache installs sccache in the container if missing' -ForegroundColor Gray
        Write-Host '  --zigbuild uses ''cargo zigbuild'' inside the container' -ForegroundColor Gray
        Write-Host '  --no-config disables mounting the host config.toml' -ForegroundColor Gray
        Write-Host '  --no-tty disables interactive terminal allocation' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Wrappers:' -ForegroundColor Yellow
        Write-Host '  cargo-docker.ps1 (direct)' -ForegroundColor Gray
        Write-Host '  cargo --route docker [args...]' -ForegroundColor Gray
        Write-Host ''
    }

    foreach ($arg in $rawArgs) {
        if ($arg -eq '--help' -or $arg -eq '-h') { Show-Help; return 0 }
    }

    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $arg = $rawArgs[$i]
        if ($arg -eq '--image' -or $arg -eq '-image') {
            $i++
            if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --image'; return 1 }
            $selectedImage = $rawArgs[$i]
            continue
        }
        if ($arg -eq '--sccache') { $Sccache = $true; continue }
        if ($arg -eq '--zigbuild') { $Zigbuild = $true; continue }
        if ($arg -eq '--no-sccache') { $NoSccache = $true; continue }
        if ($arg -eq '--bootstrap-sccache') { $BootstrapSccache = $true; $Sccache = $true; continue }
        if ($arg -eq '--no-config') { $NoConfig = $true; continue }
        if ($arg -eq '--no-tty') { $NoTty = $true; continue }
        $remaining.Add($arg)
    }

    if (-not (Assert-NotBoth -Name 'docker sccache mode' -A $Sccache -B $NoSccache)) { return 1 }

    $preflightSplit = Split-PreflightArgs $remaining.ToArray()
    if (-not $preflightSplit) { return 1 }
    $remaining = New-Object System.Collections.Generic.List[string]
    $remaining.AddRange($preflightSplit.Remaining)
    $preflight = Apply-PreflightEnvDefaults $preflightSplit.State
    $preflight = Apply-PreflightIdeGuard $preflight
    if ($Zigbuild -and $remaining.Count -gt 0) {
        for ($i = $remaining.Count - 1; $i -ge 0; $i--) {
            if ($remaining[$i] -eq 'build' -or $remaining[$i] -eq 'b') {
                $remaining.RemoveAt($i)
            }
        }
    }

    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $docker) { Write-Error 'docker not found in PATH. Install Docker Desktop or add docker.exe to PATH.'; return 1 }

    $workDir = (Get-Location).Path
    $cacheRoot = 'T:\RustCache'
    $cargoHome = Join-Path $cacheRoot 'cargo-home'
    $targetDir = Join-Path $cacheRoot 'cargo-target'
    $sccacheDir = Join-Path $cacheRoot 'sccache'
    if ($NoSccache) { $Sccache = $false }
    New-Item -ItemType Directory -Path $cargoHome -Force | Out-Null
    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    if ($Sccache) { New-Item -ItemType Directory -Path $sccacheDir -Force | Out-Null }

    if ([string]::IsNullOrWhiteSpace($selectedImage)) {
        if ($Zigbuild) {
            $selectedImage = 'ghcr.io/rust-cross/cargo-zigbuild'
        } else {
            $images = docker images --format "{{.Repository}}:{{.Tag}}" 2>$null | Where-Object { $_ -like 'rust:*' }
            if ($images -and $images.Count -gt 0) { $selectedImage = $images[0] }
            else { $selectedImage = 'rust:latest' }
        }
    }

    $dockerArgs = @(
        'run', '--rm',
        '-v', "${workDir}:/work",
        '-v', "${cargoHome}:/cargo",
        '-v', "${targetDir}:/target",
        '-w', '/work',
        '-e', 'CARGO_HOME=/cargo',
        '-e', 'CARGO_TARGET_DIR=/target'
    )

    if (-not $NoTty) { $dockerArgs = @('run','--rm','-it') + $dockerArgs[2..($dockerArgs.Count - 1)] }

    if (-not $NoConfig) {
        $hostConfig = Join-Path $env:USERPROFILE '.cargo\config.toml'
        if (Test-Path $hostConfig) { $dockerArgs += @('-v', "${hostConfig}:/cargo/config.toml:ro") }
    }

    if ($Sccache) {
        $dockerArgs += @(
            '-v', "${sccacheDir}:/sccache",
            '-e', 'SCCACHE_DIR=/sccache',
            '-e', 'SCCACHE_CACHE_SIZE=30G',
            '-e', 'SCCACHE_CACHE_COMPRESSION=zstd',
            '-e', 'SCCACHE_LOG=warn',
            '-e', 'SCCACHE_ERROR_LOG=/sccache/error.log',
            '-e', 'RUSTC_WRAPPER=sccache'
        )
    }

    if ($env:RA_DIAGNOSTICS_FLAGS) { $dockerArgs += @('-e', "RA_DIAGNOSTICS_FLAGS=$env:RA_DIAGNOSTICS_FLAGS") }

    $useShell = $BootstrapSccache -or $preflight.Enabled -or $preflight.RA -or $Zigbuild
    if ($useShell) { $dockerArgs += @('--entrypoint', 'sh') }

    $dockerArgs += @($selectedImage)
    $preflightCmd = Build-PreflightShellCommand -Args $remaining.ToArray() -State $preflight -UseShellEscaping
    $raCmd = Build-RaDiagnosticsShellCommand -WorkDir '/work' -Args $remaining.ToArray() -State $preflight
    $pathPrefix = 'export PATH=/cargo/bin:/usr/local/cargo/bin:$PATH; '

    if ($useShell) {
        $cmd = $pathPrefix
        if ($BootstrapSccache) {
            $cmd += 'export RUSTC_WRAPPER=; command -v sccache >/dev/null 2>&1 || cargo install sccache; '
        }
        $cmd += $preflightCmd
        $cmd += $raCmd
        if ($Zigbuild) {
            $cmd += 'exec cargo zigbuild ' + (Convert-ArgsToShell $remaining.ToArray())
        } else {
            $cmd += 'exec cargo ' + (Convert-ArgsToShell $remaining.ToArray())
        }
        $dockerArgs += @('-lc', $cmd)
    } else {
        $dockerArgs += @('cargo')
        $dockerArgs += $remaining
    }

    try {
        & docker @dockerArgs
        return $LASTEXITCODE
    } catch {
        Write-Error "docker invocation failed: $_"
        return 1
    }
}
