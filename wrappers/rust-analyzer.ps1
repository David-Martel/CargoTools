#Requires -Version 5.1
# rust-analyzer.ps1 — CargoTools v0.9.0 rust-analyzer entry point
# Delegates to rust-analyzer-wrapper.ps1 after processing wrapper flags.
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$ArgumentList
)
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'rust-analyzer'

if ($ctx.HelpRequested)    { Show-WrapperHelp -WrapperName 'rust-analyzer' -RemainingArgs $ctx.PassThrough; exit 0 }
if ($ctx.VersionRequested) { Show-WrapperVersion -WrapperName 'rust-analyzer'; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'rust-analyzer' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

if ($ctx.NoWrapper -or $env:CARGO_RAW -eq '1') {
    $ra = Get-Command rust-analyzer.exe -ErrorAction SilentlyContinue
    if (-not $ra) { Write-Host '[ERROR] rust-analyzer not found on PATH.' -ForegroundColor Red; exit 3 }
    & $ra.Source @($ctx.PassThrough)
    exit $LASTEXITCODE
}

$inner = Join-Path $PSScriptRoot 'rust-analyzer-wrapper.ps1'
if (-not (Test-Path $inner)) {
    Write-Host "[ERROR] rust-analyzer-wrapper.ps1 not found at $inner" -ForegroundColor Red
    exit 1
}

Write-LlmEvent -Phase start -Wrapper rust-analyzer -Args $ctx.PassThrough -EmitLlm:$ctx.LlmMode
$start = Get-Date

& $inner @($ctx.PassThrough)
$code = $LASTEXITCODE

Write-LlmEvent -Phase end -Wrapper rust-analyzer -ExitCode $code `
    -DurationMs ([int]((Get-Date) - $start).TotalMilliseconds) -EmitLlm:$ctx.LlmMode
exit $code
