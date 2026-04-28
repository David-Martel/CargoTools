function Get-RustupPath {
    foreach ($candidate in @(
        $(if ($env:CARGO_HOME) { Join-Path $env:CARGO_HOME 'bin\rustup.exe' }),
        'T:\RustCache\cargo-home\bin\rustup.exe',
        (Join-Path $env:USERPROFILE '.cargo\bin\rustup.exe')
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    return "$env:USERPROFILE\.cargo\bin\rustup.exe"
}

function Resolve-CargoToolsFastCacheRoot {
    [CmdletBinding()]
    param()

    foreach ($candidate in @(
        $env:CARGOTOOLS_CACHE_ROOT,
        $env:PCAI_CACHE_ROOT,
        'T:\RustCache',
        (Join-Path $env:LOCALAPPDATA 'RustCache')
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return (Join-Path $env:LOCALAPPDATA 'RustCache')
}

function Resolve-CargoToolsFastCargoHome {
    [CmdletBinding()]
    param()

    foreach ($candidate in @(
        $env:CARGO_HOME,
        (Join-Path (Resolve-CargoToolsFastCacheRoot) 'cargo-home'),
        (Join-Path $HOME '.cargo')
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return (Join-Path $HOME '.cargo')
}

function Resolve-CargoToolsFastRustupHome {
    [CmdletBinding()]
    param()

    foreach ($candidate in @(
        $env:RUSTUP_HOME,
        (Join-Path (Resolve-CargoToolsFastCacheRoot) 'rustup'),
        (Join-Path $HOME '.rustup')
    )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return (Join-Path $HOME '.rustup')
}

function Import-CargoToolsAccelerationStack {
    if (Get-Variable -Name CargoToolsAccelerationBootstrapStatus -Scope Script -ErrorAction SilentlyContinue) {
        return $script:CargoToolsAccelerationBootstrapStatus
    }

    $script:CargoToolsAccelerationBootstrapStatus = $null

    try {
        Import-Module 'PC-AI.Common' -ErrorAction Stop | Out-Null
    } catch {
        foreach ($candidate in @(
            (Join-Path (Join-Path $HOME 'Documents\PowerShell\Modules') 'PC-AI.Common\PC-AI.Common.psm1'),
            (Join-Path (Join-Path $HOME 'OneDrive\Documents\PowerShell\Modules') 'PC-AI.Common\PC-AI.Common.psm1'),
            'C:\codedev\PC_AI\Modules\PC-AI.Common\PC-AI.Common.psm1'
        )) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            try {
                Import-Module $candidate -ErrorAction Stop | Out-Null
                break
            } catch {}
        }
    }

    if (Get-Command Import-PcaiAccelerationStack -ErrorAction SilentlyContinue) {
        try {
            $script:CargoToolsAccelerationBootstrapStatus = Import-PcaiAccelerationStack -Modules @('ProfileAccelerator')
        } catch {
            $script:CargoToolsAccelerationBootstrapStatus = $null
        }
    }

    return $script:CargoToolsAccelerationBootstrapStatus
}

if (-not (Get-Variable -Name CargoToolsCommandPathCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CargoToolsCommandPathCache = @{}
}
if (-not (Get-Variable -Name CargoToolsUseProfileAccelerator -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CargoToolsUseProfileAccelerator = $false
}
if (-not (Get-Variable -Name CargoToolsAccelerationInitialized -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CargoToolsAccelerationInitialized = $false
}
if (-not (Get-Variable -Name CargoToolsGlobalRustfmtInitialized -Scope Script -ErrorAction SilentlyContinue)) {
    $script:CargoToolsGlobalRustfmtInitialized = $false
}

function Initialize-CargoToolsCommandAcceleration {
    if ($script:CargoToolsAccelerationInitialized) {
        return $script:CargoToolsUseProfileAccelerator
    }

    $script:CargoToolsAccelerationInitialized = $true
    $bootstrapStatus = Import-CargoToolsAccelerationStack
    if ($bootstrapStatus) {
        $script:CargoToolsUseProfileAccelerator = [bool]$bootstrapStatus.CommandLookupAvailable
        return $script:CargoToolsUseProfileAccelerator
    }

    try {
        if (Get-Command Test-AcceleratorAvailable -ErrorAction SilentlyContinue) {
            $script:CargoToolsUseProfileAccelerator = [bool](Test-AcceleratorAvailable)
        }
    } catch {
        $script:CargoToolsUseProfileAccelerator = $false
    }

    return $script:CargoToolsUseProfileAccelerator
}

function Find-CargoCommandPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$BypassCache,
        [switch]$AllowNonExternal
    )

    $cacheKey = if ($AllowNonExternal) { "any::$Name" } else { "exe::$Name" }
    if (-not $BypassCache -and $script:CargoToolsCommandPathCache.ContainsKey($cacheKey)) {
        return $script:CargoToolsCommandPathCache[$cacheKey]
    }

    $resolved = $null
    Initialize-CargoToolsCommandAcceleration | Out-Null

    if ($script:CargoToolsUseProfileAccelerator -and (Get-Command Find-CommandCached -ErrorAction SilentlyContinue)) {
        try { $resolved = Find-CommandCached -Name $Name } catch { $resolved = $null }
    }

    if (-not $resolved -and $script:CargoToolsUseProfileAccelerator -and (Get-Command Find-CommandNative -ErrorAction SilentlyContinue)) {
        try { $resolved = Find-CommandNative -Name $Name } catch { $resolved = $null }
    }

    if (-not $resolved) {
        $cmd = $null
        try {
            if ($AllowNonExternal) {
                $cmd = Get-Command $Name -ErrorAction SilentlyContinue
            } else {
                $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue
            }
        } catch {
            $cmd = $null
        }

        if ($cmd) {
            $resolved = if ($cmd.Source) { $cmd.Source } else { $cmd.Path }
        }
    }

    if (-not $BypassCache) {
        $script:CargoToolsCommandPathCache[$cacheKey] = $resolved
    }
    return $resolved
}

function Test-CargoCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [switch]$BypassCache,
        [switch]$AllowNonExternal
    )

    return [bool](Find-CargoCommandPath -Name $Name -BypassCache:$BypassCache -AllowNonExternal:$AllowNonExternal)
}

function Resolve-RustAnalyzerPath {
    <#
    .SYNOPSIS
    Resolves the canonical rust-analyzer executable path.
    .DESCRIPTION
    Finds rust-analyzer in priority order:
    1. RUST_ANALYZER_PATH environment variable
    2. Active rustup toolchain
    3. Known installation locations
    Avoids Get-Command which may find broken shims or wrong versions.
    #>
    [CmdletBinding()]
    param()

    # Priority 1: Explicit environment variable (validate it's a real executable, not empty shim)
    if ($env:RUST_ANALYZER_PATH -and (Test-Path $env:RUST_ANALYZER_PATH)) {
        $fileInfo = Get-Item $env:RUST_ANALYZER_PATH -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt 1000) {
            return $env:RUST_ANALYZER_PATH
        }
        Write-Verbose "RUST_ANALYZER_PATH points to invalid file (size: $($fileInfo.Length) bytes), skipping"
    }

    $rustupHome = Resolve-CargoToolsFastRustupHome
    $cargoHome = Resolve-CargoToolsFastCargoHome
    $cacheRoot = Resolve-CargoToolsFastCacheRoot

    # Priority 2: Query rustup for active toolchain
    $rustupPath = Get-RustupPath
    if (Test-Path $rustupPath) {
        try {
            $toolchainOutput = & $rustupPath show active-toolchain 2>$null
            if ($toolchainOutput -match '^([^\s]+)') {
                $toolchain = $Matches[1]
                $raPath = Join-Path $rustupHome "toolchains\$toolchain\bin\rust-analyzer.exe"
                if (Test-Path $raPath) {
                    return $raPath
                }
            }
        } catch {
            Write-Verbose "Rustup query failed: $_"
        }
    }

    # Priority 3: Known locations (lightweight, no machine probing)
    $knownPaths = @(
        (Join-Path $cacheRoot 'rustup\toolchains\stable-x86_64-pc-windows-msvc\bin\rust-analyzer.exe'),
        (Join-Path $cacheRoot 'rustup\toolchains\nightly-x86_64-pc-windows-msvc\bin\rust-analyzer.exe'),
        (Join-Path $rustupHome 'toolchains\stable-x86_64-pc-windows-msvc\bin\rust-analyzer.exe'),
        (Join-Path $rustupHome 'toolchains\nightly-x86_64-pc-windows-msvc\bin\rust-analyzer.exe'),
        (Join-Path $cargoHome 'bin\rust-analyzer.exe'),
        (Join-Path $HOME '.cargo\bin\rust-analyzer.exe')
    )

    foreach ($path in $knownPaths) {
        if (Test-Path $path) {
            $fileInfo = Get-Item $path
            # Verify it's not a 0-byte empty file
            if ($fileInfo.Length -gt 1000) {
                return $path
            }
        }
    }

    return $null
}

function Resolve-LspmuxPath {
    <#
    .SYNOPSIS
    Resolves the canonical lspmux executable path.
    .DESCRIPTION
    Checks explicit environment overrides, accelerated PATH lookup, and known
    cargo-home locations. Returns $null if lspmux is not installed.
    #>
    [CmdletBinding()]
    param()

    if ($env:LSPMUX_PATH -and (Test-Path $env:LSPMUX_PATH)) {
        $fileInfo = Get-Item $env:LSPMUX_PATH -ErrorAction SilentlyContinue
        if ($fileInfo -and $fileInfo.Length -gt 1000) {
            return $env:LSPMUX_PATH
        }
    }

    $cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $HOME '.cargo' }
    $knownPaths = @(
        (Join-Path 'T:\RustCache' 'cargo-home\bin\lspmux.exe'),
        (Join-Path $cargoHome 'bin\lspmux.exe'),
        (Join-Path $HOME '.cargo\bin\lspmux.exe')
    )

    foreach ($path in $knownPaths) {
        if (Test-Path $path) {
            $fileInfo = Get-Item $path -ErrorAction SilentlyContinue
            if ($fileInfo -and $fileInfo.Length -gt 1000) {
                return $path
            }
        }
    }

    return $null
}

function Test-RustAnalyzerStandaloneInvocation {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$ArgumentList
    )

    $argsList = @($ArgumentList | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($argsList.Count -eq 0) {
        return $false
    }

    if ($argsList -contains '--help' -or $argsList -contains '-h' -or $argsList -contains '--version' -or $argsList -contains '-V') {
        return $true
    }

    $directCommands = @(
        'analysis-stats',
        'diagnostics',
        'highlight',
        'lsif',
        'parse',
        'proc-macro',
        'run-tests',
        'scip',
        'search',
        'ssr',
        'syntax-tree',
        'unresolved-references'
    )

    foreach ($arg in $argsList) {
        if (-not $arg.StartsWith('-')) {
            return ($directCommands -contains $arg)
        }
    }

    return $false
}

function Resolve-RustAnalyzerTransportMode {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]]$ArgumentList,
        [ValidateSet('auto', 'direct', 'lspmux')]
        [string]$Preference
    )

    $effectivePreference = if ($Preference) {
        $Preference.ToLowerInvariant()
    } elseif ($env:CARGOTOOLS_RA_TRANSPORT) {
        $env:CARGOTOOLS_RA_TRANSPORT.ToLowerInvariant()
    } elseif ($env:RUST_ANALYZER_TRANSPORT) {
        $env:RUST_ANALYZER_TRANSPORT.ToLowerInvariant()
    } else {
        'auto'
    }

    $lspmuxPath = Resolve-LspmuxPath
    $directInvocation = Test-RustAnalyzerStandaloneInvocation -ArgumentList $ArgumentList
    $effective = 'direct'
    $reason = 'direct fallback'

    switch ($effectivePreference) {
        'direct' {
            $effective = 'direct'
            $reason = 'forced direct transport'
        }
        'lspmux' {
            if ($lspmuxPath) {
                $effective = 'lspmux'
                $reason = 'forced lspmux transport'
            } else {
                $effective = 'direct'
                $reason = 'lspmux requested but not installed'
            }
        }
        default {
            if ($lspmuxPath -and -not $directInvocation) {
                $effective = 'lspmux'
                $reason = 'interactive/stdin LSP session'
            } else {
                $effective = 'direct'
                $reason = if ($directInvocation) { 'standalone rust-analyzer command' } else { 'lspmux unavailable' }
            }
        }
    }

    [pscustomobject]@{
        Preference = $effectivePreference
        Effective = $effective
        LspmuxPath = $lspmuxPath
        DirectInvocation = $directInvocation
        Reason = $reason
    }
}

