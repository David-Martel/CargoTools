#requires -Version 5.1

Set-StrictMode -Version Latest

<#
.SYNOPSIS
    Resolve a usable sccache server port, avoiding Windows "excluded port ranges".

.DESCRIPTION
    Windows reserves TCP port ranges for Hyper-V / WSL / WinNAT (visible via
    `netsh int ipv4 show excludedportrange protocol=tcp`). If SCCACHE_SERVER_PORT lands inside one
    of these ranges, `sccache --start-server` fails with os error 10013
    ("An attempt was made to access a socket in a way forbidden by its access permissions") and every
    cached build silently runs uncached or fails. The reserved ranges shift across reboots / Windows
    updates, so a once-good port (e.g. 14400) can become blocked later.

    This function validates the desired port against the live exclusion table and, if it is reserved,
    returns the first free port in a safe band. On non-Windows hosts or if netsh is unavailable it
    still checks whether the requested port can be used locally.

.PARAMETER DesiredPort
    The configured/default sccache server port (string, e.g. from $env:SCCACHE_SERVER_PORT).

.OUTPUTS
    [string] a port guaranteed (best-effort) not to be in a Windows excluded range.
#>
function Get-SccachePortStateFile {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CacheRoot)
    return (Join-Path $CacheRoot 'sccache\resolved-port.txt')
}

function Resolve-FreeSccachePort {
    <#
    .DESCRIPTION
    Beyond avoiding Windows-excluded port ranges (see below), this also converges every
    session on this machine onto ONE shared sccache server instead of each independently
    resolving its own port. Reproduced 2026-07-24: with no shared state, concurrent agent
    sessions each ran their own scan-for-a-free-port logic, landed on DIFFERENT ports, and
    each started its OWN sccache server - 4 simultaneous server processes observed, plus
    "os error 10048" (two servers racing to bind the same port) and repeated client
    "timed out" errors in T:\RustCache\sccache\error.log from clients whose server had
    since been replaced/killed by another session's consolidation attempt.

    Fix: persist the resolved port to $CacheRoot\sccache\resolved-port.txt. A new session
    checks that file FIRST and reuses it if a healthy server already answers there -
    skipping the scan entirely - so the whole machine converges on one server. Only when
    there's no persisted port, or the persisted server isn't responding, does this fall
    back to the original excluded-range scan, and it then persists whatever it finds for
    the next session to reuse. This is deliberately best-effort/racy under concurrent
    first-run (two sessions starting at the exact same instant could still pick different
    ports once) - not worth a cross-process lock for a cache-warming optimization; it
    self-corrects on the next call once the file exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$DesiredPort,
        [string]$CacheRoot
    )

    # State is opt-in: direct callers without a cache root retain their requested
    # port and do not read or change another workspace's machine-wide state.
    $stateFile = if ($CacheRoot) { Get-SccachePortStateFile -CacheRoot $CacheRoot } else { $null }
    if ($stateFile -and (Test-Path -LiteralPath $stateFile)) {
        try {
            $persisted = (Get-Content -LiteralPath $stateFile -Raw -ErrorAction Stop).Trim()
            $persistedPort = 0
            if ([int]::TryParse($persisted, [ref]$persistedPort) -and $persistedPort -gt 0 -and $persistedPort -le 65535) {
                if (Test-SccachePortAvailable -Port $persistedPort) {
                    return "$persistedPort"
                }
            }
        } catch {
            # Corrupt/unreadable state file - fall through to a fresh resolve below.
            Write-Verbose "Could not reuse persisted sccache port: $($_.Exception.Message)"
        }
    }

    $port = 0
    if (-not [int]::TryParse($DesiredPort, [ref]$port) -or $port -le 0 -or $port -gt 65535) { $port = 4400 }

    # Parse the live Windows TCP exclusion table. If unavailable, a local bind
    # check still detects occupied ports before selecting or persisting one.
    $ranges = @()
    try {
        $rows = & netsh int ipv4 show excludedportrange protocol=tcp 2>$null
        foreach ($line in $rows) {
            if ($line -match '^\s*(\d+)\s+(\d+)\s*$') {
                $ranges += [pscustomobject]@{ Start = [int]$Matches[1]; End = [int]$Matches[2] }
            }
        }
    } catch {
        Write-Verbose 'Windows port exclusions unavailable; checking local port availability.'
    }

    $resolved = $null
    if (
        -not (Test-SccachePortExcluded -Port $port -Ranges $ranges) -and
        (Test-SccachePortAvailable -Port $port)
    ) {
        $resolved = "$port"
    } else {
        foreach ($candidate in 4200..4599) {
            if (
                -not (Test-SccachePortExcluded -Port $candidate -Ranges $ranges) -and
                (Test-SccachePortAvailable -Port $candidate)
            ) {
                Write-Warning ("CargoTools: sccache port {0} is unavailable or in a Windows excluded port range; using free port {1} instead." -f $port, $candidate)
                $resolved = "$candidate"
                break
            }
        }
    }

    if ($resolved) {
        if ($stateFile) {
            try {
                $stateDir = Split-Path -Parent $stateFile
                if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
                [System.IO.File]::WriteAllText($stateFile, $resolved, [System.Text.UTF8Encoding]::new($false))
            } catch {
                # Best-effort persistence; a failure here just means the next session re-scans.
                Write-Verbose "Could not persist sccache port: $($_.Exception.Message)"
            }
        }
        return $resolved
    }

    # No free port found in the preferred band; surface the original and let sccache report the bind
    # failure loudly rather than picking an arbitrary high port.
    Write-Warning ("CargoTools: sccache port {0} is excluded and no free port was found in 4200-4599." -f $port)
    return "$port"
}

function Test-SccachePortAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port
    )

    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        try {
            # A failed bind is reusable only when this exact endpoint responds.
            # Native stats can return synthetic success without a cache server.
            return (Test-SccacheHealth -Port $Port).Healthy
        } catch {
            return $false
        }
    } finally {
        if ($listener) { $listener.Stop() }
    }
}

function Test-SccachePortExcluded {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Ranges
    )
    foreach ($r in $Ranges) {
        if ($Port -ge $r.Start -and $Port -le $r.End) { return $true }
    }
    return $false
}
