#Requires -Modules Pester
<#
.SYNOPSIS
Pester tests for BuildOutput.ps1 functions.
.DESCRIPTION
Tests for Copy-SingleFile, Copy-ProfileDirectory, Copy-BuildOutputToLocal,
and related build output copy functionality.
#>

BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force

    $module = Get-Module CargoTools
    $script:CopySingleFile = & $module { ${function:Copy-SingleFile} }
    $script:CopyProfileDirectory = & $module { ${function:Copy-ProfileDirectory} }
    $script:CopyBuildOutputToLocal = & $module { ${function:Copy-BuildOutputToLocal} }
    $script:TestIsBuildCommand = & $module { ${function:Test-IsBuildCommand} }
    $script:GetBuildProfile = & $module { ${function:Get-BuildProfile} }
    $script:GetPackageNames = & $module { ${function:Get-PackageNames} }
    $script:TestAutoCopyEnabled = & $module { ${function:Test-AutoCopyEnabled} }

    # Save env state
    $script:SavedEnv = @{}
    foreach ($name in @('CARGO_TARGET_DIR', 'CARGO_AUTO_COPY', 'CARGO_AUTO_COPY_EXAMPLES', 'CARGO_PROFILE')) {
        if (Test-Path "Env:$name") {
            $script:SavedEnv[$name] = (Get-Item "Env:$name").Value
        }
    }

    # Create temp directory structure for tests
    $script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) "CargoTools_BuildOutput_Tests_$(Get-Random)"
    New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
}

