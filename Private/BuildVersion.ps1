function Invoke-BuildVersionGitText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & git -C $RepoRoot @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ($output -join "`n")
}

function ConvertTo-AssemblyVersion {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SemVer,

        [int]$Revision = 0
    )

    if ($SemVer -notmatch '^(?<major>\d+)\.(?<minor>\d+)\.(?<patch>\d+)') {
        return [pscustomobject]@{
            AssemblyVersion = '0.1.0.0'
            FileVersion = '0.1.0.0'
        }
    }

    $major = [int]$Matches.major
    $minor = [int]$Matches.minor
    $patch = [int]$Matches.patch
    $revision = [Math]::Max(0, [Math]::Min(65535, $Revision))

    [pscustomobject]@{
        AssemblyVersion = "$major.$minor.$patch.0"
        FileVersion = "$major.$minor.$patch.$revision"
    }
}

function Get-BuildVersionInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$RepoRoot = (Get-Location).Path,
        [string]$DefaultVersion = '0.1.0',
        [string]$TagPrefix = 'v'
    )

    $result = [ordered]@{
        Version             = $DefaultVersion
        SemVer              = $DefaultVersion
        AssemblyVersion     = '0.1.0.0'
        FileVersion         = '0.1.0.0'
        InformationalVersion = $DefaultVersion
        ReleaseTag          = ''
        GitDescribe         = ''
        GitHash             = 'unknown'
        GitHashShort        = 'unknown'
        GitBranch           = 'unknown'
        CommitsSinceTag     = 0
        Timestamp           = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        TimestampUnix       = [int][double]::Parse((Get-Date -UFormat %s))
        IsDirty             = $false
        BuildType           = 'dev'
        RepoRoot            = [System.IO.Path]::GetFullPath($RepoRoot)
    }

    $exactTag = $null
    $defaultSemVer = $DefaultVersion
    if ($defaultSemVer -match '^(?<semver>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)') {
        $defaultSemVer = $Matches.semver
    }

    try {
        $gitHash = (Invoke-BuildVersionGitText -RepoRoot $RepoRoot -Arguments @('rev-parse', 'HEAD')) -replace '\s', ''
        if ($gitHash) {
            $result.GitHash = $gitHash
            $result.GitHashShort = $gitHash.Substring(0, [Math]::Min(7, $gitHash.Length))
        }

        $branch = (Invoke-BuildVersionGitText -RepoRoot $RepoRoot -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')) -replace '\s', ''
        if ($branch) {
            $result.GitBranch = $branch
        }

        $status = Invoke-BuildVersionGitText -RepoRoot $RepoRoot -Arguments @('status', '--porcelain')
        $result.IsDirty = [bool]$status

        $exactTag = (Invoke-BuildVersionGitText -RepoRoot $RepoRoot -Arguments @('describe', '--tags', '--exact-match')) -replace '\s', ''
        $describe = (Invoke-BuildVersionGitText -RepoRoot $RepoRoot -Arguments @('describe', '--tags', '--long', '--always')) -replace '\s', ''
        if ($describe) {
            $result.GitDescribe = $describe
        }

        if ($describe -match '^(?<tag>.+)-(?<commits>\d+)-g(?<hash>[0-9a-f]+)$') {
            $rawTag = $Matches.tag
            $commitsSinceTag = [int]$Matches.commits
            $tagSemVer = $rawTag.TrimStart('v')
            $result.ReleaseTag = $rawTag
            if ($tagSemVer -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
                $result.SemVer = $tagSemVer
            } else {
                $result.SemVer = $defaultSemVer
            }
            $result.CommitsSinceTag = $commitsSinceTag
        } elseif ($exactTag) {
            $result.ReleaseTag = $exactTag
            $result.SemVer = $exactTag.TrimStart('v')
            $result.CommitsSinceTag = 0
        } else {
            $commitCount = (Invoke-BuildVersionGitText -RepoRoot $RepoRoot -Arguments @('rev-list', '--count', 'HEAD')) -replace '\s', ''
            if ($commitCount) {
                $result.CommitsSinceTag = [int]$commitCount
            }
            $result.SemVer = $defaultSemVer
        }
    } catch {
        $result.SemVer = $defaultSemVer
    }

    if (-not $result.ReleaseTag -and $result.SemVer) {
        $result.ReleaseTag = "$TagPrefix$($result.SemVer)"
    }

    if ($result.CommitsSinceTag -eq 0 -and $exactTag -and -not $result.IsDirty) {
        $result.BuildType = 'release'
    } elseif ($result.SemVer -match '-') {
        $result.BuildType = 'prerelease'
    } else {
        $result.BuildType = 'dev'
    }

    $result.Version = $result.SemVer
    if ($result.CommitsSinceTag -gt 0) {
        $result.Version += ".$($result.CommitsSinceTag)"
    }
    if ($result.GitHashShort -and $result.GitHashShort -ne 'unknown') {
        $result.Version += "+$($result.GitHashShort)"
    }
    if ($result.IsDirty) {
        $result.Version += '.dirty'
    }
    $result.InformationalVersion = "$($result.Version) ($($result.ReleaseTag))"

    $assemblyInfo = ConvertTo-AssemblyVersion -SemVer $result.SemVer -Revision $result.CommitsSinceTag
    $result.AssemblyVersion = $assemblyInfo.AssemblyVersion
    $result.FileVersion = $assemblyInfo.FileVersion

    return [pscustomobject]$result
}

