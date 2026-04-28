#Requires -Version 5.1
<#
.SYNOPSIS
    Machine-aware configuration for CargoTools.
.DESCRIPTION
    Resolves machine-specific paths and settings based on the current machine's
    identity (hostname + hardware hash). Each machine can have different cache
    drives, toolchain locations, and build optimization settings.

    Machine configs are stored in CargoTools/Config/machines.json alongside
    the existing PowerShell MachineConfiguration module's format.
#>

# Cache the machine identity for the session
$script:MachineIdentity = $null
$script:MachineConfig = $null

function Get-MachineIdentity {
    <#
    .SYNOPSIS
    Returns a stable machine identity hash based on hostname and hardware.
    #>
    if ($script:MachineIdentity) { return $script:MachineIdentity }

    $hostname = $env:COMPUTERNAME
    if (-not $hostname) { $hostname = [System.Net.Dns]::GetHostName() }

    # Use hostname as the primary key (simple, readable, stable)
    $script:MachineIdentity = $hostname.ToUpper()
    return $script:MachineIdentity
}

function Get-MachineConfigPath {
    $moduleRoot = Split-Path -Parent $PSScriptRoot
    return Join-Path $moduleRoot 'Config\machines-cargo.json'
}

function Get-MachineConfig {
    <#
    .SYNOPSIS
    Returns the CargoTools configuration for the current machine.
    .DESCRIPTION
    Looks up machine-specific settings (cache root, CARGO_HOME, RUSTUP_HOME,
    build jobs, sccache settings, etc.) from Config/machines-cargo.json.
    Falls back to sensible defaults if no machine entry exists.
    .OUTPUTS
    Hashtable with machine-specific CargoTools settings.
    #>
    [CmdletBinding()]
    param([switch]$Force)

    if ($script:MachineConfig -and -not $Force) { return $script:MachineConfig }

    $configPath = Get-MachineConfigPath
    $machineId = Get-MachineIdentity
    $defaults = Get-DefaultMachineConfig

    if (Test-Path $configPath) {
        try {
            $allConfigs = Get-Content $configPath -Raw | ConvertFrom-Json
            $machineEntry = $allConfigs.$machineId
            if ($machineEntry) {
                # Merge machine-specific values over defaults
                $config = $defaults.Clone()
                foreach ($prop in $machineEntry.PSObject.Properties) {
                    if ($null -ne $prop.Value -and $prop.Value -ne '') {
                        $config[$prop.Name] = $prop.Value
                    }
                }
                $script:MachineConfig = $config
                return $config
            }
        } catch {
            Write-Verbose "Failed to read machine config: $_"
        }
    }

    # No machine entry - return defaults and auto-register
    $script:MachineConfig = $defaults
    Register-CurrentMachine -Config $defaults
    return $defaults
}

