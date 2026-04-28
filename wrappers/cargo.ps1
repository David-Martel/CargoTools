[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$ArgumentList
)

$router = Join-Path $PSScriptRoot 'cargo-route.ps1'
if (-not (Test-Path $router)) {
    Write-Error "cargo-route.ps1 not found at $router"
    exit 1
}

& $router @ArgumentList
exit $LASTEXITCODE
