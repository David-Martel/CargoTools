function Test-CargoMachineDependencies {
    <#
    .SYNOPSIS
    Validates machine-level Cargo/Rust build dependencies.
    .DESCRIPTION
    Performs a fast dependency gate for critical local tooling needed by CargoTools
    quality-enforced builds.
    #>
    [CmdletBinding()]
    param(
        [switch]$Quiet,
        [switch]$Detailed
    )

    $checks = @(
        @{ Name = 'rustup'; Command = 'rustup'; Mandatory = $true; Install = 'https://rustup.rs/' },
        @{ Name = 'cargo'; Command = 'cargo'; Mandatory = $true; Install = 'rustup component add rustfmt clippy' },
        @{ Name = 'rustc'; Command = 'rustc'; Mandatory = $true; Install = 'rustup update stable' },
        @{ Name = 'sccache'; Command = 'sccache'; Mandatory = $true; Install = 'cargo install sccache --locked' },
        @{ Name = 'cargo-nextest'; Command = 'cargo-nextest'; Mandatory = $false; Install = 'cargo install cargo-nextest --locked' },
        @{ Name = 'cargo-deny'; Command = 'cargo-deny'; Mandatory = $false; Install = 'cargo install cargo-deny --locked' },
        @{ Name = 'ninja'; Command = 'ninja'; Mandatory = $false; Install = 'choco install ninja' }
    )

    $results = @()
    $missingMandatory = @()
    $missingOptional = @()

    foreach ($check in $checks) {
        $cmdPath = Find-CargoCommandPath -Name $check.Command
        $entry = [pscustomobject]@{
            Name = $check.Name
            Mandatory = [bool]$check.Mandatory
            Status = if ($cmdPath) { 'present' } else { 'missing' }
            Path = $cmdPath
            InstallHint = $check.Install
        }
        $results += $entry

        if (-not $cmdPath) {
            if ($check.Mandatory) {
                $missingMandatory += $check.Name
            } else {
                $missingOptional += $check.Name
            }
        }
    }

    if (Test-IsWindows) {
        $msvcCl = Get-MsvcClExePath
        $msvcEntry = [pscustomobject]@{
            Name = 'msvc-cl'
            Mandatory = $true
            Status = if ($msvcCl) { 'present' } else { 'missing' }
            Path = $msvcCl
            InstallHint = 'Install Visual Studio Build Tools (MSVC x64) and run msvc-env.ps1'
        }
        $results += $msvcEntry
        if (-not $msvcCl) {
            $missingMandatory += 'msvc-cl'
        }
    }

    $passed = ($missingMandatory.Count -eq 0)

    if (-not $Quiet) {
        Write-Host ''
        Write-Host '=== Cargo Machine Dependencies ===' -ForegroundColor Cyan
        foreach ($r in $results) {
            $color = if ($r.Status -eq 'present') { 'Green' } elseif ($r.Mandatory) { 'Red' } else { 'Yellow' }
            $level = if ($r.Mandatory) { 'required' } else { 'optional' }
            Write-Host ("  {0,-16} {1,-8} ({2})" -f $r.Name, $r.Status, $level) -ForegroundColor $color
        }

        if ($missingMandatory.Count -gt 0) {
            Write-Host ''
            Write-Host 'Missing required dependencies:' -ForegroundColor Red
            foreach ($name in $missingMandatory) {
                $hint = ($results | Where-Object { $_.Name -eq $name } | Select-Object -First 1).InstallHint
                Write-Host "  - $name -> $hint" -ForegroundColor Red
            }
        }

        if ($missingOptional.Count -gt 0) {
            Write-Host ''
            Write-Host 'Missing optional dependencies:' -ForegroundColor Yellow
            foreach ($name in $missingOptional) {
                $hint = ($results | Where-Object { $_.Name -eq $name } | Select-Object -First 1).InstallHint
                Write-Host "  - $name -> $hint" -ForegroundColor Yellow
            }
        }
    }

    $summary = [pscustomobject]@{
        Passed = $passed
        MissingMandatory = @($missingMandatory)
        MissingOptional = @($missingOptional)
        Results = @($results)
    }

    return $summary
}
