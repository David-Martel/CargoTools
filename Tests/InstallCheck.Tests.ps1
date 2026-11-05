#Requires -Version 7.0
# tools/Test-CargoToolsInstall.ps1 decides whether a host loads CargoTools from one current git checkout. Why: a
# hand-copied 0.9.0 sat on dtm-p1gen7's PSModulePath, patched in place, while main moved to 0.9.2; nothing failed, so
# nobody noticed. These cases prove the check fails for each way that state can recur (no module, an unversioned copy,
# a second copy, a copy in a per-user module folder, a stale HEAD, a failed fetch, local edits) and passes for a clean
# checkout at origin/main, in pwsh and in Windows PowerShell 5.1. They point the check at fixture directories through
# -PSModulePathOverride and -UserModuleRootOverride, use no network and compile nothing. The case tagged Integration
# checks the real host and is excluded from CI.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Check = Join-Path $script:RepoRoot 'tools/Test-CargoToolsInstall.ps1'
    $script:Pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

    function Invoke-InstallCheck([string[]]$ModulePath, [string]$Session = 'NoProfile', [string]$UserRoot = (New-Root), [switch]$Fetch) {
        # $UserRoot stands in for <Documents>\PowerShell\Modules, so the host's own Documents never decides a case.
        $extra = @(if (-not $Fetch) { '-NoFetch' })
        $output = & $script:Pwsh -NoLogo -NoProfile -File $script:Check -Session $Session @extra `
            -PSModulePathOverride ($ModulePath -join [IO.Path]::PathSeparator) -UserModuleRootOverride $UserRoot 2>&1 | Out-String
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

    It 'fails when the fetch fails instead of trusting the cached origin/main' {
        # Review of #25 (codex): a failed fetch left the old ref in place, so a stale checkout passed.
        $install = New-GitInstall
        git -C $install.Module remote set-url origin (Join-Path $TestDrive 'no-such-remote')
        $result = Invoke-InstallCheck @($install.Root) -Fetch
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'git fetch origin main failed'
    }

    It 'fails when a per-user module folder holds another copy, even off PSModulePath' {
        # dtm-work keeps its clone in a OneDrive-synced Documents that dtm-p1gen7 also syncs; once synced it would sit in
        # <Documents>\PowerShell\Modules, which pwsh puts first on PSModulePath.
        $result = Invoke-InstallCheck @((New-GitInstall).Root) -UserRoot (New-CopyInstall).Root
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'per-user module folder'
    }

    It 'fails when git status cannot read the checkout' {
        # Review of #25 (codex, round 2): a failing `git status` prints nothing, which read as "clean".
        $install = New-GitInstall
        [IO.File]::WriteAllText((Join-Path $install.Module '.git/index'), 'not an index')
        $result = Invoke-InstallCheck @($install.Root)
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match 'git status failed'
    }

    It 'fails when two sessions on the host select different clean checkouts' {
        # Review of #25 (codex, round 2): each session was judged alone, so pwsh and 5.1 could load different clones.
        $root = New-Root
        foreach ($edition in 'Core', 'Desktop') {
            $module = Join-Path $root "$edition/CargoTools"
            git clone --quiet --no-hardlinks $script:RepoRoot $module 2>&1 | Out-Null
            git -C $module update-ref refs/remotes/origin/main HEAD
        }
        $userRoot = New-Root
        $command = "& '$script:Check' -Session NoProfile,Desktop -NoFetch -PSModulePathOverride '$(Join-Path $root '{edition}')' -UserModuleRootOverride '$userRoot'; exit `$LASTEXITCODE"
        $text = & $script:Pwsh -NoLogo -NoProfile -Command $command 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1 -Because $text
        $text | Should -Match '\[PASS\] local NoProfile: '
        $text | Should -Match '\[FAIL\] local Desktop: selects .*Desktop.CargoTools, but another session on this host selects .*Core.CargoTools'
    }

    It 'accepts a checkout installed in a version folder of a per-user module folder' {
        # Review of #25 (codex, round 3): a base of <root>\CargoTools\<version> was taken for a second copy at
        # <root>\CargoTools.
        $root = New-Root
        $version = (Import-PowerShellDataFile (Join-Path $script:RepoRoot 'CargoTools.psd1')).ModuleVersion
        $module = Join-Path $root "CargoTools/$version"
        git clone --quiet --no-hardlinks $script:RepoRoot $module 2>&1 | Out-Null
        git -C $module update-ref refs/remotes/origin/main HEAD
        $result = Invoke-InstallCheck @($root) -UserRoot $root
        $result.Code | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match "\[PASS\] local NoProfile: CargoTools $([regex]::Escape($version)) from "
    }

    It 'counts a junction to the checkout as that checkout, in pwsh and Windows PowerShell 5.1' {
        # dtm-work gives 5.1 its OneDrive clone through a junction on a 5.1-only module path. pwsh then lists the clone
        # twice (real path and junction); both are one physical copy, and both editions select it.
        $install = New-GitInstall
        $linkRoot = New-Root
        [void](New-Item -ItemType Junction -Path (Join-Path $linkRoot 'CargoTools') -Target $install.Module)
        $both = Invoke-InstallCheck @($install.Root, $linkRoot)
        $both.Code | Should -Be 0 -Because $both.Text
        $desktop = Invoke-InstallCheck @($linkRoot) -Session Desktop
        $desktop.Code | Should -Be 0 -Because $desktop.Text
        $desktop.Text | Should -Match ([regex]::Escape("from $($install.Module)"))
    }

    It 'still fails a real second copy next to a junction (control for the case above)' {
        $install = New-GitInstall
        $linkRoot = New-Root
        [void](New-Item -ItemType Junction -Path (Join-Path $linkRoot 'CargoTools') -Target $install.Module)
        $result = Invoke-InstallCheck @($install.Root, $linkRoot, (New-CopyInstall).Root)
        $result.Code | Should -Be 1 -Because $result.Text
        $result.Text | Should -Match '2 CargoTools copies on PSModulePath'
    }

    It 'passes the same clean checkout in Windows PowerShell 5.1' {
        $result = Invoke-InstallCheck @((New-GitInstall).Root) -Session Desktop
        $result.Code | Should -Be 0 -Because $result.Text
        $result.Text | Should -Match '\[PASS\] local Desktop: '
    }

    It 'passes on this host in every session, with Test-BuildEnvironment' -Tag 'Integration' {
        $output = & $script:Pwsh -NoLogo -NoProfile -File $script:Check -BuildEnvironment 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
    }
}
