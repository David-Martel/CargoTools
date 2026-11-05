<#
.SYNOPSIS
Checks that every PowerShell session on this host loads CargoTools from one up-to-date git checkout.

.DESCRIPTION
A copied, unversioned CargoTools drifts silently: dtm-p1gen7 ran a hand-patched 0.9.0 copy long after main had moved
on, and nothing reported it. This script starts fresh sessions (pwsh -NoProfile, pwsh with the profile and Windows
PowerShell 5.1, and the same over ssh with -SshTarget) and in each one checks that:

  1. exactly one CargoTools module base is on PSModulePath (a second copy can shadow the first), and every session on
     a host selects the same one (a profile or edition-specific path must not pick a different clone). Paths are
     compared after following junctions and symbolic links, so a link to the checkout is that checkout;
  2. no other CargoTools sits in a per-user module folder (<Documents>\PowerShell\Modules or
     <Documents>\WindowsPowerShell\Modules). PowerShell adds those folders to PSModulePath on its own, and when
     Documents is OneDrive-synced another host's clone can arrive there: dtm-work keeps its clone in a Documents
     that dtm-p1gen7 also syncs;
  3. that base is the top level of a git work tree with no uncommitted changes to tracked files;
  4. its HEAD is origin/main, fetched first unless -NoFetch. A failed fetch fails the check, because the cached ref
     cannot show whether HEAD is current;
  5. Import-Module CargoTools loads that base, at the version its manifest declares;
  6. with -BuildEnvironment, Test-BuildEnvironment -Detailed runs without throwing.

It prints one [PASS] or [FAIL] line per session and exits 0 when every session passes, otherwise 1. It compiles
nothing. Tests/InstallCheck.Tests.ps1 covers it, including the failures it must report.

.PARAMETER Session
Which sessions to probe: NoProfile (pwsh -NoProfile), Profile (pwsh) and Desktop (powershell.exe -NoProfile, Windows
PowerShell 5.1). The default is all three.

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
directories; a real check leaves it unset. The token {edition} becomes the session's PSEdition (Core or Desktop), so
a test can give the two editions different paths.

.PARAMETER UserModuleRootOverride
Replace the per-user module folders that check 2 scans. Tests use it; a real check leaves it unset.

.EXAMPLE
./tools/Test-CargoToolsInstall.ps1 -BuildEnvironment -SshTarget localhost
#>
[CmdletBinding()]
param(
    [ValidateSet('NoProfile', 'Profile', 'Desktop')][string[]]$Session = @('NoProfile', 'Profile', 'Desktop'),
    [string]$SshTarget,
    [string]$Branch = 'main',
    [switch]$NoFetch,
    [switch]$BuildEnvironment,
    [string]$PSModulePathOverride,
    [string[]]$UserModuleRootOverride
)

$ErrorActionPreference = 'Stop'

# Runs inside each probe session and prints one tagged JSON line. Parameters arrive as a JSON argument so the same
# text works locally, over ssh and in Windows PowerShell 5.1. Native commands run under 'Continue': 5.1 turns
# redirected stderr into a terminating error under 'Stop', and every native result is checked through $LASTEXITCODE.
$probe = @'
param([string]$ArgsJson)
$ErrorActionPreference = 'Continue'
$a = $ArgsJson | ConvertFrom-Json
if ($a.override) { $env:PSModulePath = $a.override.Replace('{edition}', [string]$PSVersionTable.PSEdition) }
$r = [ordered]@{ machine = [Environment]::MachineName; bases = @(); strays = @(); gitTop = $null; dirty = $null
    statusFailed = $false; fetchFailed = $false; head = $null; remote = $null; manifestVersion = $null; version = $null
    base = $null; buildEnvironment = $null; error = $null }
