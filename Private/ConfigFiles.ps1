#Requires -Version 5.1
<#
.SYNOPSIS
TOML config file read/write/merge primitives for CargoTools.
.DESCRIPTION
Provides minimal TOML parsing and generation for cargo config, rustfmt, clippy,
and rust-analyzer configuration files. Supports flat sections (no arrays-of-tables
or inline tables) which covers the cargo config subset.
#>

function Read-TomlSections {
    <#
    .SYNOPSIS
    Parses a TOML file into an ordered hashtable of sections.
    .PARAMETER Path
    Path to the TOML file.
    .DESCRIPTION
    Returns an ordered hashtable where keys are section names (e.g., 'build',
    'registries.crates-io') and values are ordered hashtables of key-value pairs.
    Top-level keys (before any section header) go under the '' (empty string) key.
    Comments are preserved as-is in a '_comments' key per section.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        return [ordered]@{}
    }

    $lines = Get-Content -Path $Path -ErrorAction Stop
    $result = [ordered]@{}
    $currentSection = ''
    $result[$currentSection] = [ordered]@{}

    $inArray = $false
    $arrayKey = ''
    $arrayBuf = ''

    foreach ($line in $lines) {
        $trimmed = $line.Trim()

        # Accumulate multi-line arrays
        if ($inArray) {
            $arrayBuf += " $trimmed"
            if ($trimmed.Contains(']')) {
                $inArray = $false
                if (-not $result.Contains($currentSection)) {
                    $result[$currentSection] = [ordered]@{}
                }
                # Store the raw array literal as-is (Format-TomlValue will pass it through)
                $result[$currentSection][$arrayKey] = $arrayBuf.Trim()
            }
            continue
        }

        # Skip empty lines and comments
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        # Section header: [section] or [section.subsection]
        if ($trimmed -match '^\[([^\]]+)\]\s*$') {
            $currentSection = $Matches[1].Trim()
            if (-not $result.Contains($currentSection)) {
                $result[$currentSection] = [ordered]@{}
            }
            continue
        }

        # Key-value pair: key = value
        $eqIndex = $trimmed.IndexOf('=')
        if ($eqIndex -gt 0) {
            $key = $trimmed.Substring(0, $eqIndex).Trim()
            $rawValue = $trimmed.Substring($eqIndex + 1).Trim()

            # Detect multi-line array start
            if ($rawValue.StartsWith('[') -and -not $rawValue.Contains(']')) {
                $inArray = $true
                $arrayKey = $key
                $arrayBuf = $rawValue
                continue
            }

            # Strip inline comments (only if not inside a quoted string)
            $value = ConvertFrom-TomlValue $rawValue

            if (-not $result.Contains($currentSection)) {
                $result[$currentSection] = [ordered]@{}
            }
            $result[$currentSection][$key] = $value
        }
    }

    # Remove empty root section if no top-level keys
    if ($result.Contains('') -and $result[''].Count -eq 0) {
        $result.Remove('')
    }

    return $result
}

function ConvertFrom-TomlValue {
    <#
    .SYNOPSIS
    Converts a raw TOML value string to a PowerShell value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawValue
    )

    $v = $RawValue.Trim()

    # Strip trailing inline comment (not inside quotes)
    if ($v -match '^".*"' -or $v -match "^'.*'") {
        # Quoted string - don't strip comments
    } else {
        $commentIdx = $v.IndexOf('#')
        if ($commentIdx -gt 0) {
            $v = $v.Substring(0, $commentIdx).Trim()
        }
    }

    # Quoted string (double quotes) - unescape standard TOML escapes
    if ($v.StartsWith('"') -and $v.EndsWith('"') -and $v.Length -ge 2) {
        $inner = $v.Substring(1, $v.Length - 2)
        $inner = $inner.Replace('\\', '\').Replace('\"', '"')
        return $inner
    }

    # Quoted string (single quotes / literal)
    if ($v.StartsWith("'") -and $v.EndsWith("'") -and $v.Length -ge 2) {
        return $v.Substring(1, $v.Length - 2)
    }

    # Boolean
    if ($v -eq 'true') { return $true }
    if ($v -eq 'false') { return $false }

    # Integer
    if ($v -match '^\d+$') { return [int]$v }

    # Return as-is (unquoted string)
    return $v
}

