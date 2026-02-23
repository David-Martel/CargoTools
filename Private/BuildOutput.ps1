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

function Copy-BuildOutputToLocal {
    <#
    .SYNOPSIS
    Copies build outputs from shared target directory to local ./target/{profile}/.

    .DESCRIPTION
    After a successful cargo build, copies relevant executables and libraries
    from T:\RustCache\cargo-target\{profile}\ to the local project's
    ./target/{profile}/ directory.

    .PARAMETER Profile
    The build profile (debug, release, or custom profile name).

    .PARAMETER ProjectRoot
    The project root directory containing Cargo.toml. Defaults to current directory.

    .PARAMETER SharedTarget
    The shared CARGO_TARGET_DIR. Defaults to T:\RustCache\cargo-target.

    .PARAMETER CopyPattern
    File patterns to copy. Defaults to executables and libraries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Profile,

        [string]$ProjectRoot = (Get-Location).Path,

        [string]$SharedTarget = $env:CARGO_TARGET_DIR,

        [string[]]$CopyPattern = @('*.exe', '*.dll', '*.pdb', '*.lib', '*.rlib'),

        [switch]$Quiet
    )

    if (-not $SharedTarget) { $SharedTarget = 'T:\RustCache\cargo-target' }

    $manifestPath = Join-Path $ProjectRoot 'Cargo.toml'
    if (-not (Test-Path $manifestPath)) {
        Write-Debug "[BuildOutput] No Cargo.toml found in $ProjectRoot"
        return $false
    }

    $sharedProfileDir = Join-Path $SharedTarget $Profile
    if (-not (Test-Path $sharedProfileDir)) {
        Write-Debug "[BuildOutput] Shared profile dir not found: $sharedProfileDir"
        return $false
    }

    # Get package/binary names from Cargo.toml
    $packageNames = @(Get-PackageNames $manifestPath)
    if (-not $packageNames -or $packageNames.Count -eq 0) {
        Write-Debug "[BuildOutput] Could not determine package names from manifest"
        return $false
    }

    # Create local target directory
    $localTargetDir = Join-Path $ProjectRoot "target\$Profile"
    if (-not (Test-Path $localTargetDir)) {
        New-Item -ItemType Directory -Path $localTargetDir -Force | Out-Null
        if (-not $Quiet) {
            Write-Host "  [CargoTools] Created local target: .\target\$Profile\" -ForegroundColor DarkCyan
        }
    }

    $copiedCount = 0
    $copiedFiles = @()

    foreach ($name in $packageNames) {
        # Build patterns with package name
        $namedPatterns = @(
            "$name.exe",
            "$name.dll",
            "$name.pdb",
            "lib$name.dll",
            "lib$name.rlib"
        )

        foreach ($pattern in $namedPatterns) {
            $sourcePath = Join-Path $sharedProfileDir $pattern
            if (Test-Path $sourcePath) {
                $destPath = Join-Path $localTargetDir $pattern

                # Only copy if source is newer or dest doesn't exist
                $shouldCopy = $false
                if (-not (Test-Path $destPath)) {
                    $shouldCopy = $true
                } else {
                    $sourceTime = (Get-Item $sourcePath).LastWriteTime
                    $destTime = (Get-Item $destPath).LastWriteTime
                    if ($sourceTime -gt $destTime) {
                        $shouldCopy = $true
                    }
                }

                if ($shouldCopy) {
                    try {
                        Copy-Item -Path $sourcePath -Destination $destPath -Force
                        $copiedCount++
                        $copiedFiles += $pattern
                    } catch {
                        Write-Warning "[BuildOutput] Failed to copy $pattern : $_"
                    }
                }
            }
        }
    }

    # Also copy deps directory if it exists (for runtime deps)
    $sharedDeps = Join-Path $sharedProfileDir 'deps'
    $localDeps = Join-Path $localTargetDir 'deps'
    if ((Test-Path $sharedDeps) -and -not (Test-Path $localDeps)) {
        # Create deps symlink instead of copying (saves space)
        try {
            New-Item -ItemType Junction -Path $localDeps -Target $sharedDeps -Force -ErrorAction SilentlyContinue | Out-Null
        } catch {
            # Junction creation may fail, that's ok
        }
    }

    if ($copiedCount -gt 0 -and -not $Quiet) {
        $fileList = $copiedFiles -join ', '
        Write-Host "  [CargoTools] Copied to .\target\$Profile\: $fileList" -ForegroundColor Green
    }

    return $copiedCount -gt 0
}

function Test-AutoCopyEnabled {
    # Check if auto-copy is disabled via env var
    if ($env:CARGO_AUTO_COPY -eq '0' -or $env:CARGO_AUTO_COPY -eq 'false') {
        return $false
    }
    # Default to enabled
    return $true
}