function Set-BuildVersionEnvironment {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$VersionInfo,

        [string[]]$Prefixes = @('BUILD')
    )

    foreach ($prefix in $Prefixes | Where-Object { $_ }) {
        $normalized = $prefix.ToUpperInvariant()
        [Environment]::SetEnvironmentVariable("${normalized}_VERSION", $VersionInfo.Version, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_SEMVER", $VersionInfo.SemVer, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_ASSEMBLY_VERSION", $VersionInfo.AssemblyVersion, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_FILE_VERSION", $VersionInfo.FileVersion, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_INFORMATIONAL_VERSION", $VersionInfo.InformationalVersion, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_RELEASE_TAG", $VersionInfo.ReleaseTag, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_GIT_DESCRIBE", $VersionInfo.GitDescribe, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_GIT_HASH", $VersionInfo.GitHash, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_GIT_HASH_SHORT", $VersionInfo.GitHashShort, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_GIT_BRANCH", $VersionInfo.GitBranch, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_BUILD_TIMESTAMP", $VersionInfo.Timestamp, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_BUILD_TIMESTAMP_UNIX", [string]$VersionInfo.TimestampUnix, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_BUILD_TYPE", $VersionInfo.BuildType, 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_BUILD_DIRTY", $(if ($VersionInfo.IsDirty) { '1' } else { '0' }), 'Process')
        [Environment]::SetEnvironmentVariable("${normalized}_COMMITS_SINCE_TAG", [string]$VersionInfo.CommitsSinceTag, 'Process')
    }

    return $VersionInfo
}

function Resolve-CargoTargetDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$ProjectDir,
        [string]$ManifestPath,
        [ValidateSet('Debug', 'Release')]
        [string]$Configuration = 'Release',
        [string]$Target
    )

    if (-not $ManifestPath) {
        if ($ProjectDir) {
            $ManifestPath = Join-Path $ProjectDir 'Cargo.toml'
        }
    }

    $profile = if ($Configuration -eq 'Debug') { 'debug' } else { 'release' }

    $targetRoot = $null
    if ($env:CARGO_TARGET_DIR) {
        $targetRoot = $env:CARGO_TARGET_DIR
    } elseif ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath)) {
        $manifestDir = Split-Path -Parent $ManifestPath
        Push-Location $manifestDir
        try {
            $metadata = cargo metadata --manifest-path $ManifestPath --format-version 1 --no-deps 2>$null | ConvertFrom-Json
            if ($metadata.target_directory) {
                $targetRoot = [string]$metadata.target_directory
            }
        } catch {
        } finally {
            Pop-Location
        }
    }

    if (-not $targetRoot) {
        if (-not $ProjectDir) {
            throw 'ProjectDir or ManifestPath is required to resolve cargo target directory.'
        }
        $targetRoot = Join-Path $ProjectDir 'target'
    }

    if ($Target) {
        return Join-Path $targetRoot "$Target\$profile"
    }

    return Join-Path $targetRoot $profile
}

function Publish-BuildArtifact {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$DestinationDirectory,

        [string]$DestinationFileName,

        [pscustomobject]$VersionInfo,

        [string]$ArtifactKind = 'native'
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Build artifact not found: $SourcePath"
    }

    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }

    if (-not $DestinationFileName) {
        $DestinationFileName = [System.IO.Path]::GetFileName($SourcePath)
    }

    $destinationPath = Join-Path $DestinationDirectory $DestinationFileName
    $resolvedSourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
    $resolvedDestinationDirectory = [System.IO.Path]::GetFullPath($DestinationDirectory)
    $resolvedDestinationPath = [System.IO.Path]::Combine($resolvedDestinationDirectory, $DestinationFileName)

    if (-not [System.StringComparer]::OrdinalIgnoreCase.Equals($resolvedSourcePath, $resolvedDestinationPath)) {
        Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force
    }

    $manifestPath = "$destinationPath.buildinfo.json"
    $item = Get-Item -LiteralPath $destinationPath -ErrorAction Stop
    $hash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
    $manifest = [ordered]@{
        artifactKind    = $ArtifactKind
        fileName        = $item.Name
        destinationPath = $destinationPath
        sourcePath      = $resolvedSourcePath
        sizeBytes       = $item.Length
        sha256          = $hash
        copiedUtc       = [DateTime]::UtcNow.ToString('o')
        version         = if ($VersionInfo) { $VersionInfo.Version } else { $null }
        semver          = if ($VersionInfo) { $VersionInfo.SemVer } else { $null }
        releaseTag      = if ($VersionInfo) { $VersionInfo.ReleaseTag } else { $null }
        fileVersion     = if ($VersionInfo) { $VersionInfo.FileVersion } else { $null }
        assemblyVersion = if ($VersionInfo) { $VersionInfo.AssemblyVersion } else { $null }
        informationalVersion = if ($VersionInfo) { $VersionInfo.InformationalVersion } else { $null }
        gitHashShort    = if ($VersionInfo) { $VersionInfo.GitHashShort } else { $null }
    }

    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding utf8

    return [pscustomobject]@{
        DestinationPath = $destinationPath
        ManifestPath = $manifestPath
        FileName = $item.Name
    }
}
