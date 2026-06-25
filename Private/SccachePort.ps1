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
    trusts the caller's value unchanged.

.PARAMETER DesiredPort
    The configured/default sccache server port (string, e.g. from $env:SCCACHE_SERVER_PORT).

.OUTPUTS
    [string] a port guaranteed (best-effort) not to be in a Windows excluded range.
#>
function Resolve-FreeSccachePort {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$DesiredPort
    )

    $port = 0
    if (-not [int]::TryParse($DesiredPort, [ref]$port) -or $port -le 0) { $port = 4400 }

    # Parse the live Windows TCP exclusion table. Any failure (non-Windows, restricted shell) is
    # non-fatal: trust the caller's port rather than block the build.
    $ranges = @()
    try {
        $rows = & netsh int ipv4 show excludedportrange protocol=tcp 2>$null
        foreach ($line in $rows) {
            if ($line -match '^\s*(\d+)\s+(\d+)\s*$') {
                $ranges += [pscustomobject]@{ Start = [int]$Matches[1]; End = [int]$Matches[2] }
            }
        }
    } catch {
        return "$port"
    }
    if ($ranges.Count -eq 0) { return "$port" }

    if (
        -not (Test-SccachePortExcluded -Port $port -Ranges $ranges) -and
        (Test-SccachePortAvailable -Port $port)
    ) {
        return "$port"
    }

    foreach ($candidate in 4200..4599) {
        if (
            -not (Test-SccachePortExcluded -Port $candidate -Ranges $ranges) -and
            (Test-SccachePortAvailable -Port $candidate)
        ) {
            Write-Warning ("CargoTools: sccache port {0} is unavailable or in a Windows excluded port range; using free port {1} instead." -f $port, $candidate)
            return "$candidate"
        }
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
        [Parameter(Mandatory)][int]$Port
    )

    $listener = $null
    try {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    } catch {
        $oldPort = $env:SCCACHE_SERVER_PORT
        try {
            $env:SCCACHE_SERVER_PORT = "$Port"
            $sccache = Get-Command sccache -ErrorAction SilentlyContinue
            if (-not $sccache) { return $false }
            & $sccache.Source --show-stats *> $null
            return $LASTEXITCODE -eq 0
        } catch {
            return $false
        } finally {
            if ($null -eq $oldPort) {
                Remove-Item Env:SCCACHE_SERVER_PORT -ErrorAction SilentlyContinue
            } else {
                $env:SCCACHE_SERVER_PORT = $oldPort
            }
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
