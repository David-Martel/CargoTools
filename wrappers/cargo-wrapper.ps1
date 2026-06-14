#Requires -Version 5.1
# cargo-wrapper.ps1 - CargoTools v0.9.0 Windows/MSVC build shim
# Loads CargoTools module and calls Invoke-CargoWrapper.
$ErrorActionPreference = 'Stop'
[string[]]$ArgumentList = @($args)

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'cargo-wrapper'
$passThroughArgs = [string[]]@($ctx.PassThrough)

if ($ctx.HelpRequested)    { Show-WrapperHelp -WrapperName 'cargo-wrapper' -RemainingArgs $passThroughArgs; exit 0 }
if ($ctx.VersionRequested) { Show-WrapperVersion -WrapperName 'cargo-wrapper'; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'cargo-wrapper' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

if ($ctx.NoWrapper -or $env:CARGO_RAW -eq '1') {
    $rustup = Get-Command rustup -ErrorAction SilentlyContinue
    if (-not $rustup) { Write-Host '[ERROR] rustup not found.' -ForegroundColor Red; exit 3 }
    & rustup run stable cargo @passThroughArgs
    exit $LASTEXITCODE
}

if (-not (Import-CargoToolsResilient -EmitLlm:$ctx.LlmMode)) { exit 2 }

Write-LlmEvent -Phase start -Wrapper cargo-wrapper -Args $passThroughArgs -EmitLlm:$ctx.LlmMode
$start = Get-Date

$code = Invoke-CargoWrapper -ArgumentList $passThroughArgs
if ($null -eq $code) { $code = $LASTEXITCODE }

Write-LlmEvent -Phase end -Wrapper cargo-wrapper -ExitCode $code `
    -DurationMs ([int]((Get-Date) - $start).TotalMilliseconds) -EmitLlm:$ctx.LlmMode
exit $code
