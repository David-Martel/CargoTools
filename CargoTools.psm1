#requires -Version 5.1

Set-StrictMode -Version Latest

$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$privatePath = Join-Path $moduleRoot 'Private'
$publicPath = Join-Path $moduleRoot 'Public'

if (Test-Path $privatePath) {
    Get-ChildItem -Path $privatePath -Filter *.ps1 | Sort-Object Name | ForEach-Object { . $_.FullName }
}

$publicFunctions = @()
if (Test-Path $publicPath) {
    Get-ChildItem -Path $publicPath -Filter *.ps1 | Sort-Object Name | ForEach-Object {
        . $_.FullName
        $publicFunctions += $_.BaseName
    }
}

# Helper functions to export for external use
$helperFunctions = @(
    'Initialize-CargoEnv',
    'Start-SccacheServer',
    'Stop-SccacheServer',
    'Get-SccacheMemoryMB',
    'Get-OptimalBuildJobs',
    # Machine-aware configuration
    'Get-MachineConfig',
    'Get-MachineIdentity',
    'Register-CurrentMachine',
    # Rust-analyzer helpers
    'Resolve-RustAnalyzerPath',
    'Get-RustAnalyzerMemoryMB',
    'Test-RustAnalyzerSingleton',
    # LLM-friendly output helpers
    'Format-CargoOutput',
    'Format-CargoError',
    'ConvertTo-LlmContext',
    'Get-RustProjectContext',
    'Get-CargoContextSnapshot',
    'Get-BuildVersionInfo',
    'Set-BuildVersionEnvironment',
    'Resolve-CargoTargetDirectory',
    'Publish-BuildArtifact'
)

$allExports = $publicFunctions + $helperFunctions
if ($allExports.Count -gt 0) {
    Export-ModuleMember -Function $allExports
}