function Get-RustAnalyzerMemoryMB {
    <#
    .SYNOPSIS
    Gets total memory usage of all rust-analyzer processes in MB.
    #>
    $procs = @(Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $total = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum
        return [math]::Round($total / 1MB, 0)
    }
    return 0
}

function Test-RustAnalyzerSingleton {
    <#
    .SYNOPSIS
    Tests if rust-analyzer singleton is properly enforced.
    .OUTPUTS
    PSCustomObject with Status, ProcessCount, MemoryMB, LockFileExists, Issues
    #>
    [CmdletBinding()]
    param(
        [int]$WarnThresholdMB = 1500
    )

    $result = [PSCustomObject]@{
        Status = 'Unknown'
        ProcessCount = 0
        MemoryMB = 0
        LockFileExists = $false
        LockFilePID = $null
        Issues = @()
    }

    # Check processes
    $procs = @(Get-Process -Name 'rust-analyzer' -ErrorAction SilentlyContinue |
               Where-Object { $_.ProcessName -eq 'rust-analyzer' })
    $result.ProcessCount = $procs.Count
    $result.MemoryMB = Get-RustAnalyzerMemoryMB

    # Check lock file (dynamically resolved)
    $cacheRoot = Resolve-CargoToolsFastCacheRoot
    $lockFile = Join-Path $cacheRoot 'rust-analyzer\ra.lock'
    $result.LockFileExists = Test-Path $lockFile
    if ($result.LockFileExists) {
        $content = Get-Content $lockFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($content -match '^\d+$') {
            $result.LockFilePID = [int]$content
        }
    }

    # Analyze issues
    if ($result.ProcessCount -eq 0) {
        $result.Status = 'NotRunning'
    } elseif ($result.ProcessCount -eq 1) {
        if ($result.MemoryMB -gt $WarnThresholdMB) {
            $result.Status = 'HighMemory'
            $result.Issues += "Memory usage ($($result.MemoryMB)MB) exceeds threshold (${WarnThresholdMB}MB)"
        } else {
            $result.Status = 'Healthy'
        }
    } else {
        $result.Status = 'MultipleInstances'
        $result.Issues += "Multiple rust-analyzer processes detected ($($result.ProcessCount))"
    }

    # Check lock file consistency
    if ($result.ProcessCount -gt 0 -and -not $result.LockFileExists) {
        $result.Issues += 'No lock file - wrapper may not be in use'
    }
    if ($result.LockFileExists -and $result.LockFilePID) {
        $lockProc = Get-Process -Id $result.LockFilePID -ErrorAction SilentlyContinue
        if (-not $lockProc) {
            $result.Issues += "Stale lock file (PID $($result.LockFilePID) not running)"
        }
    }

    return $result
}

