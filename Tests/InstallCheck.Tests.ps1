#Requires -Version 7.0
# tools/Test-CargoToolsInstall.ps1 decides whether a host loads CargoTools from one current git checkout. Why: a
# hand-copied 0.9.0 sat on dtm-p1gen7's PSModulePath, patched in place, while main moved to 0.9.2; nothing failed, so
# nobody noticed. These cases prove the check fails for each way that state can recur (no module, an unversioned copy,
# a second copy, a stale HEAD, local edits) and passes for a clean checkout at origin/main. They point the check at
# fixture directories through -PSModulePathOverride, use no network (-NoFetch) and compile nothing. The case tagged
# Integration checks the real host and is excluded from CI.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Check = Join-Path $script:RepoRoot 'tools/Test-CargoToolsInstall.ps1'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

    function Invoke-InstallCheck([string[]]$ModulePath, [string[]]$Extra = @()) {
        $output = & $script:Pwsh -NoLogo -NoProfile -File $script:Check -Session NoProfile -NoFetch `
            -PSModulePathOverride ($ModulePath -join [IO.Path]::PathSeparator) @Extra 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Text = $output }
    }
    function New-Root {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $root)
        return $root
    }
    function New-GitInstall {
        # A clone of this repository whose origin/main is its HEAD: the state the check must accept.
        $root = New-Root
        $module = Join-Path $root 'CargoTools'
        git clone --quiet --no-hardlinks $script:RepoRoot $module 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'git clone of the repository failed' }
        git -C $module update-ref refs/remotes/origin/main HEAD
        return @{ Root = $root; Module = $module }
    }
    function New-CopyInstall {
        # The module files without .git: how the stale 0.9.0 copy was installed.
        $root = New-Root
        $module = Join-Path $root 'CargoTools'
        [void](New-Item -ItemType Directory -Path $module)
        Get-ChildItem -LiteralPath $script:RepoRoot -Force | Where-Object Name -ne '.git' |
            Copy-Item -Destination $module -Recurse -Force
        return @{ Root = $root; Module = $module }
    }
}

Describe 'Test-CargoToolsInstall' {
    It 'passes a clean git checkout at origin/main (positive control for the failures below)' {
        $install = New-GitInstall
        $result = Invoke-InstallCheck @($install.Root)
        $result.Code | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match '\[PASS\] local NoProfile: CargoTools \S+ from '
    }

    It 'fails when PSModulePath holds no CargoTools' {
        $result = Invoke-InstallCheck @((New-Root))
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'CargoTools is not on PSModulePath'
    }

    It 'fails an unversioned copy of the module files' {
        $result = Invoke-InstallCheck @((New-CopyInstall).Root)
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'is not a git checkout'
    }

    It 'fails when a second copy is on PSModulePath next to the checkout' {
        $result = Invoke-InstallCheck @((New-GitInstall).Root, (New-CopyInstall).Root)
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match '2 CargoTools copies on PSModulePath'
    }

    It 'fails a checkout whose HEAD is not origin/main' {
        $install = New-GitInstall
        # A commit object built by hand moves origin/main ahead without running commit hooks.
        $tree = git -C $install.Module rev-parse 'HEAD^{tree}'
        $head = git -C $install.Module rev-parse HEAD
        $body = "tree $tree`nparent $head`nauthor fixture <fixture@example.invalid> 0 +0000`ncommitter fixture <fixture@example.invalid> 0 +0000`n`nnewer main`n"
        $newer = $body | git -C $install.Module hash-object -t commit -w --stdin
        git -C $install.Module update-ref refs/remotes/origin/main $newer
        $result = Invoke-InstallCheck @($install.Root)
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'is not origin/main'
    }

    It 'fails a checkout with uncommitted changes to tracked files' {
        $install = New-GitInstall
        Add-Content -LiteralPath (Join-Path $install.Module 'CargoTools.psm1') -Value '# local hotfix'
        $result = Invoke-InstallCheck @($install.Root)
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'uncommitted changes'
    }

    It 'passes on this host in every session, with Test-BuildEnvironment' -Tag 'Integration' {
        $output = & $script:Pwsh -NoLogo -NoProfile -File $script:Check -BuildEnvironment 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
    }
}
