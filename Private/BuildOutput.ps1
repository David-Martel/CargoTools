function Test-IsBuildCommand {
    param([string]$PrimaryCommand)
    $buildCommands = @('build', 'b', 'run', 'r', 'test', 't', 'bench', 'install')
    return $buildCommands -contains $PrimaryCommand
}

function Get-BuildProfile {
    param([string[]]$ArgsList)

    $ArgsList = Normalize-ArgsList $ArgsList
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        $arg = $ArgsList[$i]
        if ($arg -eq '--release' -or $arg -eq '-r') { return 'release' }
        if ($arg -eq '--profile') {
            if ($i + 1 -lt $ArgsList.Count) { return $ArgsList[$i + 1] }
        }
        if ($arg -like '--profile=*') {
            return $arg.Substring(10)
        }
    }

    if ($env:CARGO_PROFILE) { return $env:CARGO_PROFILE }
    return 'debug'
}

function Resolve-CargoProjectRoot {
    [CmdletBinding()]
    param(
        [string]$Path = (Get-Location).Path
    )

    $resolvedPath = try {
        if (Test-Path -LiteralPath $Path) {
            (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        } else {
            [System.IO.Path]::GetFullPath($Path)
        }
    } catch {
        [System.IO.Path]::GetFullPath($Path)
    }

    $current = if (Test-Path -LiteralPath $resolvedPath -PathType Container) {
        $resolvedPath
    } else {
        Split-Path -Parent $resolvedPath
    }

    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current 'Cargo.toml')) {
            return $current
        }

        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) {
            break
        }
        $current = $parent
    }

    return $resolvedPath
}

function Get-LocalCargoTargetRoot {
    [CmdletBinding()]
    param(
        [string]$ProjectRoot = (Get-Location).Path
    )

    $resolvedRoot = Resolve-CargoProjectRoot -Path $ProjectRoot
    return Join-Path $resolvedRoot 'target'
}

function Resolve-CargoOutputDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,
        [string[]]$ArgsList,
        [string]$ProjectRoot = (Get-Location).Path,
        [string]$TargetRoot
    )

    $resolvedTargetRoot = if ($TargetRoot) {
        $TargetRoot
    } else {
        Get-LocalCargoTargetRoot -ProjectRoot $ProjectRoot
    }

    $targetTriple = Get-TargetFromArgs $ArgsList
    if ($targetTriple) {
        return Join-Path (Join-Path $resolvedTargetRoot $targetTriple) $Profile
    }

    return Join-Path $resolvedTargetRoot $Profile
}

function Get-PackageNames {
    param([string]$ManifestPath)

    $names = @()
    if (-not (Test-Path $ManifestPath)) { return $names }

    try {
        $content = Get-Content -Path $ManifestPath -Raw

        # Match [package] name = "..."
        if ($content -match '\[package\]\s*[\r\n]+(?:[^\[]*?)name\s*=\s*"([^"]+)"') {
            $names += $Matches[1]
        }

        # Match [[bin]] name = "..."
        $binMatches = [regex]::Matches($content, '\[\[bin\]\]\s*[\r\n]+(?:[^\[]*?)name\s*=\s*"([^"]+)"')
        foreach ($match in $binMatches) {
            $names += $match.Groups[1].Value
        }

        # Also get workspace members if this is a workspace
        if ($content -match 'members\s*=\s*\[([^\]]+)\]') {
            $membersStr = $Matches[1]
            $memberDirs = [regex]::Matches($membersStr, '"([^"]+)"')
            foreach ($memberMatch in $memberDirs) {
                $memberPath = Join-Path (Split-Path $ManifestPath -Parent) $memberMatch.Groups[1].Value
                $memberManifest = Join-Path $memberPath 'Cargo.toml'
                if (Test-Path $memberManifest) {
                    $names += Get-PackageNames $memberManifest
                }
            }
        }
    } catch {
        Write-Debug "[BuildOutput] Failed to parse $ManifestPath : $_"
    }

    return $names | Select-Object -Unique
}

function Copy-SingleFile {
    <#
    .SYNOPSIS
    Copies a single file using C# FileCopy accelerator with retry, or falls back to Copy-Item.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Dest
    )

    if (([System.Management.Automation.PSTypeName]'CargoTools.FileCopy').Type) {
        $result = [CargoTools.FileCopy]::CopyWithRetry($Source, $Dest, 3, 100)
        if ($result.Success) { return $true }
        Write-Warning "[BuildOutput] Copy failed after $($result.Attempts) attempts: $($result.LastError)"
        return $false
    }
    try {
        Copy-Item -Path $Source -Destination $Dest -Force
        return $true
    } catch {
        Write-Warning "[BuildOutput] Copy failed: $_"
        return $false
    }
}