function Test-IsWindows {
    return ($env:OS -eq 'Windows_NT')
}

function Resolve-UserScript {
    param([string]$Name)
    $candidates = @(
        (Join-Path $env:USERPROFILE "bin\\$Name"),
        (Join-Path $env:USERPROFILE ".local\\bin\\$Name")
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Ensure-MsvcEnv {
    if (-not (Test-IsWindows)) { return }

    $forceMsvcBootstrap = $env:CARGOTOOLS_FORCE_MSVC_ENV -and $env:CARGOTOOLS_FORCE_MSVC_ENV -ne '0'
    $alreadyBootstrapped = $env:CARGOTOOLS_MSVC_ENV_INITIALIZED -eq '1'
    $hasCompilerEnv = $env:VCINSTALLDIR -and $env:LIB -and $env:INCLUDE
    if ($hasCompilerEnv -and $alreadyBootstrapped -and -not $forceMsvcBootstrap) { return }

    $msvcEnv = Resolve-UserScript 'msvc-env.ps1'
    if (-not $msvcEnv) { return }

    # Prefer VS version from env, falling back to VS 2026/18.x if installed, then latest.
    $vsVersionArg = $env:CARGOTOOLS_VS_VERSION
    if (-not $vsVersionArg) {
        $msvcInfo = Get-MsvcInfo
        if ($msvcInfo -and $msvcInfo.VsPath) {
            if ($msvcInfo.VsPath -match '\\(2026|18)\\') {
                $vsVersionArg = '2026'
            } elseif ($msvcInfo.VsVersion -and ([version]$msvcInfo.VsVersion).Major -ge 18) {
                $vsVersionArg = '2026'
            } elseif ($msvcInfo.VsPath -match '\\2022\\') {
                $vsVersionArg = '2022'
            }
        }
    }

    try {
        $msvcArgs = @('-Arch', 'x64', '-HostArch', 'x64', '-NoChocoRefresh')
        if ($vsVersionArg) {
            $msvcArgs += @('-VSVersion', $vsVersionArg)
        }
        & $msvcEnv @msvcArgs | Out-Null
        $env:CARGOTOOLS_MSVC_ENV_INITIALIZED = '1'
    } catch {
        Write-Warning "Unable to load MSVC environment via ${msvcEnv}: $_"
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Resolve-CacheRoot {
    param([string]$CacheRoot)

    if (-not $CacheRoot) {
        if ($env:CARGOTOOLS_CACHE_ROOT) {
            $CacheRoot = $env:CARGOTOOLS_CACHE_ROOT
        } elseif ($env:PCAI_CACHE_ROOT) {
            $CacheRoot = $env:PCAI_CACHE_ROOT
        }
    }

    # Delegate to machine-aware resolver (Private/MachineConfig.ps1)
    return Resolve-MachineAwareCacheRoot -CacheRoot $CacheRoot
}

function Get-CargoTargetMode {
    [CmdletBinding()]
    param()

    if ($env:CARGOTOOLS_TARGET_MODE) {
        return $env:CARGOTOOLS_TARGET_MODE.ToLowerInvariant()
    }

    $mc = Get-MachineConfig
    if ($mc['TargetMode']) {
        return ([string]$mc['TargetMode']).ToLowerInvariant()
    }

    return 'local'
}

function Convert-WindowsPathToWslPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $driveMatch = [regex]::Match($fullPath, '^(?<drive>[A-Za-z]):\\(?<rest>.*)$')
    if ($driveMatch.Success) {
        $drive = $driveMatch.Groups['drive'].Value.ToLowerInvariant()
        $rest = $driveMatch.Groups['rest'].Value -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($rest)) {
            return "/mnt/$drive"
        }

        return "/mnt/$drive/$rest"
    }

    return ($fullPath -replace '\\', '/')
}

function Resolve-WslSharedCacheRoot {
    [CmdletBinding()]
    param(
        [string]$CacheRoot
    )

    $resolvedRoot = Resolve-CacheRoot -CacheRoot $CacheRoot
    if (-not $resolvedRoot) {
        return $null
    }

    return Convert-WindowsPathToWslPath -Path $resolvedRoot
}

function Resolve-Sccache {
    return (Find-CargoCommandPath -Name 'sccache')
}

function Get-SanitizedPath {
    <#
    .SYNOPSIS
    Returns PATH with known conflicting compiler directories removed.
    .DESCRIPTION
    Strips Strawberry Perl gcc.exe directory and Git mingw64/bin to prevent
    them from shadowing MSVC cl.exe/link.exe during Windows-native builds.
    #>
    [CmdletBinding()]
    param([string]$CurrentPath = $env:PATH)

    $conflictPatterns = @(
        '*\Strawberry\c\bin*',
        '*\Strawberry\perl\bin*',
        '*\Git\mingw64\bin*',
        '*\Git\usr\bin*'
    )

    $parts = $CurrentPath -split ';' | Where-Object { $_ -and $_.Trim() }
    $cleaned = @()
    $removed = @()

    foreach ($part in $parts) {
        $isConflict = $false
        foreach ($pattern in $conflictPatterns) {
            if ($part -like $pattern) {
                $isConflict = $true
                $removed += $part
                break
            }
        }
        if (-not $isConflict) { $cleaned += $part }
    }

    if ($removed.Count -gt 0) {
        Write-Verbose "[CargoTools] Sanitized PATH: removed $($removed -join ', ')"
    }

    return $cleaned -join ';'
}

function Get-MsvcClExePath {
    <#
    .SYNOPSIS
    Resolves the absolute path to MSVC cl.exe (not Strawberry/MinGW).
    #>
    [CmdletBinding()]
    param()

    # Prefer explicit VCToolsInstallDir when present
    if ($env:VCToolsInstallDir) {
        $msvcCl = Join-Path $env:VCToolsInstallDir 'bin\\Hostx64\\x64\\cl.exe'
        if (Test-Path $msvcCl) { return $msvcCl }
    }

    # VCINSTALLDIR may point either to the VC root or directly to a tools version
    if ($env:VCINSTALLDIR) {
        $directCl = Join-Path $env:VCINSTALLDIR 'bin\\Hostx64\\x64\\cl.exe'
        if (Test-Path $directCl) { return $directCl }

        $toolsRoot = Join-Path $env:VCINSTALLDIR 'Tools\\MSVC'
        if (Test-Path $toolsRoot) {
            $latestToolsDir = Get-ChildItem -LiteralPath $toolsRoot -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                Select-Object -First 1

            if ($latestToolsDir) {
                $nestedCl = Join-Path $latestToolsDir.FullName 'bin\\Hostx64\\x64\\cl.exe'
                if (Test-Path $nestedCl) { return $nestedCl }
            }
        }
    }

    # Search PATH but skip known conflict directories
    $cleanPath = Get-SanitizedPath
    foreach ($dir in ($cleanPath -split ';')) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir 'cl.exe'
        if ((Test-Path $candidate) -and $dir -notlike '*Strawberry*' -and $dir -notlike '*mingw*') {
            return $candidate
        }
    }

    return $null
}

function Test-RustToolchainHealth {
    <#
    .SYNOPSIS
    Validates that rustup can compile metadata with a toolchain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Toolchain,

        [string]$RustupPath = (Get-RustupPath)
    )

    if (-not (Get-Variable -Scope Script -Name CargoToolsToolchainHealthCache -ErrorAction SilentlyContinue)) {
        $script:CargoToolsToolchainHealthCache = @{}
    }

    $cacheKey = "$RustupPath|$Toolchain"
    if ($script:CargoToolsToolchainHealthCache.ContainsKey($cacheKey)) {
        return $script:CargoToolsToolchainHealthCache[$cacheKey]
    }

    $result = [ordered]@{
        Toolchain = $Toolchain
        Healthy   = $false
        Rustc     = $null
        Error     = $null
    }

    if (-not $RustupPath -or -not (Test-Path $RustupPath)) {
        $result.Error = 'rustup.exe not found'
        $obj = [PSCustomObject]$result
        $script:CargoToolsToolchainHealthCache[$cacheKey] = $obj
        return $obj
    }

    $probeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cargotools-rust-probe-" + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
        $sourcePath = Join-Path $probeDir 'main.rs'
        $outputPath = Join-Path $probeDir 'probe.rmeta'
        Set-Content -LiteralPath $sourcePath -Value 'fn main() {}' -Encoding UTF8

        $rustcVersion = & $RustupPath run $Toolchain rustc --version 2>$null
        if ($LASTEXITCODE -eq 0) { $result.Rustc = [string]$rustcVersion }

        $probeOutput = & $RustupPath run $Toolchain rustc --crate-name cargotools_probe --edition=2021 $sourcePath --emit=metadata -o $outputPath 2>&1
        if ($LASTEXITCODE -eq 0) {
            $result.Healthy = $true
        } else {
            $result.Error = ($probeOutput | Out-String).Trim()
        }
    } catch {
        $result.Error = "toolchain health probe failed: $_"
    } finally {
        Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    $obj = [PSCustomObject]$result
    $script:CargoToolsToolchainHealthCache[$cacheKey] = $obj
    return $obj
}