function Resolve-PhysicalPath([string]$Path, [int]$Depth = 0) {
    # Follows junctions and symbolic links in every path component, so a link to the checkout counts as the checkout,
    # not as a second copy (dtm-work gives Windows PowerShell 5.1 the OneDrive clone through a junction). A link's
    # target is resolved the same way, so chains and links inside a target resolve too; past 32 hops (a cycle) the
    # path stays as it is, so a cycle cannot make two copies look like one.
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($Depth -gt 32) { return $full }
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root.TrimEnd('\', '/')
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path ($current + '\') $part
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.LinkType -eq 'Junction' -or $item.LinkType -eq 'SymbolicLink') -and $item.Target) {
            $target = (@($item.Target)[0]) -replace '^\\\\\?\\', ''
            if (-not [IO.Path]::IsPathRooted($target)) { $target = Join-Path (Split-Path -Parent $current) $target }
            $current = Resolve-PhysicalPath $target ($Depth + 1)
        }
    }
    return $current
}
try {
    # One entry per physical directory: a junction to the same checkout is not a second copy.
    $r.bases = @(Get-Module -ListAvailable CargoTools | ForEach-Object { Resolve-PhysicalPath $_.ModuleBase } | Select-Object -Unique)
    $docs = [Environment]::GetFolderPath('MyDocuments')
    $userRoots = if ($a.userRoots) { @($a.userRoots) } else { @((Join-Path $docs 'PowerShell\Modules'), (Join-Path $docs 'WindowsPowerShell\Modules')) }
    $known = @($r.bases)
    $r.strays = @(foreach ($root in $userRoots) {
        $candidate = Join-Path $root 'CargoTools'
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        $container = Resolve-PhysicalPath $candidate
        # A versioned install (CargoTools\0.9.2) reports the version folder as its base, inside this container.
        $isKnown = @($known | Where-Object { $_ -eq $container -or $_.StartsWith($container + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $isKnown) { $candidate }
    })
    if ($r.bases.Count -eq 1) {
        $base = $r.bases[0]
        $r.manifestVersion = [string](Import-PowerShellDataFile (Join-Path $base 'CargoTools.psd1') -ErrorAction Stop).ModuleVersion
        $top = git -C $base rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0 -and $top) {
            $r.gitTop = [IO.Path]::GetFullPath($top)
            $status = git -C $base status --porcelain --untracked-files=no 2>$null
            $r.statusFailed = $LASTEXITCODE -ne 0
            $r.dirty = [bool]$status
            if ($a.fetch) {
                git -C $base fetch --quiet origin $a.branch 2>$null | Out-Null
                $r.fetchFailed = $LASTEXITCODE -ne 0
            }
            $r.head = git -C $base rev-parse HEAD
            $r.remote = git -C $base rev-parse --verify --quiet "refs/remotes/origin/$($a.branch)"
        }
        Import-Module CargoTools -Force -ErrorAction Stop
        $m = Get-Module CargoTools
        $r.version = [string]$m.Version
        $r.base = Resolve-PhysicalPath $m.ModuleBase
        if ($a.buildEnvironment) { Test-BuildEnvironment -Detailed *>&1 | Out-Null; $r.buildEnvironment = 'ran' }
    }
} catch { $r.error = $_.Exception.Message }
'CARGOTOOLS_PROBE ' + ($r | ConvertTo-Json -Compress)
'@

$argsJson = @{ override = $PSModulePathOverride; userRoots = @($UserModuleRootOverride | Where-Object { $_ }); branch = $Branch
    fetch = -not $NoFetch; buildEnvironment = [bool]$BuildEnvironment } | ConvertTo-Json -Compress
# -EncodedCommand cannot take script arguments, so the arguments are embedded as a literal in the command.
$command = "& { $probe } -ArgsJson '$($argsJson -replace "'", "''")'"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source

function Get-SessionFailure([object]$r) {
    # Returns the first failed check for one session, or $null when all pass.
    if ($null -eq $r) { return 'the probe printed no result' }
    if ($r.bases.Count -eq 0) { return 'CargoTools is not on PSModulePath' }
    if ($r.bases.Count -gt 1) { return "$($r.bases.Count) CargoTools copies on PSModulePath ($($r.bases -join '; ')); one can shadow the other" }
    if (@($r.strays).Count) { return "CargoTools copy in a per-user module folder that PowerShell can add to PSModulePath ($(@($r.strays) -join '; ')); with a OneDrive-synced Documents it may be another host's clone" }
    $base = [IO.Path]::GetFullPath($r.bases[0]).TrimEnd('\', '/')
    if (-not $r.gitTop -or -not [string]::Equals($r.gitTop.TrimEnd('\', '/'), $base, [StringComparison]::OrdinalIgnoreCase)) { return "$base is not a git checkout" }
    if ($r.statusFailed) { return "git status failed in $base, so its tracked files could not be checked" }
    if ($r.dirty) { return "$base has uncommitted changes to tracked files" }
    if ($r.fetchFailed) { return "git fetch origin $Branch failed in $base, so the cached origin/$Branch cannot show whether HEAD is current" }
    if (-not $r.remote) { return "$base has no origin/$Branch ref" }
    if ($r.head -ne $r.remote) { return "$base HEAD $($r.head) is not origin/$Branch $($r.remote)" }
    if ($r.error) { return "import failed: $($r.error)" }
    if (-not [string]::Equals(([IO.Path]::GetFullPath($r.base)).TrimEnd('\', '/'), $base, [StringComparison]::OrdinalIgnoreCase)) { return "Import-Module loaded $($r.base), not $base" }
    if ($r.version -ne $r.manifestVersion) { return "loaded version $($r.version) differs from the manifest's $($r.manifestVersion)" }
    if ($BuildEnvironment -and $r.buildEnvironment -ne 'ran') { return 'Test-BuildEnvironment -Detailed did not run' }
    return $null
}

$runs = foreach ($s in $Session) {
    $exe = if ($s -eq 'Desktop') { 'powershell' } else { 'pwsh' }
    $local = if ($s -eq 'Desktop') { (Get-Command powershell -CommandType Application | Select-Object -First 1).Source } else { $pwsh }
    $flags = @('-NoLogo') + $(if ($s -ne 'Profile') { @('-NoProfile') } else { @() }) + @('-EncodedCommand', $encoded)
    @{ Name = "local $s"; Output = { & $local @flags 2>&1 }.GetNewClosure() }
    if ($SshTarget) {
        $remote = "$exe $($flags -join ' ')"
        @{ Name = "ssh $SshTarget $s"; Output = { & ssh -o BatchMode=yes -o ConnectTimeout=15 $SshTarget $remote 2>&1 }.GetNewClosure() }
    }
}

$failed = 0
# Keyed by the machine name each probe reports, so ssh to localhost and local sessions count as one host.
$selected = @{}   # machine -> the base its first passing session loaded
foreach ($run in $runs) {
    $lines = @(& $run.Output | ForEach-Object { [string]$_ })
    $line = $lines | Where-Object { $_ -like 'CARGOTOOLS_PROBE *' } | Select-Object -Last 1
    $result = if ($line) { $line.Substring('CARGOTOOLS_PROBE '.Length) | ConvertFrom-Json } else { $null }
    $failure = Get-SessionFailure $result
    if (-not $failure) {
        $chosen = [IO.Path]::GetFullPath($result.base).TrimEnd('\', '/')
        if (-not $selected.ContainsKey($result.machine)) { $selected[$result.machine] = $chosen }
        elseif (-not [string]::Equals($selected[$result.machine], $chosen, [StringComparison]::OrdinalIgnoreCase)) {
            $failure = "selects $chosen, but another session on this host selects $($selected[$result.machine])"
        }
    }
    if ($failure) {
        $failed++
        Write-Output "[FAIL] $($run.Name): $failure"
        if (-not $line) { $lines | Select-Object -Last 5 | ForEach-Object { Write-Output "       $_" } }
    } else {
        Write-Output "[PASS] $($run.Name): CargoTools $($result.version) from $($result.base) at origin/$Branch $($result.head.Substring(0, 10))"
    }
}
exit $(if ($failed) { 1 } else { 0 })
