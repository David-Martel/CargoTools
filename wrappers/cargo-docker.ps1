#Requires -Version 5.1
# cargo-docker.ps1 — CargoTools v0.9.0 Docker build shim
# Loads CargoTools module and calls Invoke-CargoDocker.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$ArgumentList
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'cargo-docker'

if ($ctx.HelpRequested)    { Show-WrapperHelp -WrapperName 'cargo-docker' -RemainingArgs $ctx.PassThrough; exit 0 }
if ($ctx.VersionRequested) { Show-WrapperVersion -WrapperName 'cargo-docker'; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'cargo-docker' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

if ($ctx.NoWrapper -or $env:CARGO_RAW -eq '1') {
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if (-not $rustup) { Write-Host '[ERROR] rustup not found.' -ForegroundColor Red; exit 3 }
    & rustup run stable cargo @($ctx.PassThrough)
    exit $LASTEXITCODE
}

if (-not (Import-CargoToolsResilient -EmitLlm:$ctx.LlmMode)) { exit 2 }

Write-LlmEvent -Phase start -Wrapper cargo-docker -Args $ctx.PassThrough -EmitLlm:$ctx.LlmMode
$start = Get-Date

$code = Invoke-CargoDocker -ArgumentList $ctx.PassThrough
if ($null -eq $code) { $code = $LASTEXITCODE }

Write-LlmEvent -Phase end -Wrapper cargo-docker -ExitCode $code `
    -DurationMs ([int]((Get-Date) - $start).TotalMilliseconds) -EmitLlm:$ctx.LlmMode
exit $code