function Get-InstalledRustToolchains {
    [CmdletBinding()]
    param([string]$RustupPath = (Get-RustupPath))

    if (-not $RustupPath -or -not (Test-Path $RustupPath)) { return @() }
    try {
        $lines = & $RustupPath toolchain list 2>$null
        $toolchains = @()
        foreach ($line in $lines) {
            if ($line -match '^([^\s]+)') {
                $toolchains += $Matches[1]
            }
        }
        return $toolchains | Select-Object -Unique
    } catch {
        return @()
    }
}

function Resolve-CargoToolchain {
    <#
    .SYNOPSIS
    Selects a healthy rustup toolchain for CargoTools cargo invocations.
    .DESCRIPTION
    Honors explicit/env overrides first. Otherwise validates the active
    toolchain and falls back to the newest installed versioned MSVC toolchain
    before using prerelease/nightly entries. This avoids a broken rustup
    alias/sysroot from taking down every wrapper command.
    #>
    [CmdletBinding()]
    param(
        [string]$RustupPath = (Get-RustupPath),
        [string]$RequestedToolchain
    )

    if ($RequestedToolchain) { return $RequestedToolchain.TrimStart('+') }
    foreach ($envName in @('CARGOTOOLS_RUST_TOOLCHAIN', 'CARGO_TOOLCHAIN', 'RUSTUP_TOOLCHAIN')) {
        $value = [Environment]::GetEnvironmentVariable($envName)
        if ($value) { return $value.TrimStart('+') }
    }

    if (-not $RustupPath -or -not (Test-Path $RustupPath)) { return 'stable' }

    $active = $null
    try {
        $activeOutput = & $RustupPath show active-toolchain 2>$null
        if ($activeOutput -match '^([^\s]+)') { $active = $Matches[1] }
    } catch {}

    $installed = @(Get-InstalledRustToolchains -RustupPath $RustupPath)
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($active) { $candidates.Add($active) }

    $versioned = @($installed | Where-Object { $_ -match '^\d+\.\d+\.\d+.*windows-msvc$' } |
        Sort-Object @{ Expression = { [version]($_ -replace '-.*$', '') }; Descending = $true })
    foreach ($toolchain in $versioned) {
        if (-not $candidates.Contains($toolchain)) { $candidates.Add($toolchain) }
    }
    foreach ($toolchain in $installed) {
        if (-not $candidates.Contains($toolchain)) { $candidates.Add($toolchain) }
    }

    foreach ($toolchain in $candidates) {
        $health = Test-RustToolchainHealth -Toolchain $toolchain -RustupPath $RustupPath
        if ($health.Healthy) { return $toolchain }
    }

    if ($active) { return $active }
    return 'stable'
}