AfterAll {
    # Restore saved env
    foreach ($entry in $script:SavedEnv.GetEnumerator()) {
        Set-Item -Path ("Env:" + $entry.Key) -Value $entry.Value
    }
    foreach ($name in @('CARGO_TARGET_DIR', 'CARGO_AUTO_COPY', 'CARGO_AUTO_COPY_EXAMPLES', 'CARGO_PROFILE')) {
        if (-not $script:SavedEnv.ContainsKey($name)) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
    }

    # Clean up temp directory
    if ($script:TestRoot -and (Test-Path $script:TestRoot)) {
        Remove-Item -Path $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Test-IsBuildCommand' {
    It 'Recognizes build commands' {
        & $script:TestIsBuildCommand 'build' | Should -BeTrue
        & $script:TestIsBuildCommand 'b' | Should -BeTrue
        & $script:TestIsBuildCommand 'run' | Should -BeTrue
        & $script:TestIsBuildCommand 'r' | Should -BeTrue
        & $script:TestIsBuildCommand 'test' | Should -BeTrue
        & $script:TestIsBuildCommand 't' | Should -BeTrue
        & $script:TestIsBuildCommand 'bench' | Should -BeTrue
        & $script:TestIsBuildCommand 'install' | Should -BeTrue
    }
    It 'Rejects non-build commands' {
        & $script:TestIsBuildCommand 'check' | Should -BeFalse
        & $script:TestIsBuildCommand 'clippy' | Should -BeFalse
        & $script:TestIsBuildCommand 'fmt' | Should -BeFalse
        & $script:TestIsBuildCommand 'clean' | Should -BeFalse
    }
}

Describe 'Get-BuildProfile' {
    BeforeEach {
        Remove-Item Env:CARGO_PROFILE -ErrorAction SilentlyContinue
    }
    It 'Defaults to debug' {
        $result = & $script:GetBuildProfile @('build')
        $result | Should -Be 'debug'
    }
    It 'Detects --release flag' {
        $result = & $script:GetBuildProfile @('build', '--release')
        $result | Should -Be 'release'
    }
    It 'Detects -r flag' {
        $result = & $script:GetBuildProfile @('build', '-r')
        $result | Should -Be 'release'
    }
    It 'Detects --profile=custom' {
        $result = & $script:GetBuildProfile @('build', '--profile=bench')
        $result | Should -Be 'bench'
    }
    It 'Detects --profile custom' {
        $result = & $script:GetBuildProfile @('build', '--profile', 'bench')
        $result | Should -Be 'bench'
    }
    It 'Respects CARGO_PROFILE env var as fallback' {
        $env:CARGO_PROFILE = 'custom-profile'
        $result = & $script:GetBuildProfile @('build')
        $result | Should -Be 'custom-profile'
    }
}

Describe 'Copy-SingleFile' {
    BeforeEach {
        $script:srcDir = Join-Path $script:TestRoot "src_$(Get-Random)"
        $script:dstDir = Join-Path $script:TestRoot "dst_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:srcDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:dstDir -Force | Out-Null
    }

    It 'Copies a file successfully' {
        $srcFile = Join-Path $script:srcDir 'test.exe'
        $dstFile = Join-Path $script:dstDir 'test.exe'
        Set-Content -Path $srcFile -Value 'test content'

        $result = & $script:CopySingleFile -Source $srcFile -Dest $dstFile
        $result | Should -BeTrue
        Test-Path $dstFile | Should -BeTrue
        Get-Content $dstFile | Should -Be 'test content'
    }

    It 'Overwrites existing file' {
        $srcFile = Join-Path $script:srcDir 'test.exe'
        $dstFile = Join-Path $script:dstDir 'test.exe'
        Set-Content -Path $srcFile -Value 'new content'
        Set-Content -Path $dstFile -Value 'old content'

        $result = & $script:CopySingleFile -Source $srcFile -Dest $dstFile
        $result | Should -BeTrue
        Get-Content $dstFile | Should -Be 'new content'
    }

    It 'Returns false for non-existent source' {
        $srcFile = Join-Path $script:srcDir 'nonexistent.exe'
        $dstFile = Join-Path $script:dstDir 'test.exe'

        $result = & $script:CopySingleFile -Source $srcFile -Dest $dstFile
        $result | Should -BeFalse
    }
}

Describe 'Copy-ProfileDirectory' {
    BeforeEach {
        $script:srcProfile = Join-Path $script:TestRoot "profile_src_$(Get-Random)"
        $script:dstProfile = Join-Path $script:TestRoot "profile_dst_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:srcProfile -Force | Out-Null
    }

    It 'Copies files with matching extensions' {
        Set-Content -Path (Join-Path $script:srcProfile 'myapp.exe') -Value 'exe content'
        Set-Content -Path (Join-Path $script:srcProfile 'myapp.pdb') -Value 'pdb content'
        Set-Content -Path (Join-Path $script:srcProfile 'mylib.dll') -Value 'dll content'

        $result = & $script:CopyProfileDirectory -SourceDir $script:srcProfile -DestDir $script:dstProfile
        $result | Should -Be 3
        Test-Path (Join-Path $script:dstProfile 'myapp.exe') | Should -BeTrue
        Test-Path (Join-Path $script:dstProfile 'myapp.pdb') | Should -BeTrue
        Test-Path (Join-Path $script:dstProfile 'mylib.dll') | Should -BeTrue
    }

    It 'Skips files with non-matching extensions' {
        Set-Content -Path (Join-Path $script:srcProfile 'myapp.exe') -Value 'exe'
        Set-Content -Path (Join-Path $script:srcProfile 'build_script.d') -Value 'dep info'
        Set-Content -Path (Join-Path $script:srcProfile 'something.o') -Value 'object'

        $result = & $script:CopyProfileDirectory -SourceDir $script:srcProfile -DestDir $script:dstProfile
        $result | Should -Be 1
        Test-Path (Join-Path $script:dstProfile 'myapp.exe') | Should -BeTrue
        Test-Path (Join-Path $script:dstProfile 'build_script.d') | Should -BeFalse
    }

    It 'Creates destination directory if it does not exist' {
        Set-Content -Path (Join-Path $script:srcProfile 'app.exe') -Value 'test'

        $newDst = Join-Path $script:TestRoot "new_dst_$(Get-Random)"
        $result = & $script:CopyProfileDirectory -SourceDir $script:srcProfile -DestDir $newDst
        $result | Should -Be 1
        Test-Path $newDst | Should -BeTrue
    }

    It 'Skips up-to-date files' {
        Set-Content -Path (Join-Path $script:srcProfile 'app.exe') -Value 'source'
        New-Item -ItemType Directory -Path $script:dstProfile -Force | Out-Null

        $dstFile = Join-Path $script:dstProfile 'app.exe'
        Set-Content -Path $dstFile -Value 'dest'
        # Make dest newer than source
        (Get-Item $dstFile).LastWriteTime = (Get-Date).AddHours(1)

        $result = & $script:CopyProfileDirectory -SourceDir $script:srcProfile -DestDir $script:dstProfile
        $result | Should -Be 0
        Get-Content $dstFile | Should -Be 'dest'
    }

    It 'Copies newer files over older ones' {
        Set-Content -Path (Join-Path $script:srcProfile 'app.exe') -Value 'newer'
        New-Item -ItemType Directory -Path $script:dstProfile -Force | Out-Null

        $dstFile = Join-Path $script:dstProfile 'app.exe'
        Set-Content -Path $dstFile -Value 'older'
        # Make dest older than source
        (Get-Item $dstFile).LastWriteTime = (Get-Date).AddHours(-1)

        $result = & $script:CopyProfileDirectory -SourceDir $script:srcProfile -DestDir $script:dstProfile
        $result | Should -Be 1
        Get-Content $dstFile | Should -Be 'newer'
    }

    It 'Returns 0 for non-existent source directory' {
        $result = & $script:CopyProfileDirectory -SourceDir 'C:\nonexistent\path' -DestDir $script:dstProfile
        $result | Should -Be 0
    }

    Context 'Examples subdirectory' {
        It 'Copies examples when IncludeExamples is set' {
            $examplesDir = Join-Path $script:srcProfile 'examples'
            New-Item -ItemType Directory -Path $examplesDir -Force | Out-Null
            Set-Content -Path (Join-Path $examplesDir 'example1.exe') -Value 'example'

            $result = & $script:CopyProfileDirectory -SourceDir $script:srcProfile -DestDir $script:dstProfile -IncludeExamples
            $result | Should -Be 1
            Test-Path (Join-Path $script:dstProfile 'examples\example1.exe') | Should -BeTrue
        }
        It 'Does not copy examples by default' {
            $examplesDir = Join-Path $script:srcProfile 'examples'
            New-Item -ItemType Directory -Path $examplesDir -Force | Out-Null
            Set-Content -Path (Join-Path $examplesDir 'example1.exe') -Value 'example'

            $result = & $script:CopyProfileDirectory -SourceDir $script:srcProfile -DestDir $script:dstProfile
            $result | Should -Be 0
        }
    }
}

Describe 'Copy-BuildOutputToLocal' {
    BeforeEach {
        $script:projectDir = Join-Path $script:TestRoot "project_$(Get-Random)"
        $script:sharedTarget = Join-Path $script:TestRoot "shared_$(Get-Random)"

        New-Item -ItemType Directory -Path $script:projectDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:sharedTarget -Force | Out-Null

        # Create a minimal Cargo.toml
        Set-Content -Path (Join-Path $script:projectDir 'Cargo.toml') -Value @'
[package]
name = "testpkg"
version = "0.1.0"
'@

        # Create shared profile directory with build outputs
        $releaseDir = Join-Path $script:sharedTarget 'release'
        New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
        Set-Content -Path (Join-Path $releaseDir 'testpkg.exe') -Value 'binary'
        Set-Content -Path (Join-Path $releaseDir 'testpkg.pdb') -Value 'symbols'
        Set-Content -Path (Join-Path $releaseDir 'other.dll') -Value 'library'

        Remove-Item Env:CARGO_AUTO_COPY_EXAMPLES -ErrorAction SilentlyContinue
    }

    It 'Copies build outputs from shared to local target' {
        $result = & $script:CopyBuildOutputToLocal -Profile 'release' -ProjectRoot $script:projectDir -SharedTarget $script:sharedTarget -Quiet
        $result | Should -BeTrue

        $localRelease = Join-Path $script:projectDir 'target\release'
        Test-Path (Join-Path $localRelease 'testpkg.exe') | Should -BeTrue
        Test-Path (Join-Path $localRelease 'testpkg.pdb') | Should -BeTrue
        Test-Path (Join-Path $localRelease 'other.dll') | Should -BeTrue
    }

    It 'Returns false when no Cargo.toml exists' {
        $emptyDir = Join-Path $script:TestRoot "empty_$(Get-Random)"
        New-Item -ItemType Directory -Path $emptyDir -Force | Out-Null

        $result = & $script:CopyBuildOutputToLocal -Profile 'release' -ProjectRoot $emptyDir -SharedTarget $script:sharedTarget -Quiet
        $result | Should -BeFalse
    }

    It 'Returns false when shared profile dir does not exist' {
        $result = & $script:CopyBuildOutputToLocal -Profile 'nonexistent' -ProjectRoot $script:projectDir -SharedTarget $script:sharedTarget -Quiet
        $result | Should -BeFalse
    }

    It 'Copies all extension-matched files regardless of package name' {
        # The new implementation copies ALL matching files, not just per-package ones
        $releaseDir = Join-Path $script:sharedTarget 'release'
        Set-Content -Path (Join-Path $releaseDir 'unknown_binary.exe') -Value 'unknown'

        $result = & $script:CopyBuildOutputToLocal -Profile 'release' -ProjectRoot $script:projectDir -SharedTarget $script:sharedTarget -Quiet
        $result | Should -BeTrue

        $localRelease = Join-Path $script:projectDir 'target\release'
        Test-Path (Join-Path $localRelease 'unknown_binary.exe') | Should -BeTrue
    }
}

Describe 'Test-AutoCopyEnabled' {
    BeforeEach {
        Remove-Item Env:CARGO_AUTO_COPY -ErrorAction SilentlyContinue
        Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    }
    It 'Returns false by default for local project targets' {
        & $script:TestAutoCopyEnabled | Should -BeFalse
    }
    It 'Returns false when CARGO_AUTO_COPY is 0' {
        $env:CARGO_AUTO_COPY = '0'
        & $script:TestAutoCopyEnabled | Should -BeFalse
    }
    It 'Returns false when CARGO_AUTO_COPY is false' {
        $env:CARGO_AUTO_COPY = 'false'
        & $script:TestAutoCopyEnabled | Should -BeFalse
    }
    It 'Returns true when CARGO_AUTO_COPY is 1' {
        $env:CARGO_AUTO_COPY = '1'
        & $script:TestAutoCopyEnabled | Should -BeTrue
    }
    It 'Returns true when CARGO_TARGET_DIR points outside the local project target root' {
        $projectDir = Join-Path $script:TestRoot "autocopy_project_$(Get-Random)"
        New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
        Set-Content -Path (Join-Path $projectDir 'Cargo.toml') -Value @'
[package]
name = "auto-copy"
version = "0.1.0"
'@
        $env:CARGO_TARGET_DIR = 'C:\shared\target'
        & $script:TestAutoCopyEnabled -ProjectRoot $projectDir | Should -BeTrue
    }
}

Describe 'Get-PackageNames' {
    It 'Extracts package name from Cargo.toml' {
        $tomlPath = Join-Path $script:TestRoot "manifest_$(Get-Random).toml"
        Set-Content -Path $tomlPath -Value @'
[package]
name = "my-crate"
version = "1.0.0"
'@
        $result = & $script:GetPackageNames -ManifestPath $tomlPath
        $result | Should -Contain 'my-crate'
    }
    It 'Returns empty for non-existent file' {
        $result = & $script:GetPackageNames -ManifestPath 'C:\nonexistent\Cargo.toml'
        $result | Should -HaveCount 0
    }
}