function Copy-ProfileDirectory {
    <#
    .SYNOPSIS
    Copies all build outputs from shared profile directory to local target.
    .DESCRIPTION
    Performs a filtered directory copy from the shared cargo-target profile dir
    to ./target/{profile}/, copying only files newer than their local counterparts.
    Excludes intermediate build artifacts (.d dep-info, .fingerprint, incremental/).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestDir,
        [string[]]$IncludeExtensions = @('.exe', '.dll', '.pdb', '.lib', '.rlib', '.so', '.dylib', '.wasm'),
        [switch]$IncludeExamples,
        [switch]$Quiet
    )

    if (-not (Test-Path $SourceDir)) { return 0 }
    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    $copiedCount = 0

    # Copy top-level build outputs (exe, dll, pdb, lib, etc.)
    $topFiles = Get-ChildItem -Path $SourceDir -File -ErrorAction SilentlyContinue |
        Where-Object { $IncludeExtensions -contains $_.Extension }

    foreach ($file in $topFiles) {
        $destPath = Join-Path $DestDir $file.Name
        $shouldCopy = (-not (Test-Path $destPath)) -or ($file.LastWriteTime -gt (Get-Item $destPath).LastWriteTime)
        if ($shouldCopy) {
            $copied = Copy-SingleFile -Source $file.FullName -Dest $destPath
            if ($copied) { $copiedCount++ }
        }
    }

    # Copy examples/ subdirectory if requested
    if ($IncludeExamples) {
        $examplesDir = Join-Path $SourceDir 'examples'
        if (Test-Path $examplesDir) {
            $localExamples = Join-Path $DestDir 'examples'
            if (-not (Test-Path $localExamples)) {
                New-Item -ItemType Directory -Path $localExamples -Force | Out-Null
            }
            $exeFiles = Get-ChildItem -Path $examplesDir -File -ErrorAction SilentlyContinue |
                Where-Object { $IncludeExtensions -contains $_.Extension }
            foreach ($file in $exeFiles) {
                $destPath = Join-Path $localExamples $file.Name
                $shouldCopy = (-not (Test-Path $destPath)) -or ($file.LastWriteTime -gt (Get-Item $destPath).LastWriteTime)
                if ($shouldCopy) {
                    $copied = Copy-SingleFile -Source $file.FullName -Dest $destPath
                    if ($copied) { $copiedCount++ }
                }
            }
        }
    }

    return $copiedCount
}

function Copy-BuildOutputToLocal {
    <#
    .SYNOPSIS
    Copies build outputs from shared target directory to local ./target/{profile}/.

    .DESCRIPTION
    After a successful cargo build, copies all relevant executables and libraries
    from the shared cargo target directory to the local project's
    ./target/{profile}/ directory. Uses extension-based filtering instead of
    per-package-name patterns to capture all build outputs.

    .PARAMETER Profile
    The build profile (debug, release, or custom profile name).

    .PARAMETER ProjectRoot
    The project root directory containing Cargo.toml. Defaults to current directory.

    .PARAMETER SharedTarget
    The shared CARGO_TARGET_DIR. Defaults to `<cache-root>\cargo-target`.

    .PARAMETER IncludeExamples
    Also copy files from the examples/ subdirectory.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [string]$ProjectRoot = (Get-Location).Path,

        [string]$SharedTarget = $env:CARGO_TARGET_DIR,
        [string[]]$ArgsList,

        [switch]$IncludeExamples,

        [switch]$Quiet
    )

    if (-not $SharedTarget) { $SharedTarget = Join-Path (Resolve-CacheRoot) 'cargo-target' }

    $manifestPath = Join-Path $ProjectRoot 'Cargo.toml'
    if (-not (Test-Path $manifestPath)) {
        Write-Debug "[BuildOutput] No Cargo.toml found in $ProjectRoot"
        return $false
    }

    $sharedProfileDir = Resolve-CargoOutputDirectory -Profile $Profile -ArgsList $ArgsList -ProjectRoot $ProjectRoot -TargetRoot $SharedTarget
    if (-not (Test-Path $sharedProfileDir)) {
        Write-Debug "[BuildOutput] Shared profile dir not found: $sharedProfileDir"
        return $false
    }

    $localTargetDir = Resolve-CargoOutputDirectory -Profile $Profile -ArgsList $ArgsList -ProjectRoot $ProjectRoot

    # Check CARGO_AUTO_COPY_EXAMPLES env var
    if (-not $IncludeExamples -and $env:CARGO_AUTO_COPY_EXAMPLES -eq '1') {
        $IncludeExamples = [switch]::new($true)
    }

    $copiedCount = Copy-ProfileDirectory -SourceDir $sharedProfileDir -DestDir $localTargetDir -IncludeExamples:$IncludeExamples -Quiet:$Quiet

    # Create deps junction if it doesn't exist (for runtime deps)
    $sharedDeps = Join-Path $sharedProfileDir 'deps'
    $localDeps = Join-Path $localTargetDir 'deps'
    if ((Test-Path $sharedDeps) -and -not (Test-Path $localDeps)) {
        try {
            New-Item -ItemType Junction -Path $localDeps -Target $sharedDeps -Force -ErrorAction SilentlyContinue | Out-Null
        } catch { }
    }

    if ($copiedCount -gt 0 -and -not $Quiet) {
        Write-Host "  [CargoTools] Copied $copiedCount file(s) to .\target\$Profile\" -ForegroundColor Green
    }

    return $copiedCount -gt 0
}

function Test-AutoCopyEnabled {
    param(
        [string]$ProjectRoot = (Get-Location).Path
    )

    # Check if auto-copy is disabled via env var
    if ($env:CARGO_AUTO_COPY -eq '0' -or $env:CARGO_AUTO_COPY -eq 'false') {
        return $false
    }
    if ($env:CARGO_AUTO_COPY -eq '1' -or $env:CARGO_AUTO_COPY -eq 'true') {
        return $true
    }

    if (-not $env:CARGO_TARGET_DIR) {
        return $false
    }

    $sharedTargetRoot = [System.IO.Path]::GetFullPath($env:CARGO_TARGET_DIR)
    $localTargetRoot = [System.IO.Path]::GetFullPath((Get-LocalCargoTargetRoot -ProjectRoot $ProjectRoot))
    return $sharedTargetRoot -ne $localTargetRoot
}
