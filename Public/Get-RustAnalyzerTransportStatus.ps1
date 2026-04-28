function Get-RustAnalyzerTransportStatus {
<#
.SYNOPSIS
Reports the effective rust-analyzer transport state.
.DESCRIPTION
Surfaces whether CargoTools will use direct rust-analyzer execution or lspmux
for a given argument shape, along with shim and server status. This is intended
for editor integration checks and agent diagnostics.
.PARAMETER ArgumentList
Optional rust-analyzer arguments to evaluate.
.EXAMPLE
Get-RustAnalyzerTransportStatus
.EXAMPLE
Get-RustAnalyzerTransportStatus -ArgumentList @('diagnostics', '.')
#>
    [CmdletBinding()]
    param(
        [string[]]$ArgumentList
    )

    function Invoke-LspmuxStatusProbe {
        param(
            [string]$LspmuxPath,
            [int]$TimeoutMs = 750
        )

        if ([string]::IsNullOrWhiteSpace($LspmuxPath) -or -not (Test-Path -LiteralPath $LspmuxPath)) {
            return $null
        }

        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $LspmuxPath
        $startInfo.Arguments = 'status --json'
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true

        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = $startInfo

        try {
            if (-not $process.Start()) {
                return [pscustomobject]@{
                    TimedOut = $false
                    ExitCode = $null
                    StdOut = $null
                    StdErr = 'failed to start lspmux status probe'
                }
            }

            if (-not $process.WaitForExit($TimeoutMs)) {
                try { $process.Kill($true) } catch {}
                return [pscustomobject]@{
                    TimedOut = $true
                    ExitCode = $null
                    StdOut = $null
                    StdErr = "lspmux status timed out after ${TimeoutMs}ms"
                }
            }

            return [pscustomobject]@{
                TimedOut = $false
                ExitCode = $process.ExitCode
                StdOut = $process.StandardOutput.ReadToEnd().Trim()
                StdErr = $process.StandardError.ReadToEnd().Trim()
            }
        }
        finally {
            $process.Dispose()
        }
    }

    $argsList = if ($ArgumentList) { @($ArgumentList) } else { @() }
    $transport = Resolve-RustAnalyzerTransportMode -ArgumentList $argsList
    $raPath = Resolve-RustAnalyzerPath
    $shimPath = Join-Path $HOME '.local\bin\rust-analyzer.cmd'
    $configCandidates = @(
        (Join-Path $env:APPDATA 'lspmux\config\config.toml'),
        (Join-Path $env:USERPROFILE '.config\lspmux\config.toml'),
        (Join-Path $env:APPDATA 'lspmux\config.toml'),
        (Join-Path $env:LOCALAPPDATA 'lspmux\config.toml'),
        (Join-Path $env:USERPROFILE '.lspmux.toml')
    )
    $configPath = $configCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $lspmuxProcesses = @(Get-Process -Name 'lspmux*' -ErrorAction SilentlyContinue)
    $instanceCount = $lspmuxProcesses.Count
    $statusProbe = Invoke-LspmuxStatusProbe -LspmuxPath $transport.LspmuxPath

    [pscustomobject]@{
        Preference = $transport.Preference
        Effective = $transport.Effective
        Reason = $transport.Reason
        RustAnalyzerPath = $raPath
        LspmuxPath = $transport.LspmuxPath
        LspmuxConfigPath = $configPath
        LspmuxAvailable = -not [string]::IsNullOrWhiteSpace($transport.LspmuxPath)
        LspmuxInstanceCount = $instanceCount
        LspmuxStatus = if ($statusProbe) { $statusProbe.StdOut } else { $null }
        LspmuxStatusError = if ($statusProbe) { $statusProbe.StdErr } else { $null }
        LspmuxStatusTimedOut = if ($statusProbe) { [bool]$statusProbe.TimedOut } else { $false }
        StandaloneInvocation = [bool]$transport.DirectInvocation
        ClientShimPath = $shimPath
        ClientShimExists = Test-Path -LiteralPath $shimPath
    }
}
