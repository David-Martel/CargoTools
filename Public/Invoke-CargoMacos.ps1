function Invoke-CargoMacos {
<#
.SYNOPSIS
macOS cross-compile helper via cargo-zigbuild Docker image.
.PARAMETER ArgumentList
Raw cargo-macos arguments.
#>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
        [string[]]$ArgumentList
    )

    $rawArgs = if ($ArgumentList) { @($ArgumentList) } else { @() }
    if ($rawArgs -isnot [System.Array]) { $rawArgs = @($rawArgs) }
    $Target = ''
    $Arm64 = $false
    $X64 = $false
    $Sccache = $false
    $NoSccache = $false
    $BootstrapSccache = $false
    $NoConfig = $false
    $NoTty = $false
    $Image = ''

    function Show-Help {
        Write-Host 'cargo-macos - macOS cross-compile helper (cargo-zigbuild)' -ForegroundColor Cyan
        Write-Host ''
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  cargo-macos [--target <triple>] <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-macos --arm64 <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-macos --x64 <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-macos --bootstrap-sccache <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-macos --no-tty <cargo-args>' -ForegroundColor Gray
        Write-Host '  cargo-macos --no-config <cargo-args>' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Defaults:' -ForegroundColor Yellow
        Write-Host '  - Uses cargo-docker --zigbuild' -ForegroundColor Gray
        Write-Host '  - Default target: aarch64-apple-darwin' -ForegroundColor Gray
        Write-Host ''
        Write-Host 'Wrappers:' -ForegroundColor Yellow
        Write-Host '  cargo-macos.ps1 (direct)' -ForegroundColor Gray
        Write-Host '  cargo --route-macos docker [args...]' -ForegroundColor Gray
        Write-Host ''
    }

    foreach ($arg in $rawArgs) {
        if ($arg -eq '--help' -or $arg -eq '-h') { Show-Help; return 0 }
    }

    $remaining = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $rawArgs.Count; $i++) {
        $arg = $rawArgs[$i]
        switch ($arg) {
            '--target' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --target'; return 1 }
                $Target = $rawArgs[$i]
                continue
            }
            '--arm64' { $Arm64 = $true; continue }
            '--x64' { $X64 = $true; continue }
            '--sccache' { $Sccache = $true; continue }
            '--no-sccache' { $NoSccache = $true; continue }
            '--bootstrap-sccache' { $BootstrapSccache = $true; $Sccache = $true; continue }
            '--no-config' { $NoConfig = $true; continue }
            '--no-tty' { $NoTty = $true; continue }
            '--image' {
                $i++
                if ($i -ge $rawArgs.Count) { Write-Error 'Missing value for --image'; return 1 }
                $Image = $rawArgs[$i]
                continue
            }
            default { $remaining.Add($arg); continue }
        }
    }

    if (-not (Assert-NotBoth -Name 'macos arch' -A $Arm64 -B $X64)) { return 1 }
    if (-not (Assert-NotBoth -Name 'macos sccache mode' -A $Sccache -B $NoSccache)) { return 1 }

    if (-not $Target) {
        if ($Arm64) { $Target = 'aarch64-apple-darwin' }
        elseif ($X64) { $Target = 'x86_64-apple-darwin' }
        else { $Target = 'aarch64-apple-darwin' }
    }

    if ($remaining.Count -gt 0) {
        for ($i = $remaining.Count - 1; $i -ge 0; $i--) {
            if ($remaining[$i] -eq 'build' -or $remaining[$i] -eq 'b') {
                $remaining.RemoveAt($i)
            }
        }
    }

    $dockerArgs = New-Object System.Collections.Generic.List[string]
    $dockerArgs.Add('--zigbuild')
    if ($Image) {
        $dockerArgs.Add('--image')
        $dockerArgs.Add($Image)
    }
    if ($NoConfig) { $dockerArgs.Add('--no-config') }
    if ($NoTty) { $dockerArgs.Add('--no-tty') }
    if ($BootstrapSccache) { $dockerArgs.Add('--bootstrap-sccache') }
    if ($NoSccache) { $dockerArgs.Add('--no-sccache') }
    elseif ($Sccache -or ($env:CARGO_DOCKER_SCCACHE -and $env:CARGO_DOCKER_SCCACHE -ne '0')) { $dockerArgs.Add('--sccache') }

    $dockerArgs.Add('--target')
    $dockerArgs.Add($Target)
    $dockerArgs.AddRange($remaining)

    return (Invoke-CargoDocker -ArgumentList $dockerArgs.ToArray())
}