function Initialize-CargoEnv {
    param(
        [string]$CacheRoot
    )

    # Resolve machine-aware cache root if not explicitly provided
    if (-not $CacheRoot) {
        $mc = Get-MachineConfig
        $CacheRoot = $mc['CacheRoot']
    }

    Ensure-MsvcEnv

    if (-not $script:CargoToolsGlobalRustfmtInitialized) {
        $disableGlobalRustfmtSync = $env:CARGOTOOLS_DISABLE_GLOBAL_RUSTFMT_SYNC -and (Test-Truthy $env:CARGOTOOLS_DISABLE_GLOBAL_RUSTFMT_SYNC)
        if (-not $disableGlobalRustfmtSync -and (Get-Command Initialize-RustDefaults -ErrorAction SilentlyContinue)) {
            try {
                Initialize-RustDefaults -Scope Rustfmt | Out-Null
            } catch {
                Write-Verbose "CargoTools: global rustfmt initialization failed: $($_.Exception.Message)"
            }
        }
        $script:CargoToolsGlobalRustfmtInitialized = $true
    }

    if (Test-IsWindows) {
        $msvcCl = Get-MsvcClExePath
        if ($msvcCl) {
            if (-not $env:CC -or ($env:CC -eq 'cl.exe')) { $env:CC = $msvcCl }
            if (-not $env:CXX -or ($env:CXX -eq 'cl.exe')) { $env:CXX = $msvcCl }
        }
        # Sanitize PATH to prevent Strawberry Perl/Git mingw from shadowing MSVC
        $env:PATH = Get-SanitizedPath
    }

    if ($env:CL) {
        $clValue = $env:CL
        $isPathLike = ($clValue -match '[A-Za-z]:') -or ($clValue -match '\\') -or ($clValue -match '/')
        $isOption = $clValue.TrimStart().StartsWith('/') -or $clValue.TrimStart().StartsWith('-')
        if ($isPathLike -and -not $isOption) {
            Remove-Item Env:CL -ErrorAction SilentlyContinue
        }
    }

    $CacheRoot = Resolve-CacheRoot -CacheRoot $CacheRoot
    $sccacheExe = Resolve-Sccache
    if ($sccacheExe) {
        $env:RUSTC_WRAPPER = 'sccache'
    } else {
        if (Test-Path Env:RUSTC_WRAPPER) { Remove-Item Env:RUSTC_WRAPPER }
        $env:SCCACHE_DISABLE = '1'
        Write-Warning 'sccache not found; disabling RUSTC_WRAPPER for this session.'
    }
    if (-not $env:CARGO_INCREMENTAL) { $env:CARGO_INCREMENTAL = '0' }

    # CARGO_INCREMENTAL=1 with sccache silently destroys cache hit rates (sccache#236)
    if ($env:CARGO_INCREMENTAL -eq '1' -and $env:RUSTC_WRAPPER -eq 'sccache') {
        Write-Warning '[CargoTools] CARGO_INCREMENTAL=1 with sccache severely reduces cache hit rates. Setting CARGO_INCREMENTAL=0.'
        $env:CARGO_INCREMENTAL = '0'
    }

    if (-not $env:SCCACHE_DIR) { $env:SCCACHE_DIR = Join-Path $CacheRoot 'sccache' }
    if (-not $env:SCCACHE_CACHE_COMPRESSION) { $env:SCCACHE_CACHE_COMPRESSION = 'zstd' }
    $mc = Get-MachineConfig

    if (-not $env:SCCACHE_CACHE_SIZE) { $env:SCCACHE_CACHE_SIZE = if ($mc['SccacheCacheSize']) { $mc['SccacheCacheSize'] } else { '30G' } }
    if (-not $env:SCCACHE_IDLE_TIMEOUT) { $env:SCCACHE_IDLE_TIMEOUT = if ($mc['SccacheIdleTimeout']) { $mc['SccacheIdleTimeout'] } else { '3600' } }
    # Fallbacks for non-cargo invocations; .cargo/config.toml is the source of truth
    if (-not $env:SCCACHE_STARTUP_TIMEOUT) { $env:SCCACHE_STARTUP_TIMEOUT = '30' }
    if (-not $env:SCCACHE_REQUEST_TIMEOUT) { $env:SCCACHE_REQUEST_TIMEOUT = '180' }
    if (-not $env:SCCACHE_DIRECT) { $env:SCCACHE_DIRECT = 'true' }
    if (-not $env:SCCACHE_SERVER_PORT) { $env:SCCACHE_SERVER_PORT = '4226' }
    if (-not $env:SCCACHE_LOG) { $env:SCCACHE_LOG = 'warn' }
    if (-not $env:SCCACHE_ERROR_LOG) { $env:SCCACHE_ERROR_LOG = (Join-Path $CacheRoot 'sccache\error.log') }
    if (-not $env:SCCACHE_NO_DAEMON) { $env:SCCACHE_NO_DAEMON = '0' }
    if (-not $env:SCCACHE_MAX_CONNECTIONS) { $env:SCCACHE_MAX_CONNECTIONS = '8' }  # Matches .cargo/config.toml

    # Auto-enable lld-link when installed (significantly faster linking)
    if (-not $env:CARGO_USE_LLD) {
        $lldDefault = 'C:\Program Files\LLVM\bin\lld-link.exe'
        if (($env:CARGO_LLD_PATH -and (Test-Path $env:CARGO_LLD_PATH)) -or (Test-Path $lldDefault)) {
            $env:CARGO_USE_LLD = '1'
        } else {
            # Fallback: check for bundled rust-lld in active toolchain
            $bundledLld = Resolve-BundledRustLld
            if ($bundledLld) {
                $env:CARGO_USE_LLD = '1'
            } else {
                $env:CARGO_USE_LLD = '0'
            }
        }
    }
    if (-not $env:CARGO_USE_FASTLINK) { $env:CARGO_USE_FASTLINK = '0' }
    if (-not $env:CARGO_LLD_PATH) {
        $lldDefault = 'C:\Program Files\LLVM\bin\lld-link.exe'
        if (Test-Path $lldDefault) {
            $env:CARGO_LLD_PATH = $lldDefault
        }
    }

    # When lld-link is the active linker, ensure LIB has MSVC + SDK paths
    $activeLld = $env:CARGO_LLD_PATH
    if ($activeLld -and (Test-Path $activeLld) -and $activeLld -match 'lld-link') {
        $mc = Get-MachineConfig
        $libPaths = @($mc['MsvcLibDir'], $mc['WindowsSdkUmLib'], $mc['WindowsSdkUcrtLib']) |
            Where-Object { $_ -and (Test-Path $_) }
        if ($libPaths.Count -gt 0) {
            $existingLib = $env:LIB
            foreach ($lp in $libPaths) {
                if (-not $existingLib -or $existingLib -notlike "*$lp*") {
                    $existingLib = if ($existingLib) { "$lp;$existingLib" } else { $lp }
                }
            }
            $env:LIB = $existingLib
        }
    }

    # rust-analyzer memory optimization
    if (-not $env:RA_LRU_CAPACITY) { $env:RA_LRU_CAPACITY = '64' }  # Limit LRU cache entries
    if (-not $env:CHALK_SOLVER_MAX_SIZE) { $env:CHALK_SOLVER_MAX_SIZE = '10' }  # Limit trait solver
    if (-not $env:RA_PROC_MACRO_WORKERS) { $env:RA_PROC_MACRO_WORKERS = '1' }  # Single proc-macro worker
    if (-not $env:RUST_ANALYZER_CACHE_DIR) { $env:RUST_ANALYZER_CACHE_DIR = Join-Path $CacheRoot 'ra-cache' }

    # Build job limits for memory management
    if (-not $env:CARGO_BUILD_JOBS) { $env:CARGO_BUILD_JOBS = (Get-OptimalBuildJobs) }  # Prevent paging file exhaustion

    # Auto-enable nextest for test commands when installed
    if (-not $env:CARGO_USE_NEXTEST) {
        if (Test-CargoCommand -Name 'cargo-nextest') {
            $env:CARGO_USE_NEXTEST = '1'
        }
    }

    # CMake: prefer Ninja generator for native C/C++ dependencies in build.rs
    if (-not $env:CMAKE_GENERATOR) {
        if (Test-CargoCommand -Name 'ninja') { $env:CMAKE_GENERATOR = 'Ninja' }
    }

    # Parallel make/cmake for native deps
    $optimalJobs = Get-OptimalBuildJobs
    if (-not $env:MAKEFLAGS) { $env:MAKEFLAGS = "-j$optimalJobs" }
    if (-not $env:CMAKE_BUILD_PARALLEL_LEVEL) { $env:CMAKE_BUILD_PARALLEL_LEVEL = "$optimalJobs" }

    # Use machine-config-aware defaults for shared caches, but keep project target dirs local by default.
    $targetMode = Get-CargoTargetMode
    if (-not $env:CARGO_TARGET_DIR -and $targetMode -eq 'shared') { $env:CARGO_TARGET_DIR = if ($mc['CargoTargetDir']) { $mc['CargoTargetDir'] } else { Join-Path $CacheRoot 'cargo-target' } }
    if (-not $env:CARGO_HOME) { $env:CARGO_HOME = if ($mc['CargoHome']) { $mc['CargoHome'] } else { Join-Path $CacheRoot 'cargo-home' } }
    if (-not $env:RUSTUP_HOME) { $env:RUSTUP_HOME = if ($mc['RustupHome']) { $mc['RustupHome'] } else { Join-Path $CacheRoot 'rustup' } }

    Ensure-Directory -Path $env:SCCACHE_DIR
    if ($env:CARGO_TARGET_DIR) { Ensure-Directory -Path $env:CARGO_TARGET_DIR }
    Ensure-Directory -Path $env:CARGO_HOME
    Ensure-Directory -Path $env:RUSTUP_HOME
    if ($env:RUST_ANALYZER_CACHE_DIR) { Ensure-Directory -Path $env:RUST_ANALYZER_CACHE_DIR }
}

