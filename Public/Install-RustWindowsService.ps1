function Install-RustWindowsService {
    <#
    .SYNOPSIS
        Install a Rust-built Windows Service binary via sc.exe.
    .DESCRIPTION
        Wraps sc.exe create with validation: checks binary exists, runs a smoke test
        in console mode, registers the Windows Event Log source, and creates the service.
    .PARAMETER ServiceName
        Name for the Windows service (e.g., "Redis").
    .PARAMETER BinaryPath
        Path to the Rust service executable.
    .PARAMETER ConfigPath
        Path to the configuration file passed via -c flag.
    .PARAMETER DisplayName
        Friendly display name for the service.
    .PARAMETER Description
        Service description shown in services.msc.
    .PARAMETER StartType
        Service start type: auto, demand, or disabled.
    .EXAMPLE
        Install-RustWindowsService -ServiceName Redis -BinaryPath .\redis-service.exe -ConfigPath .\redis-agent.conf
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName,

        [Parameter(Mandatory)]
        [string]$BinaryPath,

        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [string]$DisplayName = $ServiceName,

        [string]$Description = "Rust Windows Service: $ServiceName",

        [ValidateSet("auto", "demand", "disabled")]
        [string]$StartType = "auto"
    )

    # Validate binary exists
    if (-not (Test-Path $BinaryPath)) {
        Write-Error "Binary not found: $BinaryPath"
        return
    }

    # Validate config exists
    if (-not (Test-Path $ConfigPath)) {
        Write-Error "Config not found: $ConfigPath"
        return
    }

    $fullBinary = (Resolve-Path $BinaryPath).Path
    $fullConfig = (Resolve-Path $ConfigPath).Path

    # Smoke test: run in console mode briefly
    Write-Host "Running smoke test: $fullBinary -c $fullConfig --console" -ForegroundColor Yellow
    $smokeJob = Start-Job -ScriptBlock {
        param($bin, $cfg)
        & $bin -c $cfg --console 2>&1
    } -ArgumentList $fullBinary, $fullConfig

    Start-Sleep -Seconds 3
    Stop-Job $smokeJob -ErrorAction SilentlyContinue
    $smokeOutput = Receive-Job $smokeJob -ErrorAction SilentlyContinue
    Remove-Job $smokeJob -Force -ErrorAction SilentlyContinue

    if ($smokeOutput -match "error|panic|FATAL") {
        Write-Error "Smoke test failed. Output:`n$smokeOutput"
        return
    }
    Write-Host "Smoke test passed" -ForegroundColor Green

    # Register Event Log source
    try {
        $source = "Redis Service"
        if (-not [System.Diagnostics.EventLog]::SourceExists($source)) {
            [System.Diagnostics.EventLog]::CreateEventSource($source, "Application")
            Write-Host "Registered Event Log source: $source" -ForegroundColor Green
        }
    } catch {
        Write-Warning "Could not register Event Log source: $($_.Exception.Message)"
    }

    # Stop and remove existing service if present
    $existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($existing) {
        if ($existing.Status -eq "Running") {
            Write-Host "Stopping existing service..." -ForegroundColor Yellow
            net stop $ServiceName 2>$null
        }
        Write-Host "Removing existing service..." -ForegroundColor Yellow
        sc.exe delete $ServiceName 2>$null
        Start-Sleep -Seconds 2
    }

    # Create the service
    $binPath = "`"$fullBinary`" -c `"$fullConfig`""
    $result = sc.exe create $ServiceName binPath=$binPath start=$StartType DisplayName=$DisplayName
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create service: $result"
        return
    }

    # Set description
    sc.exe description $ServiceName $Description 2>$null

    Write-Host "Service '$ServiceName' created successfully" -ForegroundColor Green
    Write-Host "  Binary: $fullBinary" -ForegroundColor Cyan
    Write-Host "  Config: $fullConfig" -ForegroundColor Cyan
    Write-Host "  Start:  net start $ServiceName" -ForegroundColor Cyan
}

Export-ModuleMember -Function Install-RustWindowsService