function ConvertTo-TomlString {
    <#
    .SYNOPSIS
    Serializes an ordered hashtable to a TOML string.
    .PARAMETER Data
    Ordered hashtable where keys are section names and values are ordered hashtables of key-value pairs.
    .PARAMETER Header
    Optional comment header to prepend to the output.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Data,

        [Parameter()]
        [string]$Header
    )

    $sb = New-Object System.Text.StringBuilder

    if ($Header) {
        foreach ($headerLine in ($Header -split "`n")) {
            [void]$sb.AppendLine("# $($headerLine.TrimEnd())")
        }
        [void]$sb.AppendLine()
    }

    $first = $true
    foreach ($section in $Data.Keys) {
        $entries = $Data[$section]
        if ($null -eq $entries -or $entries.Count -eq 0) { continue }

        # Top-level keys (empty section name)
        if ([string]::IsNullOrEmpty($section)) {
            foreach ($key in $entries.Keys) {
                $formatted = Format-TomlValue $entries[$key]
                [void]$sb.AppendLine("$key = $formatted")
            }
            [void]$sb.AppendLine()
            $first = $false
            continue
        }

        if (-not $first) { [void]$sb.AppendLine() }
        [void]$sb.AppendLine("[$section]")
        foreach ($key in $entries.Keys) {
            $formatted = Format-TomlValue $entries[$key]
            [void]$sb.AppendLine("$key = $formatted")
        }
        $first = $false
    }

    return $sb.ToString().TrimEnd("`r", "`n") + "`n"
}

