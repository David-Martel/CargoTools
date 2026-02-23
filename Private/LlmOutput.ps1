#Requires -Version 5.1
<#
.SYNOPSIS
LLM-friendly output formatting helpers for CargoTools.
.DESCRIPTION
Provides consistent, structured output formats optimized for AI assistant consumption.
#>

function Format-CargoOutput {
    <#
    .SYNOPSIS
    Formats cargo tool output for different consumers.
    .PARAMETER Data
    The data object to format.
    .PARAMETER OutputFormat
    Output format: Text (human-readable), Json (machine-parseable), Object (PowerShell object).
    .PARAMETER Tool
    Name of the tool generating output.
    .PARAMETER IncludeContext
    Include additional context for LLM analysis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$Data,

        [Parameter()]
        [ValidateSet('Text', 'Json', 'Object')]
        [string]$OutputFormat = 'Text',

        [Parameter()]
        [string]$Tool = 'cargo',

        [Parameter()]
        [switch]$IncludeContext
    )

    process {
        # Wrap data in standard envelope
        $envelope = [ordered]@{
            tool = $Tool
            version = (Get-Module CargoTools).Version.ToString()
            timestamp = (Get-Date -Format 'o')
            status = if ($Data.Status) { $Data.Status } else { 'unknown' }
            data = $Data
        }

        if ($IncludeContext) {
            $envelope['context'] = Get-CargoContextSnapshot
        }

        switch ($OutputFormat) {
            'Json' {
                return ($envelope | ConvertTo-Json -Depth 10 -Compress:$false)
            }
            'Object' {
                return [PSCustomObject]$envelope
            }
            'Text' {
                # Human-readable format - delegate to caller's formatting
                return $Data
            }
        }
    }
}

function Get-CargoContextSnapshot {
    <#
    .SYNOPSIS
    Captures current cargo/rust environment context for LLM analysis.
    #>
    [CmdletBinding()]
    param()

    $context = [ordered]@{
        working_directory = (Get-Location).Path
        cargo_home = $env:CARGO_HOME
        rustup_home = $env:RUSTUP_HOME
        cargo_target_dir = $env:CARGO_TARGET_DIR
    }

    # Find nearest Cargo.toml
    $manifestPath = Find-CargoManifest
    if ($manifestPath) {
        $context['manifest_path'] = $manifestPath
        $context['workspace_root'] = Split-Path $manifestPath -Parent
    }

    # Rust version
    try {
        $rustVersion = & rustc --version 2>$null
        if ($rustVersion) {
            $context['rust_version'] = $rustVersion.Trim()
        }
    } catch {}

    # Active toolchain
    try {
        $toolchain = & rustup show active-toolchain 2>$null
        if ($toolchain) {
            $context['active_toolchain'] = ($toolchain -split ' ')[0]
        }
    } catch {}

    return $context
}

function Find-CargoManifest {
    <#
    .SYNOPSIS
    Finds the nearest Cargo.toml file.
    #>
    [CmdletBinding()]
    param(
        [string]$StartPath = (Get-Location).Path
    )

    $current = $StartPath
    while ($current -and $current -ne [System.IO.Path]::GetPathRoot($current)) {
        $manifest = Join-Path $current 'Cargo.toml'
        if (Test-Path $manifest) {
            return $manifest
        }
        $current = Split-Path $current -Parent
    }
    return $null
}

function Format-CargoError {
    <#
    .SYNOPSIS
    Formats cargo errors with rich context for LLM debugging.
    .PARAMETER ErrorOutput
    Raw error output from cargo command.
    .PARAMETER Command
    The cargo command that was executed.
    .PARAMETER Arguments
    Arguments passed to the command.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ErrorOutput,

        [Parameter()]
        [string]$Command = 'cargo',

        [Parameter()]
        [string[]]$Arguments = @()
    )

    $result = [ordered]@{
        error_type = 'unknown'
        error_code = $null
        message = $ErrorOutput
        location = $null
        suggested_fixes = @()
        related_docs = @()
    }

    # Parse Rust error codes (E0XXX)
    if ($ErrorOutput -match 'error\[E(\d{4})\]') {
        $result['error_code'] = "E$($Matches[1])"
        $result['error_type'] = 'compilation'

        # Get explanation
        try {
            $explain = & rustc --explain "E$($Matches[1])" 2>$null
            if ($explain) {
                $result['explanation'] = ($explain | Select-Object -First 10) -join "`n"
            }
        } catch {}

        $result['related_docs'] += "https://doc.rust-lang.org/error_codes/E$($Matches[1]).html"
    }

    # Parse location (file:line:col)
    if ($ErrorOutput -match '(?<file>[^:\s]+\.rs):(?<line>\d+):(?<col>\d+)') {
        $result['location'] = [ordered]@{
            file = $Matches['file']
            line = [int]$Matches['line']
            column = [int]$Matches['col']
        }

        # Try to get source context
        $fullPath = $Matches['file']
        if (Test-Path $fullPath) {
            $result['location']['context'] = Get-SourceContext -Path $fullPath -Line ([int]$Matches['line'])
        }
    }

    # Detect common error patterns and suggest fixes
    $patterns = @{
        'borrow of moved value' = @{
            fix = 'Clone the value before moving, or use a reference'
            docs = 'https://doc.rust-lang.org/book/ch04-01-what-is-ownership.html'
        }
        'cannot borrow .* as mutable' = @{
            fix = 'Ensure only one mutable reference exists at a time'
            docs = 'https://doc.rust-lang.org/book/ch04-02-references-and-borrowing.html'
        }
        'lifetime .* required' = @{
            fix = 'Add explicit lifetime annotations to clarify scope'
            docs = 'https://doc.rust-lang.org/book/ch10-03-lifetime-syntax.html'
        }
        'unresolved import' = @{
            fix = 'Add the dependency to Cargo.toml or fix the module path'
            docs = 'https://doc.rust-lang.org/book/ch07-02-defining-modules-to-control-scope-and-privacy.html'
        }
        'mismatched types' = @{
            fix = 'Convert types explicitly or fix the function signature'
            docs = 'https://doc.rust-lang.org/book/ch03-02-data-types.html'
        }
    }

    foreach ($pattern in $patterns.Keys) {
        if ($ErrorOutput -match $pattern) {
            $result['suggested_fixes'] += $patterns[$pattern]['fix']
            $result['related_docs'] += $patterns[$pattern]['docs']
        }
    }

    return [PSCustomObject]$result
}

