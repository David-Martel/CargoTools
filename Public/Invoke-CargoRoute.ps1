function Invoke-CargoRoute {
<#
.SYNOPSIS
Route cargo builds by target to Windows, WSL, or Docker.
.DESCRIPTION
Routes cargo invocations based on target triple, with overrides for wasm and macOS.
Pass CLI-style arguments (e.g. --route, --no-route, --wsl-native) as in the script wrapper.
.PARAMETER ArgumentList
Raw cargo/route arguments. Use this when calling from wrappers.
.EXAMPLE
Invoke-CargoRoute --help
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
        [string[]]$ArgumentList
    )

    $rawArgs = if ($ArgumentList) { @($ArgumentList) } else { @() }
    if ($rawArgs -isnot [System.Array]) { $rawArgs = @($rawArgs) }
    $passThrough = New-Object System.Collections.Generic.List[string]
    $Route = ''
    $RouteWasm = ''
    $RouteMacos = ''
    $RouteDebug = $false
    $NoRoute = $false
    $WslNative = $false
    $WslShared = $false
    $WslSccache = $false
    $WslNoSccache = $false
    $DockerSccache = $false
    $DockerNoSccache = $false
    $DockerZigbuild = $false
    $DockerNoZigbuild = $false
    $helpRequested = $false

    foreach ($arg in $rawArgs) {
        if ($arg -eq '--help' -or $arg -eq '-h') { $helpRequested = $true }
    }

    function Show-Help {
        Write-Host 'cargo-route - Route cargo builds by target' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  cargo [cargo-args]' -ForegroundColor Gray
        Write-Host '  cargo --route <auto|windows|wsl|docker> [cargo-args]' -ForegroundColor Gray
        Write-Host '  cargo --route-wasm <windows|wsl|docker> [cargo-args]' -ForegroundColor Gray
        Write-Host '  cargo --route-macos <wsl|docker> [cargo-args]' -ForegroundColor Gray
        Write-Host '  cargo --no-route [cargo-args]' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Routing defaults:' -ForegroundColor Yellow
        Write-Host '  - Windows targets -> Windows (MSVC/LLD)' -ForegroundColor Gray
        Write-Host '  - Linux targets -> WSL' -ForegroundColor Gray
        Write-Host '  - wasm targets -> WSL (override with --route-wasm)' -ForegroundColor Gray
        Write-Host '  - Apple targets -> route-macos (default set by CARGO_ROUTE_MACOS)' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'WSL cache modes:' -ForegroundColor Yellow
        Write-Host '  --wsl-native     Use ~/.cargo and ~/.rustup inside WSL' -ForegroundColor Gray
        Write-Host '  --wsl-shared     Use /mnt/t/RustCache (default)' -ForegroundColor Gray
        Write-Host '  --wsl-sccache    Enable sccache in WSL' -ForegroundColor Gray
        Write-Host '  --wsl-no-sccache Disable sccache in WSL' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Docker options:' -ForegroundColor Yellow
        Write-Host '  --docker-sccache Enable sccache in container' -ForegroundColor Gray
        Write-Host '  --docker-no-sccache Disable sccache in container' -ForegroundColor Gray
        Write-Host '  --docker-zigbuild Use cargo-zigbuild in container' -ForegroundColor Gray
        Write-Host '  --docker-no-zigbuild Disable zigbuild (Apple targets only)' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Env overrides:' -ForegroundColor Yellow
        Write-Host '  CARGO_ROUTE_DEFAULT=auto|windows|wsl|docker' -ForegroundColor Gray
        Write-Host '  CARGO_ROUTE_WASM=windows|wsl|docker' -ForegroundColor Gray
        Write-Host '  CARGO_ROUTE_MACOS=wsl|docker' -ForegroundColor Gray
        Write-Host '  CARGO_WSL_CACHE=shared|native' -ForegroundColor Gray
        Write-Host '  CARGO_WSL_SCCACHE=1' -ForegroundColor Gray
        Write-Host '  CARGO_DOCKER_SCCACHE=1' -ForegroundColor Gray
        Write-Host '  CARGO_DOCKER_ZIGBUILD=1' -ForegroundColor Gray
        Write-Host '  CARGO_ROUTE_DISABLE=1  (bypass routing)' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Wrappers:' -ForegroundColor Yellow
        Write-Host '  PowerShell: cargo.ps1 (preferred) -> cargo-route.ps1' -ForegroundColor Gray
        Write-Host '  cmd.exe:    cargo.cmd / cargo.bat -> cargo.ps1 (pwsh)' -ForegroundColor Gray
        Write-Host ''
    }

    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $arg = $rawArgs[$i]
        switch ($arg) {
            '--route' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --route'; return 1 }
                $Route = $rawArgs[$i]; continue
            }
            '--route-wasm' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --route-wasm'; return 1 }
                $RouteWasm = $rawArgs[$i]; continue
            }
            '--route-macos' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --route-macos'; return 1 }
                $RouteMacos = $rawArgs[$i]; continue
            }
            '--no-route' { $NoRoute = $true; continue }
            '--wsl-native' { $WslNative = $true; continue }
            '--wsl-shared' { $WslShared = $true; continue }
            '--wsl-sccache' { $WslSccache = $true; continue }
            '--wsl-no-sccache' { $WslNoSccache = $true; continue }
            '--docker-sccache' { $DockerSccache = $true; continue }
            '--docker-no-sccache' { $DockerNoSccache = $true; continue }
            '--docker-zigbuild' { $DockerZigbuild = $true; continue }
            '--docker-no-zigbuild' { $DockerNoZigbuild = $true; continue }
            '--route-debug' { $RouteDebug = $true; continue }
            default { $passThrough.Add($arg); continue }
        }
    }

    if ($helpRequested) {
        Show-Help
        return 0
    }

    $validRoute = Assert-AllowedValue -Name 'route' -Value $Route -Allowed @('auto','windows','wsl','docker')
    if (-not $validRoute) { return 1 }

    $validRouteWasm = Assert-AllowedValue -Name 'route-wasm' -Value $RouteWasm -Allowed @('windows','wsl','docker')
    if (-not $validRouteWasm) { return 1 }

    $validRouteMacos = Assert-AllowedValue -Name 'route-macos' -Value $RouteMacos -Allowed @('wsl','docker')
    if (-not $validRouteMacos) { return 1 }

    if ($RouteDebug) {
        Write-Host 'cargo-route debug:' -ForegroundColor Yellow
        Write-Host "  rawArgs: $($rawArgs -join '|')" -ForegroundColor Yellow
    }

    if ($env:CARGO_ROUTE_DISABLE -and $env:CARGO_ROUTE_DISABLE -ne '0') {
        $NoRoute = $true
    }

    if ($NoRoute) {
        return (Invoke-CargoWrapper @passThrough)
    }

    $target = Get-TargetFromArgs $passThrough.ToArray()
    $class = Classify-Target $target

    $routeDefault = if ($Route) { $Route } elseif ($env:CARGO_ROUTE_DEFAULT) { $env:CARGO_ROUTE_DEFAULT } else { 'auto' }
    $routeWasm = if ($RouteWasm) { $RouteWasm } elseif ($env:CARGO_ROUTE_WASM) { $env:CARGO_ROUTE_WASM } else { 'wsl' }
    $routeMacos = if ($RouteMacos) { $RouteMacos } elseif ($env:CARGO_ROUTE_MACOS) { $env:CARGO_ROUTE_MACOS } else { 'wsl' }

    if (-not (Assert-AllowedValue -Name 'route-default' -Value $routeDefault -Allowed @('auto','windows','wsl','docker'))) { return 1 }
    if (-not (Assert-AllowedValue -Name 'route-wasm' -Value $routeWasm -Allowed @('windows','wsl','docker'))) { return 1 }
    if (-not (Assert-AllowedValue -Name 'route-macos' -Value $routeMacos -Allowed @('wsl','docker'))) { return 1 }

    $route = $routeDefault
    if ($route -eq 'auto') {
        switch ($class) {
            'windows' { $route = 'windows' }
            'linux' { $route = 'wsl' }
            'wasm' { $route = $routeWasm }
            'apple' { $route = $routeMacos }
            default { $route = 'windows' }
        }
    }

    if ($RouteDebug) {
        Write-Host "  passThrough: $($passThrough.ToArray() -join '|')" -ForegroundColor Yellow
        Write-Host "  route: $route (class=$class target=$target)" -ForegroundColor Yellow
    }

    switch ($route) {
        'windows' { return (Invoke-CargoWrapper @passThrough) }
        'wsl' {
            $wslArgs = New-Object System.Collections.Generic.List[string]
            if ($WslNative) { $wslArgs.Add('--native') }
            if ($WslShared) { $wslArgs.Add('--shared') }
            if ($WslSccache) { $wslArgs.Add('--sccache') }
            if ($WslNoSccache) { $wslArgs.Add('--no-sccache') }
            $wslArgs.AddRange($passThrough)
            return (Invoke-CargoWsl @wslArgs)
        }
        'docker' {
            $dockerArgs = New-Object System.Collections.Generic.List[string]
            if ($DockerNoSccache) {
                $dockerArgs.Add('--no-sccache')
            } elseif ($DockerSccache -or ($env:CARGO_DOCKER_SCCACHE -and $env:CARGO_DOCKER_SCCACHE -ne '0')) {
                $dockerArgs.Add('--sccache')
            }
            $useZigbuild = $false
            if ($DockerNoZigbuild) {
                $useZigbuild = $false
            } elseif ($DockerZigbuild -or ($env:CARGO_DOCKER_ZIGBUILD -and $env:CARGO_DOCKER_ZIGBUILD -ne '0')) {
                $useZigbuild = $true
            } elseif ($class -eq 'apple') {
                $useZigbuild = $true
            }
            if ($useZigbuild) { $dockerArgs.Add('--zigbuild') }
            $dockerArgs.AddRange($passThrough)
            return (Invoke-CargoDocker @dockerArgs)
        }
        default {
            Write-Warning "Unknown route '$route'; falling back to Windows."
            return (Invoke-CargoWrapper @passThrough)
        }
    }
}