function Get-SccacheMemoryMB {
    $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $total = ($procs | Measure-Object -Property WorkingSet64 -Sum).Sum
        return [math]::Round($total / 1MB, 0)
    }
    return 0
}

function Start-SccacheServer {
    param(
        [int]$MaxMemoryMB = 2048,
        [switch]$Force
    )

    # Acquire cross-process mutex to prevent concurrent startup races.
    # Multiple LLM agents may invoke cargo simultaneously - without this,
    # they can both see 0 sccache processes and race to start servers.
    $mutexHandle = $null
    $useMutex = ([System.Management.Automation.PSTypeName]'CargoTools.ProcessMutex').Type
    if ($useMutex) {
        $mutexHandle = [CargoTools.ProcessMutex]::TryAcquire('CargoTools_SccacheStartup', 10000)
        if (-not $mutexHandle) {
            Write-Verbose '[sccache] Another process is starting sccache, waiting...'
            # Could not acquire in 10s - another process is handling startup.
            # Check if sccache is already running (the other process may have started it).
            $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 0) { return $true }
            Write-Warning 'Timed out waiting for sccache startup mutex. Proceeding without lock.'
        }
    }

    try {
        $manager = Resolve-UserScript 'sccache-manager.ps1'
        if ($manager) {
            & $manager -HealthCheck | Out-Null
            if ($LASTEXITCODE -eq 0) { return $true }
        }

        $sccacheCmd = Resolve-Sccache
        if (-not $sccacheCmd) {
            Write-Warning 'sccache not found in PATH. Builds will continue without sccache.'
            return $false
        }

        # Check for multiple instances or high memory usage
        $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
        if ($procs.Count -gt 1) {
            Write-Verbose "[Memory] Multiple sccache instances ($($procs.Count)), consolidating..."
            sccache --stop-server 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
            $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
            if ($procs.Count -gt 1 -and $Force) {
                $procs | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
                $procs = @()
            } elseif ($procs.Count -gt 1) {
                Write-Warning 'Multiple sccache instances detected; use -Force to consolidate.'
            }
        }

        $memMB = Get-SccacheMemoryMB
        if ($procs.Count -eq 1 -and $memMB -gt $MaxMemoryMB) {
            Write-Verbose "[Memory] sccache using ${memMB}MB > ${MaxMemoryMB}MB limit, restarting..."
            sccache --stop-server 2>$null | Out-Null
            Start-Sleep -Milliseconds 500
            $procs = @()
        }

        if ($procs.Count -eq 0 -or $Force) {
            & $sccacheCmd --start-server 2>$null | Out-Null
            Start-Sleep -Milliseconds 300
            $healthOk = $true
            try {
                & $sccacheCmd --show-stats 2>$null | Out-Null
                $healthOk = ($LASTEXITCODE -eq 0)
            } catch {
                $healthOk = $false
            }
            if (-not $healthOk) {
                Write-Warning 'sccache started but health check failed.'
                return $false
            }

            # Lower priority to prevent system overload
            $newProc = Get-Process -Name 'sccache' -ErrorAction SilentlyContinue
            if ($newProc) {
                try { $newProc.PriorityClass = 'BelowNormal' } catch {}
            }
        }
        return $true
    } catch {
        Write-Warning "Unable to start sccache server: $_"
    } finally {
        if ($mutexHandle) {
            $mutexHandle.Dispose()
        }
    }
    return $false
}

