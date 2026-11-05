<#
.SYNOPSIS
Checks that every PowerShell session on this host loads CargoTools from one up-to-date git checkout.

.DESCRIPTION
A copied, unversioned CargoTools drifts silently: dtm-p1gen7 ran a hand-patched 0.9.0 copy long after main had moved
on, and nothing reported it. This script starts fresh sessions (pwsh -NoProfile and pwsh with the profile, and the same
over ssh with -SshTarget) and in each one checks that:

  1. exactly one CargoTools module base is on PSModulePath (a second copy can shadow the first);
  2. that base is the top level of a git work tree with no uncommitted changes to tracked files;
  3. its HEAD is origin/main (fetched first unless -NoFetch);
  4. Import-Module CargoTools loads that base, at the version its manifest declares;
  5. with -BuildEnvironment, Test-BuildEnvironment -Detailed runs without throwing.

It prints one [PASS] or [FAIL] line per session and exits 0 when every session passes, otherwise 1. It compiles
nothing. Tests/InstallCheck.Tests.ps1 covers it, including the failures it must report.

.PARAMETER Session
Which local sessions to probe: NoProfile, Profile, or both (default).

.PARAMETER SshTarget
Also probe the same sessions over ssh on this target (for example localhost). The remote default shell must run
PowerShell commands.

.PARAMETER Branch
The remote branch HEAD must equal (default main).

.PARAMETER NoFetch
Compare with the existing origin/<Branch> ref instead of fetching it first.

.PARAMETER BuildEnvironment
Also run Test-BuildEnvironment -Detailed in each session.

.PARAMETER PSModulePathOverride
Replace PSModulePath inside each probe session before the checks. Tests use it to point the check at fixture
directories; a real check leaves it unset.

.EXAMPLE
./tools/Test-CargoToolsInstall.ps1 -BuildEnvironment -SshTarget localhost
#>
[CmdletBinding()]
param(
    [ValidateSet('NoProfile', 'Profile')][string[]]$Session = @('NoProfile', 'Profile'),
    [string]$SshTarget,
    [string]$Branch = 'main',
    [switch]$NoFetch,
    [switch]$BuildEnvironment,
    [string]$PSModulePathOverride
)

$ErrorActionPreference = 'Stop'

# Runs inside each probe session and prints one tagged JSON line. Parameters arrive as a JSON argument so the same
# text works locally and over ssh.
$probe = @'
param([string]$ArgsJson)
$ErrorActionPreference = 'Stop'
$a = $ArgsJson | ConvertFrom-Json
if ($a.override) { $env:PSModulePath = $a.override }
$r = [ordered]@{ bases = @(); gitTop = $null; dirty = $null; head = $null; remote = $null; manifestVersion = $null
    version = $null; base = $null; buildEnvironment = $null; error = $null }
try {
    $r.bases = @(Get-Module -ListAvailable CargoTools | ForEach-Object { $_.ModuleBase } | Select-Object -Unique)
    if ($r.bases.Count -eq 1) {
        $base = $r.bases[0]
        $r.manifestVersion = [string](Import-PowerShellDataFile (Join-Path $base 'CargoTools.psd1')).ModuleVersion
        $top = git -C $base rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) {
            $r.gitTop = [IO.Path]::GetFullPath($top)
            $r.dirty = [bool](git -C $base status --porcelain --untracked-files=no)
            if ($a.fetch) { git -C $base fetch --quiet origin $a.branch 2>$null | Out-Null }
            $r.head = git -C $base rev-parse HEAD
            $r.remote = git -C $base rev-parse --verify --quiet "refs/remotes/origin/$($a.branch)"
        }
        Import-Module CargoTools -Force
        $m = Get-Module CargoTools
        $r.version = [string]$m.Version
        $r.base = $m.ModuleBase
        if ($a.buildEnvironment) { Test-BuildEnvironment -Detailed *>&1 | Out-Null; $r.buildEnvironment = 'ran' }
    }
} catch { $r.error = $_.Exception.Message }
'CARGOTOOLS_PROBE ' + ($r | ConvertTo-Json -Compress)
'@

$argsJson = @{ override = $PSModulePathOverride; branch = $Branch; fetch = -not $NoFetch; buildEnvironment = [bool]$BuildEnvironment } |
    ConvertTo-Json -Compress
# -EncodedCommand cannot take script arguments, so the arguments are embedded as a literal in the command.
$command = "& { $probe } -ArgsJson '$($argsJson -replace "'", "''")'"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

function Get-SessionFailure([object]$r) {
    # Returns the first failed check for one session, or $null when all pass.
    if ($null -eq $r) { return 'the probe printed no result' }
    if ($r.bases.Count -eq 0) { return 'CargoTools is not on PSModulePath' }
    if ($r.bases.Count -gt 1) { return "$($r.bases.Count) CargoTools copies on PSModulePath ($($r.bases -join '; ')); one can shadow the other" }
    $base = [IO.Path]::GetFullPath($r.bases[0]).TrimEnd('\', '/')
    if (-not $r.gitTop -or -not [string]::Equals($r.gitTop.TrimEnd('\', '/'), $base, [StringComparison]::OrdinalIgnoreCase)) { return "$base is not a git checkout" }
    if ($r.dirty) { return "$base has uncommitted changes to tracked files" }
    if (-not $r.remote) { return "$base has no origin/$Branch ref" }
    if ($r.head -ne $r.remote) { return "$base HEAD $($r.head) is not origin/$Branch $($r.remote)" }
    if ($r.error) { return "import failed: $($r.error)" }
    if (-not [string]::Equals(([IO.Path]::GetFullPath($r.base)).TrimEnd('\', '/'), $base, [StringComparison]::OrdinalIgnoreCase)) { return "Import-Module loaded $($r.base), not $base" }
    if ($r.version -ne $r.manifestVersion) { return "loaded version $($r.version) differs from the manifest's $($r.manifestVersion)" }
    if ($BuildEnvironment -and $r.buildEnvironment -ne 'ran') { return 'Test-BuildEnvironment -Detailed did not run' }
    return $null
}

$runs = foreach ($s in $Session) {
    $flags = @('-NoLogo') + $(if ($s -eq 'NoProfile') { @('-NoProfile') } else { @() }) + @('-EncodedCommand', $encoded)
    @{ Name = "local $s"; Output = { & $pwsh @flags 2>&1 }.GetNewClosure() }
    if ($SshTarget) {
        $remote = "pwsh $($flags -join ' ')"
        @{ Name = "ssh $SshTarget $s"; Output = { & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshTarget $remote 2>&1 }.GetNewClosure() }
    }
}

$failed = 0
foreach ($run in $runs) {
    $lines = @(& $run.Output | ForEach-Object { [string]$_ })
    $line = $lines | Where-Object { $_ -like 'CARGOTOOLS_PROBE *' } | Select-Object -Last 1
    $result = if ($line) { $line.Substring('CARGOTOOLS_PROBE '.Length) | ConvertFrom-Json } else { $null }
    $failure = Get-SessionFailure $result
    if ($failure) {
        $failed++
        Write-Output "[FAIL] $($run.Name): $failure"
        if (-not $line) { $lines | Select-Object -Last 5 | ForEach-Object { Write-Output "       $_" } }
    } else {
        Write-Output "[PASS] $($run.Name): CargoTools $($result.version) from $($result.base) at origin/$Branch $($result.head.Substring(0, 10))"
    }
}
exit $(if ($failed) { 1 } else { 0 })
