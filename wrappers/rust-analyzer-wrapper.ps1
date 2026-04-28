[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$ArgumentList
)

$moduleName = 'CargoTools'
$moduleCandidates = @(
    $env:CARGOTOOLS_MANIFEST,
    (Join-Path $env:USERPROFILE 'Documents\PowerShell\Modules\CargoTools\CargoTools.psd1'),
    (Join-Path (Split-Path -Parent $PSScriptRoot) 'CargoTools.psd1'),
    (Join-Path $env:LOCALAPPDATA 'PowerShell\Modules\CargoTools\CargoTools.psd1'),
    (Join-Path $env:USERPROFILE 'OneDrive\Documents\PowerShell\Modules\CargoTools\CargoTools.psd1')
) | Where-Object { $_ } | Select-Object -Unique

$moduleImported = $false
foreach ($modulePath in $moduleCandidates) {
    if (-not (Test-Path $modulePath)) { continue }
    Import-Module $modulePath -ErrorAction Stop
    $moduleImported = $true
    break
}

if (-not $moduleImported) {
    try {
        Import-Module $moduleName -ErrorAction Stop
        $moduleImported = $true
    } catch {
    }
}

if (-not $moduleImported) {
    Write-Error "CargoTools module not found. Tried: $($moduleCandidates -join ', ')"
    exit 1
}

$code = Invoke-RustAnalyzerWrapper -ArgumentList $ArgumentList
if ($null -eq $code) { $code = $LASTEXITCODE }
exit $code
