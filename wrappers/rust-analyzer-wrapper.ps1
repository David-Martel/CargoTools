#Requires -Version 5.1
# rust-analyzer-wrapper.ps1 - CargoTools v0.9.0 rust-analyzer module shim
# Loads CargoTools module and calls Invoke-RustAnalyzerWrapper.
$ErrorActionPreference = 'Stop'
[string[]]$ArgumentList = @($args)

Import-Module (Join-Path $PSScriptRoot '_WrapperHelpers.psm1') -Force

$ctx = Get-WrapperContext -InvocationArgs $ArgumentList -WrapperName 'rust-analyzer-wrapper'
$passThroughArgs = [string[]]@($ctx.PassThrough)

if ($ctx.HelpRequested)    { Show-WrapperHelp -WrapperName 'rust-analyzer-wrapper' -RemainingArgs $passThroughArgs; exit 0 }
if ($ctx.VersionRequested) { Show-WrapperVersion -WrapperName 'rust-analyzer-wrapper'; exit 0 }
if ($ctx.DoctorRequested)  { exit (Invoke-WrapperDoctor -WrapperName 'rust-analyzer-wrapper' -AsJson:$ctx.DiagnoseRequested) }
if ($ctx.ListRequested)    { Show-WrapperList; exit 0 }

if ($ctx.NoWrapper -or $env:CARGO_RAW -eq '1') {
    $ra = Get-Command rust-analyzer.exe -ErrorAction SilentlyContinue
    if (-not $ra) { Write-Host '[ERROR] rust-analyzer not found on PATH.' -ForegroundColor Red; exit 3 }
    & $ra.Source @passThroughArgs
    exit $LASTEXITCODE
}

if (-not (Import-CargoToolsResilient -EmitLlm:$ctx.LlmMode)) { exit 2 }

Write-LlmEvent -Phase start -Wrapper rust-analyzer-wrapper -Args $passThroughArgs -EmitLlm:$ctx.LlmMode
$start = Get-Date

$code = Invoke-RustAnalyzerWrapper -ArgumentList $passThroughArgs
if ($null -eq $code) { $code = $LASTEXITCODE }

Write-LlmEvent -Phase end -Wrapper rust-analyzer-wrapper -ExitCode $code `
    -DurationMs ([int]((Get-Date) - $start).TotalMilliseconds) -EmitLlm:$ctx.LlmMode
exit $code