function Format-TomlValue {
    <#
    .SYNOPSIS
    Formats a PowerShell value as a TOML value string.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Value
    )

    if ($Value -is [bool]) {
        if ($Value) { return 'true' } else { return 'false' }
    }

    if ($Value -is [int] -or $Value -is [long]) {
        return $Value.ToString()
    }

    # String - check for raw TOML arrays/inline tables first
    $str = [string]$Value
    if ($str.TrimStart().StartsWith('[') -or $str.TrimStart().StartsWith('{')) {
        return $str
    }

    # Quote with double quotes, escape backslashes in paths
    $escaped = $str.Replace('\', '\\').Replace('"', '\"')
    return "`"$escaped`""
}

function New-CargoEnvInlineTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value,

        [switch]$NoForce
    )

    $forceLiteral = if ($NoForce) { 'false' } else { 'true' }
    return "{ value = $(Format-TomlValue $Value), force = $forceLiteral }"
}

function Get-ManagedCargoEnvDefaults {
    [CmdletBinding()]
    param()

    $cacheRoot = Resolve-CacheRoot
    $sccacheDir = if ($cacheRoot) { Join-Path $cacheRoot 'sccache' } else { Join-Path $HOME '.cache\sccache' }
    $sccacheErrorLog = Join-Path $sccacheDir 'error.log'

    return [ordered]@{
        RUST_BACKTRACE          = '1'
        RUST_MIN_STACK         = '8388608'
        CARGO_INCREMENTAL      = '0'
        SCCACHE_DIR            = $sccacheDir
        SCCACHE_CACHE_SIZE     = '30G'
        SCCACHE_IDLE_TIMEOUT   = '3600'
        SCCACHE_DIRECT         = 'true'
        SCCACHE_SERVER_PORT    = '4400'
        SCCACHE_LOG            = 'warn'
        SCCACHE_ERROR_LOG      = $sccacheErrorLog
        SCCACHE_NO_DAEMON      = '0'
        SCCACHE_STARTUP_TIMEOUT = '30'
        SCCACHE_REQUEST_TIMEOUT = '180'
        SCCACHE_MAX_CONNECTIONS = '8'
        SCCACHE_CACHE_COMPRESSION = 'zstd'
    }
}

function Get-CargoEnvValueText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$RawValue,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$DefaultValue
    )

    $text = $RawValue.Trim()

    if ($text.StartsWith('{')) {
        if ($text -match 'value\s*=\s*"(?<raw>(?:\\.|[^"])*)"') {
            $inner = $Matches['raw'].Replace('\"', '"').Replace('\\', '\')
            if ($inner -match '^"(?<value>[^"\\]+)\\?$') {
                return $Matches['value']
            }
            if ($inner -match '^"(?<value>[^"]*)"\s*(#.*)?$') {
                return $Matches['value']
            }
            return $inner
        }

        return $DefaultValue
    }

    if ($text -match '^"(?<value>[^"]*)"\s*(#.*)?$') {
        return $Matches['value']
    }

    return $text
}

function Normalize-CargoConfigEnvTables {
    <#
    .SYNOPSIS
    Converts CargoTools-managed [env] scalar values to Cargo inline table values.
    .DESCRIPTION
    Cargo merges config files by key and type. A home config with
    SCCACHE_REQUEST_TIMEOUT = "180" conflicts with another config that uses
    SCCACHE_REQUEST_TIMEOUT = { value = "180", force = true }. Normalize only
    CargoTools-managed environment keys so user-owned settings are preserved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Config
    )

    $normalized = [ordered]@{}
    foreach ($section in $Config.Keys) {
        $normalized[$section] = [ordered]@{}
        foreach ($key in $Config[$section].Keys) {
            $normalized[$section][$key] = $Config[$section][$key]
        }
    }

    $changes = @()
    if (-not $normalized.Contains('env')) {
        return [PSCustomObject]@{
            Config  = $normalized
            Changes = $changes
        }
    }

    $managed = Get-ManagedCargoEnvDefaults
    foreach ($key in $managed.Keys) {
        if (-not $normalized['env'].Contains($key)) { continue }

        $current = $normalized['env'][$key]
        $currentString = [string]$current
        $cleanValue = Get-CargoEnvValueText -RawValue $currentString -DefaultValue ([string]$managed[$key])
        $newValue = New-CargoEnvInlineTable -Value $cleanValue
        if ($currentString.Trim() -ne $newValue.Trim()) {
            $normalized['env'][$key] = $newValue
            $changes += "Normalized $key in [env] to Cargo inline table format"
        }
    }

    return [PSCustomObject]@{
        Config  = $normalized
        Changes = $changes
    }
}

function Normalize-CargoConfigUnsupportedKeys {
    <#
    .SYNOPSIS
    Removes Cargo config keys known to be ignored by Cargo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Config
    )

    $normalized = [ordered]@{}
    foreach ($section in $Config.Keys) {
        $normalized[$section] = [ordered]@{}
        foreach ($key in $Config[$section].Keys) {
            $normalized[$section][$key] = $Config[$section][$key]
        }
    }

    $changes = @()
    if ($normalized.Contains('cargo-new') -and $normalized['cargo-new'].Contains('edition')) {
        $normalized['cargo-new'].Remove('edition')
        $changes += 'Removed unsupported cargo-new.edition key'
    }
    if ($normalized.Contains('alias') -and $normalized['alias'].Contains('fix')) {
        $normalized['alias'].Remove('fix')
        $changes += 'Removed alias.fix because it is shadowed by Cargo built-in command'
    }

    return [PSCustomObject]@{
        Config  = $normalized
        Changes = $changes
    }
}

function Merge-TomlConfig {
    <#
    .SYNOPSIS
    Merges default config into existing config, adding missing keys without overwriting.
    .PARAMETER Existing
    The existing configuration (ordered hashtable of sections).
    .PARAMETER Defaults
    The default configuration to merge in.
    .PARAMETER Force
    When set, overwrites existing values instead of preserving them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Existing,

        [Parameter(Mandatory)]
        [System.Collections.Specialized.OrderedDictionary]$Defaults,

        [Parameter()]
        [switch]$Force
    )

    $merged = [ordered]@{}
    $additions = @()

    # Copy all existing sections first
    foreach ($section in $Existing.Keys) {
        $merged[$section] = [ordered]@{}
        foreach ($key in $Existing[$section].Keys) {
            $merged[$section][$key] = $Existing[$section][$key]
        }
    }

    # Merge in defaults
    foreach ($section in $Defaults.Keys) {
        if (-not $merged.Contains($section)) {
            $merged[$section] = [ordered]@{}
            $additions += "Added section [$section]"
        }

        foreach ($key in $Defaults[$section].Keys) {
            if (-not $merged[$section].Contains($key) -or $Force) {
                if (-not $merged[$section].Contains($key)) {
                    $additions += "Added $key to [$section]"
                }
                $merged[$section][$key] = $Defaults[$section][$key]
            }
        }
    }

    return [PSCustomObject]@{
        Config    = $merged
        Additions = $additions
    }
}

function Write-ConfigFile {
    <#
    .SYNOPSIS
    Writes a TOML config file with backup support.
    .PARAMETER Path
    Path to write the config file.
    .PARAMETER Content
    The TOML string content to write.
    .PARAMETER Backup
    Create a .bak backup before overwriting. Defaults to $true.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content,

        [Parameter()]
        [switch]$NoBackup
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        if ($PSCmdlet.ShouldProcess($dir, 'Create directory')) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    if ((Test-Path $Path) -and -not $NoBackup) {
        $bakPath = "$Path.bak"
        if ($PSCmdlet.ShouldProcess($bakPath, 'Create backup')) {
            try {
                Copy-Item -LiteralPath $Path -Destination $bakPath -Force -ErrorAction Stop
            } catch {
                $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
                $fallbackBakPath = "$Path.cargotools.bak.$timestamp"
                Copy-Item -LiteralPath $Path -Destination $fallbackBakPath -Force -ErrorAction Stop
                Write-Verbose "Primary backup path '$bakPath' was unavailable; wrote '$fallbackBakPath'."
            }
        }
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write config file')) {
        Set-Content -Path $Path -Value $Content -Encoding UTF8 -NoNewline
    }
}

function Get-DefaultCargoConfig {
    <#
    .SYNOPSIS
    Returns optimal ~/.cargo/config.toml defaults.
    #>
    [CmdletBinding()]
    param()

    # Use machine-aware build jobs
    $mc = Get-MachineConfig
    $buildJobs = if ($mc['BuildJobs']) { [int]$mc['BuildJobs'] } else { 4 }

    # Resolve linker: prefer LLVM lld-link (absolute path) > MSVC link.exe > bundled rust-lld
    $linker = 'link.exe'
    $mc = Get-MachineConfig
    if ($mc['LldLinkExe'] -and (Test-Path $mc['LldLinkExe'])) {
        $linker = $mc['LldLinkExe']
    } else {
        $lldPath = Resolve-LldLinker
        if ($lldPath) {
            $linker = if ($lldPath -match '[/\\]rust-lld') { $lldPath } else { 'lld-link' }
        }
    }

    # Only set rustc-wrapper to sccache if it's actually installed
    $sccacheCmd = Resolve-Sccache
    $buildSection = [ordered]@{ jobs = $buildJobs }
    if ($sccacheCmd) { $buildSection['rustc-wrapper'] = 'sccache' }

    $envSection = [ordered]@{}
    $managedEnv = Get-ManagedCargoEnvDefaults
    foreach ($envKey in $managedEnv.Keys) {
        $envSection[$envKey] = New-CargoEnvInlineTable -Value ([string]$managedEnv[$envKey])
    }

    $config = [ordered]@{
        'registries.crates-io' = [ordered]@{
            protocol = 'sparse'
        }
        'build' = $buildSection
        'target.x86_64-pc-windows-msvc' = [ordered]@{
            linker = $linker
        }
        'env' = $envSection
        'term' = [ordered]@{
            color = 'auto'
        }
    }

    return $config
}

function Get-DefaultRustfmtConfig {
    <#
    .SYNOPSIS
    Returns optimal rustfmt.toml defaults.
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        '' = [ordered]@{
            edition = '2021'
            max_width = 100
            tab_spaces = 4
            hard_tabs = $false
            newline_style = 'Auto'
            reorder_imports = $true
            reorder_modules = $true
            merge_derives = $true
            use_field_init_shorthand = $true
            use_try_shorthand = $true
        }
    }
}

function Get-StableRustfmtConfigKeys {
    <#
    .SYNOPSIS
    Returns the CargoTools-managed stable rustfmt key set.
    .DESCRIPTION
    These keys are treated as the supported global baseline for the home-level
    rustfmt.toml. Local project rustfmt.toml files remain free to define their
    own overrides.
    #>
    [CmdletBinding()]
    param()

    return @(
        'edition',
        'max_width',
        'tab_spaces',
        'hard_tabs',
        'newline_style',
        'reorder_imports',
        'reorder_modules',
        'merge_derives',
        'use_field_init_shorthand',
        'use_try_shorthand'
    )
}

function Normalize-RustfmtConfig {
    <#
    .SYNOPSIS
    Prunes unsupported keys from a rustfmt config object.
    .DESCRIPTION
    Used for the global home-level rustfmt.toml so stable rustfmt defaults can
    be enforced without noisy warnings from nightly-only options. Project-local
    rustfmt.toml files can still opt into their own settings independently.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable]$Config,

        [string[]]$AllowedKeys = (Get-StableRustfmtConfigKeys)
    )

    $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($AllowedKeys)) {
        if (-not [string]::IsNullOrWhiteSpace($key)) {
            $null = $allowed.Add([string]$key)
        }
    }

    $root = [ordered]@{}
    if ($Config.Contains('')) {
        foreach ($entry in $Config[''].GetEnumerator()) {
            if ($allowed.Contains([string]$entry.Key)) {
                $root[[string]$entry.Key] = $entry.Value
            }
        }
    }

    $removed = [System.Collections.Generic.List[string]]::new()
    if ($Config.Contains('')) {
        foreach ($entry in $Config[''].GetEnumerator()) {
            if (-not $allowed.Contains([string]$entry.Key)) {
                $removed.Add([string]$entry.Key)
            }
        }
    }

    return [pscustomobject]@{
        Config = [ordered]@{ '' = $root }
        RemovedKeys = $removed.ToArray()
    }
}

function Get-DefaultClippyConfig {
    <#
    .SYNOPSIS
    Returns optimal .clippy.toml defaults.
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        '' = [ordered]@{
            msrv = '1.75.0'
            'too-many-arguments-threshold' = 8
            'type-complexity-threshold' = 500
        }
    }
}

function Get-DefaultRustAnalyzerConfig {
    <#
    .SYNOPSIS
    Returns optimal rust-analyzer.toml defaults.
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        'check' = [ordered]@{
            command = 'clippy'
        }
        'procMacro' = [ordered]@{
            enable = $true
        }
        'cachePriming' = [ordered]@{
            numThreads = 1
        }
        'diagnostics' = [ordered]@{
            disabled = '[]'
        }
    }
}
