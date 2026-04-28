#Requires -Version 5.1
# cargo.ps1 — CargoTools v0.9.0 top-level cargo entry point
# Delegates to cargo-route.ps1 after processing wrapper flags.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$ArgumentList
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'cargo'

if ($ctx.HelpRequested)    { Show-WrapperHelp -WrapperName 'cargo' -RemainingArgs $ctx.PassThrough; exit 0 }
if ($ctx.VersionRequested) { Show-WrapperVersion -WrapperName 'cargo'; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'cargo' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

if ($ctx.NoWrapper -or $env:CARGO_RAW -eq '1') {
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if (-not $rustup) { Write-Host '[ERROR] rustup not found.' -ForegroundColor Red; exit 3 }
    & rustup run stable cargo @($ctx.PassThrough)
    exit $LASTEXITCODE
}

$router = Join-Path $PSScriptRoot 'cargo-route.ps1'
if (-not (Test-Path $router)) {
    Write-Host "[ERROR] cargo-route.ps1 not found at $router" -ForegroundColor Red
    exit 1
}

Write-LlmEvent -Phase start -Wrapper cargo -Args $ctx.PassThrough -EmitLlm:$ctx.LlmMode
$start  = Get-Date

& $router @($ctx.PassThrough)
$code = $LASTEXITCODE

Write-LlmEvent -Phase end -Wrapper cargo -ExitCode $code `
    -DurationMs ([int]((Get-Date) - $start).TotalMilliseconds) -EmitLlm:$ctx.LlmMode
exit $code