function Get-DefaultMachineConfig {
    <#
    .SYNOPSIS
    Returns sensible defaults based on what's available on this machine.
    #>
    $config = @{}

    # Determine cache root: prefer T: (Dev Drive/ReFS), then D:, then local
    if (Test-Path 'T:\') {
        $config['CacheRoot'] = 'T:\RustCache'
    } elseif (Test-Path 'D:\') {
        $config['CacheRoot'] = 'D:\RustCache'
    } else {
        $config['CacheRoot'] = Join-Path $env:LOCALAPPDATA 'RustCache'
    }

    # CARGO_HOME and RUSTUP_HOME: use cache root if on fast drive, else default
    $config['CargoHome'] = Join-Path $config['CacheRoot'] 'cargo-home'
    $config['RustupHome'] = Join-Path $config['CacheRoot'] 'rustup'
    $config['CargoTargetDir'] = Join-Path $config['CacheRoot'] 'cargo-target'
    $config['SccacheDir'] = Join-Path $config['CacheRoot'] 'sccache'
    $config['TargetMode'] = 'local'

    # If CARGO_HOME/RUSTUP_HOME are already at the default locations and have data, keep them
    $defaultCargoHome = Join-Path $env:USERPROFILE '.cargo'
    $defaultRustupHome = Join-Path $env:USERPROFILE '.rustup'
    if ((Test-Path (Join-Path $defaultCargoHome 'bin')) -and -not (Test-Path $config['CargoHome'])) {
        $config['CargoHome'] = $defaultCargoHome
    }
    if ((Test-Path (Join-Path $defaultRustupHome 'toolchains')) -and -not (Test-Path $config['RustupHome'])) {
        $config['RustupHome'] = $defaultRustupHome
    }

    # Build parallelism: based on CPU count and available RAM
    try {
        $cpuCount = [Environment]::ProcessorCount
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        $freeGB = if ($os) { [math]::Round($os.FreePhysicalMemory / 1MB, 1) } else { 8 }

        # Each rustc instance uses ~1-2GB, so limit based on RAM
        $ramJobs = [math]::Max(2, [math]::Floor($freeGB / 2))
        $config['BuildJobs'] = [math]::Min([math]::Min($cpuCount, $ramJobs), 16)
    } catch {
        $config['BuildJobs'] = 4
    }

    # sccache settings
    $config['SccacheCacheSize'] = if ($config['CacheRoot'] -like 'T:\*') { '80G' } else { '30G' }
    $config['SccacheIdleTimeout'] = '3600'
    $config['MaxConcurrentBuilds'] = 1
    $config['QueuePollIntervalMs'] = 500
    $config['QueueStaleMinutes'] = 240

    # Machine metadata
    $config['Hostname'] = $env:COMPUTERNAME
    $config['LastSeen'] = (Get-Date -Format 'o')

    # Hardware and toolchain detection
    $gpus = @(Get-GpuInfo)
    if ($gpus.Count -gt 0) {
        $config['GpuName'] = $gpus[0].Name
        $config['CudaComputeCap'] = $gpus[0].ComputeCapFlat
        $config['GpuMemoryMB'] = $gpus[0].MemoryMB
    }

    $cuda = Get-CudaToolkitInfo
    if ($cuda) {
        $config['CudaPath'] = $cuda.Path
        $config['CudaVersion'] = $cuda.Version
    }

    $msvc = Get-MsvcInfo
    if ($msvc) {
        $config['MsvcVersion'] = $msvc.MsvcVersion
        $config['MsvcBinDir'] = $msvc.MsvcBinDir
        $config['MsvcLinkExe'] = $msvc.LinkExePath
        $config['MsvcLibDir'] = $msvc.MsvcLibDir
        $config['VsPath'] = $msvc.VsPath
    }

    $llvm = Get-LlvmInfo
    if ($llvm) {
        $config['LlvmPath'] = $llvm.Path
        $config['LlvmVersion'] = $llvm.Version
        $config['LldLinkExe'] = $llvm.LldLink
        $config['ClangClExe'] = $llvm.ClangCl
    }

    $sdk = Get-WindowsSdkInfo
    if ($sdk) {
        $config['WindowsSdkVersion'] = $sdk.SdkVer
        $config['WindowsSdkUmLib'] = $sdk.UmLibDir
        $config['WindowsSdkUcrtLib'] = $sdk.UcrtLibDir
    }

    return $config
}

function Register-CurrentMachine {
    <#
    .SYNOPSIS
    Registers the current machine in the CargoTools machine config file.
    #>
    param([hashtable]$Config)

    $configPath = Get-MachineConfigPath
    $configDir = Split-Path -Parent $configPath
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $machineId = Get-MachineIdentity
    $allConfigs = @{}

    if (Test-Path $configPath) {
        try {
            $existing = Get-Content $configPath -Raw | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) {
                $allConfigs[$prop.Name] = $prop.Value
            }
        } catch {}
    }

    # Convert config to a PSCustomObject for JSON serialization
    $entry = [PSCustomObject]@{}
    foreach ($key in $Config.Keys) {
        $entry | Add-Member -NotePropertyName $key -NotePropertyValue $Config[$key] -Force
    }

    $allConfigs[$machineId] = $entry
    $allConfigs | ConvertTo-Json -Depth 5 | Out-File $configPath -Encoding UTF8
    Write-Verbose "Registered machine '$machineId' in CargoTools config"
}

function Resolve-MachineAwareCacheRoot {
    <#
    .SYNOPSIS
    Returns the cache root for the current machine from machine config.
    Replaces the hardcoded T:\RustCache logic.
    #>
    param([string]$CacheRoot)

    # Explicit override takes priority
    if ($CacheRoot -and (Test-Path $CacheRoot)) { return $CacheRoot }

    # Machine config
    $mc = Get-MachineConfig
    $root = $mc['CacheRoot']

    # Validate the configured root is accessible
    $driveLetter = if ($root -match '^([A-Z]):') { $Matches[1] } else { $null }
    if ($driveLetter) {
        $driveRoot = "${driveLetter}:\"
        if (-not (Test-Path $driveRoot)) {
            # Configured drive is offline — fall back to local
            Write-Verbose "Cache drive $driveRoot not available, falling back to local"
            $root = Join-Path $env:LOCALAPPDATA 'RustCache'
        }
    }

    Ensure-Directory -Path $root
    return $root
}

