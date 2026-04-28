[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true, Position = 0)]
    [string[]]$ArgumentList
)

$wrapper = Join-Path $PSScriptRoot 'rust-analyzer-wrapper.ps1'
if (-not (Test-Path $wrapper)) {
    Write-Error "rust-analyzer-wrapper.ps1 not found at $wrapper"
    exit 1
}

& $wrapper @ArgumentList
exit $LASTEXITCODE