function Get-SourceContext {
    <#
    .SYNOPSIS
    Gets source code context around a specific line.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [int]$Line,

        [Parameter()]
        [int]$Before = 3,

        [Parameter()]
        [int]$After = 3
    )

    if (-not (Test-Path $Path)) {
        return $null
    }

    $lines = Get-Content $Path -TotalCount ($Line + $After)
    $startLine = [Math]::Max(1, $Line - $Before)

    $context = @()
    for ($i = $startLine; $i -le [Math]::Min($lines.Count, $Line + $After); $i++) {
        $prefix = if ($i -eq $Line) { '>>> ' } else { '    ' }
        $context += "$prefix$($i.ToString().PadLeft(4)): $($lines[$i - 1])"
    }

    return $context -join "`n"
}

function ConvertTo-LlmContext {
    <#
    .SYNOPSIS
    Converts cargo tool output to optimized LLM context.
    .DESCRIPTION
    Extracts key information and formats it for efficient LLM consumption,
    minimizing tokens while preserving essential context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$ToolOutput,

        [Parameter()]
        [int]$MaxTokens = 2000
    )

    process {
        $context = [ordered]@{
            summary = ''
            key_findings = @()
            action_items = @()
            raw_excerpt = ''
        }

        # Extract based on output type
        if ($ToolOutput.PSObject.Properties['Status']) {
            $context['summary'] = "Tool returned status: $($ToolOutput.Status)"
        }

        if ($ToolOutput.PSObject.Properties['Issues']) {
            $context['key_findings'] = $ToolOutput.Issues
        }

        if ($ToolOutput.PSObject.Properties['Recommendations']) {
            $context['action_items'] = $ToolOutput.Recommendations
        }

        # Truncate if needed
        $json = $context | ConvertTo-Json -Depth 5
        if ($json.Length -gt $MaxTokens * 4) {  # Rough token estimate
            $context['truncated'] = $true
            $context['raw_excerpt'] = $json.Substring(0, $MaxTokens * 4)
        }

        return [PSCustomObject]$context
    }
}

function Get-RustProjectContext {
    <#
    .SYNOPSIS
    Extracts comprehensive project context for LLM analysis.
    .DESCRIPTION
    Gathers project structure, dependencies, build state, and recommendations
    in a format optimized for AI-assisted development.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Path = '.',

        [Parameter()]
        [switch]$IncludeDependencies,

        [Parameter()]
        [switch]$IncludeLastErrors
    )

    $manifest = Find-CargoManifest -StartPath $Path
    if (-not $manifest) {
        return [PSCustomObject]@{
            error = 'No Cargo.toml found'
            searched_path = $Path
        }
    }

    $projectRoot = Split-Path $manifest -Parent
    $result = [ordered]@{
        project_root = $projectRoot
        manifest_path = $manifest
    }

    # Parse Cargo.toml basics
    $tomlContent = Get-Content $manifest -Raw
    if ($tomlContent -match '\[package\][\s\S]*?name\s*=\s*"([^"]+)"') {
        $result['package_name'] = $Matches[1]
    }
    if ($tomlContent -match 'version\s*=\s*"([^"]+)"') {
        $result['version'] = $Matches[1]
    }

    # Check for workspace
    $result['is_workspace'] = $tomlContent -match '\[workspace\]'

    # Get dependency count
    $depMatches = [regex]::Matches($tomlContent, '\[(?:dependencies|dev-dependencies|build-dependencies)\]')
    $result['dependency_sections'] = $depMatches.Count

    if ($IncludeDependencies) {
        try {
            $tree = & cargo tree --depth 1 --manifest-path $manifest 2>$null
            if ($tree) {
                $result['direct_dependencies'] = ($tree | Select-Object -Skip 1 | Measure-Object).Count
            }
        } catch {}
    }

    # Rust-analyzer status
    $raHealth = Test-RustAnalyzerSingleton -WarnThresholdMB 1500
    $result['rust_analyzer'] = [ordered]@{
        status = $raHealth.Status
        memory_mb = $raHealth.MemoryMB
        issues = $raHealth.Issues
    }

    return [PSCustomObject]$result
}
