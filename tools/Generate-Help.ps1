[CmdletBinding()]
param(
    [string]$ModuleRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name platyPS)) {
    throw 'platyPS is not installed. Run: Install-Module platyPS -Scope CurrentUser'
}

Import-Module platyPS -ErrorAction Stop | Out-Null
Import-Module (Join-Path $ModuleRoot 'CargoTools.psd1') -Force -ErrorAction Stop | Out-Null

$docsPath = Join-Path $ModuleRoot 'docs'
$helpPath = Join-Path $ModuleRoot 'en-US'

New-Item -ItemType Directory -Path $docsPath -Force | Out-Null
New-Item -ItemType Directory -Path $helpPath -Force | Out-Null

New-MarkdownHelp -Module CargoTools -OutputFolder $docsPath -Force | Out-Null
New-ExternalHelp -Path $docsPath -OutputPath $helpPath -Force | Out-Null

Write-Host "Generated help: $docsPath -> $helpPath" -ForegroundColor Cyan
