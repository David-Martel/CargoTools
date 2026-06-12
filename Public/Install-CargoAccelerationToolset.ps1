function Install-CargoAccelerationToolset {
<#
.SYNOPSIS
Installs CargoTools' curated Rust acceleration and diagnostics toolset.
.DESCRIPTION
Installs missing tools from the CargoTools catalog using cargo-binstall, winget,
rustup, or cargo install as appropriate. Existing commands are skipped unless
-Force is supplied.
#>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [ValidateSet('Core', 'Deep', 'All')]
        [string]$Profile = 'Deep',

        [switch]$Force,

        [switch]$PassThru
    )

    $tools = @(Get-CargoAccelerationToolCatalog -Profile $Profile)
    $results = New-Object System.Collections.Generic.List[object]
    $env:BINSTALL_DISABLE_TELEMETRY = '1'

    $cargoBinstall = Find-CargoCommandPath -Name 'cargo-binstall'
    $cargo = Find-CargoCommandPath -Name 'cargo'
    $rustup = Find-CargoCommandPath -Name 'rustup'
    $winget = Find-CargoCommandPath -Name 'winget'

    foreach ($tool in $tools) {
        $existingPath = Find-CargoCommandPath -Name $tool.Command -BypassCache
        if ($existingPath -and -not $Force) {
            $results.Add([pscustomobject]@{
                Name = $tool.Name
                Command = $tool.Command
                Manager = $tool.Manager
                Status = 'present'
                Path = $existingPath
                ExitCode = 0
            })
            continue
        }

        $status = 'skipped'
        $exitCode = $null
        $path = $existingPath

        if ($PSCmdlet.ShouldProcess($tool.Name, "Install via $($tool.Manager)")) {
            switch ($tool.Manager) {
                'Binstall' {
                    if (-not $cargoBinstall) {
                        $status = 'missing cargo-binstall'
                        $exitCode = 127
                        break
                    }
                    & $cargoBinstall --no-confirm --locked $tool.Package
                    $exitCode = $LASTEXITCODE
                    $status = if ($exitCode -eq 0) { 'installed' } else { 'failed' }
                }
                'CargoInstall' {
                    if (-not $cargo) {
                        $status = 'missing cargo'
                        $exitCode = 127
                        break
                    }
                    & $cargo install $tool.Package --locked
                    $exitCode = $LASTEXITCODE
                    $status = if ($exitCode -eq 0) { 'installed' } else { 'failed' }
                }
                'Winget' {
                    if (-not $winget) {
                        $status = 'missing winget'
                        $exitCode = 127
                        break
                    }
                    & $winget install --id $tool.Package --exact --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity
                    $exitCode = $LASTEXITCODE
                    $status = if ($exitCode -eq 0) { 'installed' } else { 'failed' }
                }
                'RustupComponent' {
                    if (-not $rustup) {
                        $status = 'missing rustup'
                        $exitCode = 127
                        break
                    }
                    & $rustup component add $tool.Package
                    $exitCode = $LASTEXITCODE
                    $status = if ($exitCode -eq 0) { 'installed' } else { 'failed' }
                }
            }

            $path = Find-CargoCommandPath -Name $tool.Command -BypassCache
        }

        $results.Add([pscustomobject]@{
            Name = $tool.Name
            Command = $tool.Command
            Manager = $tool.Manager
            Status = $status
            Path = $path
            ExitCode = $exitCode
        })
    }

    if ($PassThru) {
        return $results
    }

    $failed = @($results | Where-Object { $_.Status -eq 'failed' -or $_.Status -like 'missing *' })
    if ($failed.Count -gt 0) {
        Write-Warning "Cargo acceleration toolset completed with $($failed.Count) failed or skipped installer prerequisites."
    }
}