function Test-SccacheHealth {
    <#
    .SYNOPSIS
    Verifies sccache server is responsive. Used for post-failure diagnosis.
    .OUTPUTS
    PSCustomObject with Healthy, Running, ProcessCount, MemoryMB, Port, Error fields.
    #>
    [CmdletBinding()]
    param()

    $result = [PSCustomObject]@{
        Healthy      = $false
        Running      = $false
        ProcessCount = 0
        MemoryMB     = 0
        Port         = $env:SCCACHE_SERVER_PORT
        Error        = $null
    }

    $procs = @(Get-Process -Name 'sccache' -ErrorAction SilentlyContinue)
    $result.ProcessCount = $procs.Count
    $result.Running = $procs.Count -gt 0
    $result.MemoryMB = Get-SccacheMemoryMB

    if (-not $result.Running) {
        $result.Error = 'sccache server not running'
        return $result
    }

    try {
        $sccacheCmd = Resolve-Sccache
        if ($sccacheCmd) {
            & $sccacheCmd --show-stats 2>$null | Out-Null
            $result.Healthy = ($LASTEXITCODE -eq 0)
            if (-not $result.Healthy) {
                $result.Error = "sccache --show-stats returned exit code $LASTEXITCODE"
            }
        } else {
            $result.Error = 'sccache binary not found in PATH'
        }
    } catch {
        $result.Error = "sccache health check exception: $_"
    }

    return $result
}