function Get-GpuInfo {
    <#
    .SYNOPSIS
    Detects NVIDIA GPUs via nvidia-smi.
    #>
    [CmdletBinding()]
    param()

    $nvsmi = Find-CargoCommandPath -Name 'nvidia-smi'
    if (-not $nvsmi) {
        # Fallback: nvidia-smi is often in System32 or CUDA bin
        $fallbacks = @(
            (Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'),
            'C:\Program Files\NVIDIA Corporation\NVSMI\nvidia-smi.exe'
        )
        foreach ($fb in $fallbacks) {
            if (Test-Path $fb) { $nvsmi = $fb; break }
        }
    }
    if (-not $nvsmi) { return @() }

    try {
        $csv = & $nvsmi --query-gpu=name,compute_cap,memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $csv) { return @() }

        $gpus = @()
        foreach ($line in $csv) {
            $parts = $line -split ',\s*'
            if ($parts.Count -ge 3) {
                $cap = $parts[1].Trim()
                $gpus += [PSCustomObject]@{
                    Name                = $parts[0].Trim()
                    ComputeCapability   = $cap
                    ComputeCapFlat      = $cap -replace '\.', ''
                    MemoryMB            = [int]$parts[2].Trim()
                }
            }
        }
        return $gpus
    } catch {
        Write-Verbose "GPU detection failed: $_"
        return @()
    }
}

function Get-CudaToolkitInfo {
    <#
    .SYNOPSIS
    Detects installed CUDA toolkit versions.
    #>
    [CmdletBinding()]
    param(
        [string]$PreferredVersion = 'v13.1'
    )

    $cudaBase = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA'
    if (-not (Test-Path $cudaBase)) { return $null }

    $allVersions = @(Get-ChildItem -Path $cudaBase -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName 'bin\nvcc.exe')
    } | ForEach-Object { $_.Name })

    if ($allVersions.Count -eq 0) { return $null }

    # Prefer specified version, fallback to newest
    $selected = if ($PreferredVersion -and $allVersions -contains $PreferredVersion) {
        $PreferredVersion
    } else {
        $allVersions | Sort-Object -Descending | Select-Object -First 1
    }

    $cudaPath = Join-Path $cudaBase $selected
    $nvccExe = Join-Path $cudaPath 'bin\nvcc.exe'
    $nvccVer = $null
    try {
        $verOutput = & $nvccExe --version 2>$null
        if ($verOutput -match 'release\s+([\d.]+)') { $nvccVer = $Matches[1] }
    } catch {}

    return [PSCustomObject]@{
        Path         = $cudaPath
        Version      = $selected
        NvccVersion  = $nvccVer
        AllInstalled = $allVersions
    }
}

