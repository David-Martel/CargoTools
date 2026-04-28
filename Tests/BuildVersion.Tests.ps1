#Requires -Modules Pester

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    $script:SavedEnv = @{}
    foreach ($name in @('CARGO_TARGET_DIR', 'BUILD_VERSION', 'BUILD_RELEASE_TAG', 'BUILD_GIT_HASH')) {
        if (Test-Path "Env:$name") {
            $script:SavedEnv[$name] = (Get-Item "Env:$name").Value
        }
    }

    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "CargoTools_BuildVersion_Tests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
}

AfterAll {
    foreach ($entry in $script:SavedEnv.GetEnumerator()) {
        Set-Item -Path ("Env:" + $entry.Key) -Value $entry.Value
    }

    foreach ($name in @('CARGO_TARGET_DIR', 'BUILD_VERSION', 'BUILD_RELEASE_TAG', 'BUILD_GIT_HASH')) {
        if (-not $script:SavedEnv.ContainsKey($name)) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
        Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Get-BuildVersionInfo' {
    It 'Returns semantic version, release tag, and assembly metadata for an existing repo without mutating signing state' {
        $repoRoot = 'C:\codedev\PC_AI'
        Test-Path $repoRoot | Should -BeTrue

        $info = Get-BuildVersionInfo -RepoRoot $repoRoot -DefaultVersion '0.1.0'
        $info.SemVer | Should -Match '^\d+\.\d+\.\d+'
        $info.ReleaseTag | Should -Match '^v'
        $info.AssemblyVersion | Should -Match '^\d+\.\d+\.\d+\.0$'
        $info.FileVersion | Should -Match '^\d+\.\d+\.\d+\.\d+$'
        $info.GitHashShort | Should -Match '^[0-9a-f]{7,}$|^unknown$'
    }
}

Describe 'Set-BuildVersionEnvironment' {
    It 'Sets prefixed environment variables for build scripts' {
        $versionInfo = [pscustomobject]@{
            Version = '1.2.3+abc1234'
            SemVer = '1.2.3'
            AssemblyVersion = '1.2.3.0'
            FileVersion = '1.2.3.4'
            InformationalVersion = '1.2.3+abc1234 (v1.2.3)'
            ReleaseTag = 'v1.2.3'
            GitDescribe = 'v1.2.3-4-gabc1234'
            GitHash = 'abc1234def5678'
            GitHashShort = 'abc1234'
            GitBranch = 'main'
            Timestamp = '2026-03-11T00:00:00Z'
            TimestampUnix = 1741651200
            BuildType = 'dev'
            IsDirty = $false
            CommitsSinceTag = 4
        }

        Set-BuildVersionEnvironment -VersionInfo $versionInfo -Prefixes @('BUILD', 'PCAI') | Out-Null
        $env:BUILD_VERSION | Should -Be '1.2.3+abc1234'
        $env:BUILD_RELEASE_TAG | Should -Be 'v1.2.3'
        $env:PCAI_FILE_VERSION | Should -Be '1.2.3.4'
    }
}

Describe 'Resolve-CargoTargetDirectory' {
    It 'Prefers the shared target root when CARGO_TARGET_DIR is set' {
        $env:CARGO_TARGET_DIR = Join-Path $script:TestRoot 'shared-target'
        $projectDir = Join-Path $script:TestRoot "cargo_project_$(Get-Random)"
        New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
        Set-Content -Path (Join-Path $projectDir 'Cargo.toml') -Value "[package]`nname='x'`nversion='0.1.0'"

        $resolved = Resolve-CargoTargetDirectory -ProjectDir $projectDir -Configuration Release
        $resolved | Should -Be (Join-Path $env:CARGO_TARGET_DIR 'release')
    }
}

Describe 'Publish-BuildArtifact' {
    It 'Writes a buildinfo manifest even when source and destination are the same file' {
        $artifactDir = Join-Path $script:TestRoot "artifact_$(Get-Random)"
        New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
        $artifactPath = Join-Path $artifactDir 'sample.dll'
        Set-Content -Path $artifactPath -Value 'artifact-bytes'

        $versionInfo = [pscustomobject]@{
            Version = '2.0.0+def5678'
            SemVer = '2.0.0'
            AssemblyVersion = '2.0.0.0'
            FileVersion = '2.0.0.3'
            InformationalVersion = '2.0.0+def5678 (v2.0.0)'
            ReleaseTag = 'v2.0.0'
            GitHashShort = 'def5678'
        }

        $result = Publish-BuildArtifact -SourcePath $artifactPath -DestinationDirectory $artifactDir -DestinationFileName 'sample.dll' -VersionInfo $versionInfo -ArtifactKind 'managed-dotnet'
        $result.DestinationPath | Should -Be $artifactPath
        Test-Path $result.ManifestPath | Should -BeTrue

        $manifest = Get-Content -Path $result.ManifestPath -Raw | ConvertFrom-Json
        $manifest.releaseTag | Should -Be 'v2.0.0'
        $manifest.fileName | Should -Be 'sample.dll'
    }
}