function Stop-SccacheServer {
    $existing = Get-Process -Name 'sccache' -ErrorAction SilentlyContinue
    if (-not $existing) { return }
    sccache --stop-server 2>$null | Out-Null
    Start-Sleep -Milliseconds 500
    $remaining = Get-Process -Name 'sccache' -ErrorAction SilentlyContinue
    if ($remaining) {
        $remaining | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Get-OptimalBuildJobs {
    param([switch]$LowMemory)
    $lowMemoryJobs = 2

    if ($LowMemory) { return $lowMemoryJobs }

    # Check machine config first
    $mc = Get-MachineConfig
    $configuredJobs = $mc['BuildJobs']

    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $freeGB = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
            if ($freeGB -lt 4) { return $lowMemoryJobs }
        }
    } catch {}

    if ($configuredJobs) { return [int]$configuredJobs }
    return 4
}

function Resolve-BundledRustLld {
    <#
    .SYNOPSIS
    Finds the bundled rust-lld.exe in the active Rust toolchain.
    .DESCRIPTION
    Rust ships a bundled lld linker at <toolchain>/lib/rustlib/x86_64-pc-windows-msvc/bin/rust-lld.exe.
    This is significantly faster than link.exe and requires no external LLVM install.
    #>
    $rustupPath = Get-RustupPath
    if (-not (Test-Path $rustupPath)) { return $null }

    $rustupHome = if ($env:RUSTUP_HOME) { $env:RUSTUP_HOME }
                  else {
                      $mc = Get-MachineConfig
                      if ($mc['RustupHome'] -and (Test-Path $mc['RustupHome'])) { $mc['RustupHome'] }
                      else { Join-Path $env:USERPROFILE '.rustup' }
                  }

    try {
        $toolchain = Resolve-CargoToolchain -RustupPath $rustupPath
        if ($toolchain) {
            $bundledPath = Join-Path $rustupHome "toolchains\$toolchain\lib\rustlib\x86_64-pc-windows-msvc\bin\rust-lld.exe"
            if (Test-Path $bundledPath) {
                return $bundledPath
            }
        }
    } catch {
        Write-Verbose "Failed to resolve bundled rust-lld: $_"
    }
    return $null
}

function Resolve-LldLinker {
    # Priority 1: Explicit path
    if ($env:CARGO_LLD_PATH -and (Test-Path $env:CARGO_LLD_PATH)) {
        return $env:CARGO_LLD_PATH
    }
    # Priority 2: External lld-link on PATH
    $lldPath = Find-CargoCommandPath -Name 'lld-link'
    if ($lldPath) { return $lldPath }
    # Priority 3: Bundled rust-lld in active toolchain
    return Resolve-BundledRustLld
}

function Apply-LinkerSettings {
    param(
        [bool]$UseLld,
        [string]$LldPath
    )

    if ($UseLld) {
        if ($LldPath) {
            $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = $LldPath
            # Bundled rust-lld requires explicit linker-flavor flag
            if ($LldPath -match '[/\\]rust-lld') {
                Add-RustFlags '-C linker-flavor=lld-link'
            }
            return $true
        }
        Write-Warning 'CARGO_USE_LLD requested, but no lld-link.exe or bundled rust-lld found. Falling back to link.exe.'
        $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = 'link.exe'
        return $false
    }

    $env:CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER = 'link.exe'
    return $false
}

function Apply-NativeCpuFlag {
    param([bool]$UseNative)
    if ($UseNative) { Add-RustFlags '-C target-cpu=native' }
}