function Get-MsvcInfo {
    <#
    .SYNOPSIS
    Detects MSVC toolchain (Visual Studio + cl.exe/link.exe).
    #>
    [CmdletBinding()]
    param()

    $instances = @()
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        try {
            $json = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null
            if ($json) {
                $instances = @($json | ConvertFrom-Json | Where-Object { $_.isComplete -and $_.isLaunchable })
            }
        } catch {}
    }

    $vsPath = $null
    $vsVersion = $null
    $vsDisplayName = $null
    if ($instances.Count -gt 0) {
        $selected = $instances |
            Sort-Object @{ Expression = { [version]$_.installationVersion }; Descending = $true } |
            Select-Object -First 1
        $vsPath = $selected.installationPath
        $vsVersion = $selected.installationVersion
        $vsDisplayName = $selected.displayName
    }

    # Fallback for preview/dev boxes where vswhere lags behind a new VS layout.
    if (-not $vsPath) {
        $candidates = @(
            'C:\Program Files\Microsoft Visual Studio\2026\Enterprise',
            'C:\Program Files\Microsoft Visual Studio\2026\Professional',
            'C:\Program Files\Microsoft Visual Studio\2026\Community',
            'C:\Program Files\Microsoft Visual Studio\2026\BuildTools',
            'C:\Program Files\Microsoft Visual Studio\18\Insiders',
            'C:\Program Files\Microsoft Visual Studio\18\Preview',
            'C:\Program Files\Microsoft Visual Studio\18\BuildTools',
            'C:\Program Files\Microsoft Visual Studio\2022\Enterprise',
            'C:\Program Files\Microsoft Visual Studio\2022\Professional',
            'C:\Program Files\Microsoft Visual Studio\2022\Community',
            'C:\Program Files\Microsoft Visual Studio\2022\BuildTools',
            'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
            'C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools'
        )
        foreach ($candidate in $candidates) {
            $toolsRoot = Join-Path $candidate 'VC\Tools\MSVC'
            if (Test-Path $toolsRoot) {
                $vsPath = $candidate
                break
            }
        }
    }

    if (-not $vsPath -or -not (Test-Path $vsPath)) { return $null }

    # Find latest MSVC version
    $msvcBase = Join-Path $vsPath 'VC\Tools\MSVC'
    if (-not (Test-Path $msvcBase)) { return $null }

    $msvcVer = Get-ChildItem -Path $msvcBase -Directory |
        Sort-Object Name -Descending |
        Select-Object -First 1 -ExpandProperty Name

    if (-not $msvcVer) { return $null }

    $binDir = Join-Path $msvcBase "$msvcVer\bin\Hostx64\x64"
    $libDir = Join-Path $msvcBase "$msvcVer\lib\x64"

    return [PSCustomObject]@{
        VsPath        = $vsPath
        VsVersion     = $vsVersion
        VsDisplayName = $vsDisplayName
        MsvcVersion   = $msvcVer
        MsvcBinDir    = $binDir
        LinkExePath   = Join-Path $binDir 'link.exe'
        MsvcLibDir    = $libDir
    }
}

function Get-LlvmInfo {
    <#
    .SYNOPSIS
    Detects LLVM/Clang/LLD installation.
    #>
    [CmdletBinding()]
    param()

    $llvmPath = $null
    $candidates = @(
        $env:LLVM_PATH,
        'C:\Program Files\LLVM'
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $llvmPath = $c; break }
    }

    if (-not $llvmPath) { return $null }

    $binDir = Join-Path $llvmPath 'bin'
    if (-not (Test-Path $binDir)) { return $null }

    $lldLink = Join-Path $binDir 'lld-link.exe'
    $clangCl = Join-Path $binDir 'clang-cl.exe'
    $llvmAr  = Join-Path $binDir 'llvm-ar.exe'
    $libClang = Join-Path $binDir 'libclang.dll'

    # Get version
    $version = $null
    $clangExe = Join-Path $binDir 'clang.exe'
    if (Test-Path $clangExe) {
        try {
            $verOutput = & $clangExe --version 2>$null
            if ($verOutput -and $verOutput[0] -match '(\d+\.\d+\.\d+)') {
                $version = $Matches[1]
            }
        } catch {}
    }

    return [PSCustomObject]@{
        Path     = $llvmPath
        BinDir   = $binDir
        Version  = $version
        LldLink  = if (Test-Path $lldLink) { $lldLink } else { $null }
        ClangCl  = if (Test-Path $clangCl) { $clangCl } else { $null }
        LlvmAr   = if (Test-Path $llvmAr) { $llvmAr } else { $null }
        LibClang = if (Test-Path $libClang) { $libClang } else { $null }
    }
}

function Get-WindowsSdkInfo {
    <#
    .SYNOPSIS
    Detects Windows SDK installation and lib paths.
    #>
    [CmdletBinding()]
    param()

    $sdkBase = 'C:\Program Files (x86)\Windows Kits\10'
    $libBase = Join-Path $sdkBase 'Lib'
    if (-not (Test-Path $libBase)) { return $null }

    # Find latest SDK version
    $sdkVer = Get-ChildItem -Path $libBase -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
        Sort-Object Name -Descending |
        Select-Object -First 1 -ExpandProperty Name

    if (-not $sdkVer) { return $null }

    return [PSCustomObject]@{
        SdkBase    = $sdkBase
        SdkVer     = $sdkVer
        UmLibDir   = Join-Path $libBase "$sdkVer\um\x64"
        UcrtLibDir = Join-Path $libBase "$sdkVer\ucrt\x64"
    }
}
