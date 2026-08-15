#Requires -Version 5.1
# cargo-route.ps1 - CargoTools v0.9.0 routing shim
# Loads CargoTools module and calls Invoke-CargoRoute.
$ErrorActionPreference = 'Stop'
[string[]]$ArgumentList = @($args)

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'cargo-route'
$passThroughArgs = [string[]]@($ctx.PassThrough)

if ($ctx.HelpRequested)    { Show-WrapperHelp -WrapperName 'cargo-route' -RemainingArgs $passThroughArgs; exit 0 }
if ($ctx.VersionRequested) { Show-WrapperVersion -WrapperName 'cargo-route'; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'cargo-route' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

if ($ctx.NoWrapper -or $env:CARGO_RAW -eq '1') {
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if (-not $rustup) { Write-Host '[ERROR] rustup not found.' -ForegroundColor Red; exit 3 }
    & rustup run stable cargo @passThroughArgs
    exit $LASTEXITCODE
}

if (-not (Import-CargoToolsResilient -EmitLlm:$ctx.LlmMode)) { exit 2 }

Write-LlmEvent -Phase start -Wrapper cargo-route -Args $passThroughArgs -EmitLlm:$ctx.LlmMode
$start = Get-Date

$invocationOutput = @(Invoke-CargoRoute -ArgumentList $passThroughArgs)
$resolvedResult = Split-WrapperInvocationResult -Result $invocationOutput -FallbackExitCode $LASTEXITCODE
@($resolvedResult.Output) | Write-Output
$code = $resolvedResult.ExitCode

Write-LlmEvent -Phase end -Wrapper cargo-route -ExitCode $code `
    -DurationMs ([int]((Get-Date) - $start).TotalMilliseconds) -EmitLlm:$ctx.LlmMode
exit $code
