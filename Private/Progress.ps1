# Progress tracking and verbosity management for CargoTools

# Verbosity levels: 0=quiet, 1=normal, 2=verbose, 3=debug
$script:VerbosityLevel = 1

function Set-CargoVerbosity {
    param([int]$Level)
    $script:VerbosityLevel = [Math]::Max(0, [Math]::Min(3, $Level))
}

function Get-CargoVerbosity {
    return $script:VerbosityLevel
}

function Write-CargoStatus {
    <#
    .SYNOPSIS
    Write a status message with phase indicator.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Debug')]
        [string]$Type = 'Info',

        [int]$MinVerbosity = 1
    )

    if ($script:VerbosityLevel -lt $MinVerbosity) { return }

    $colors = @{
        Info    = 'Cyan'
        Success = 'Green'
        Warning = 'Yellow'
        Error   = 'Red'
        Debug   = 'DarkGray'
    }

    $symbols = @{
        Info    = [char]0x2022  # bullet
        Success = [char]0x2713  # checkmark
        Warning = [char]0x26A0  # warning
        Error   = [char]0x2717  # X
        Debug   = [char]0x2022  # bullet
    }

    $symbol = $symbols[$Type]
    $color = $colors[$Type]

    Write-Host "  [$Phase] $symbol $Message" -ForegroundColor $color
}

function Write-CargoProgress {
    <#
    .SYNOPSIS
    Write a progress indicator for long-running operations.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Activity,

        [Parameter(Mandatory)]
        [int]$Current,

        [Parameter(Mandatory)]
        [int]$Total,

        [string]$Status = ''
    )

    if ($script:VerbosityLevel -lt 1) { return }

    $percent = [Math]::Round(($Current / $Total) * 100)
    $barLength = 30
    $filled = [Math]::Round($barLength * ($Current / $Total))
    $empty = $barLength - $filled

    $bar = ('[' + ('=' * $filled) + (' ' * $empty) + ']')

    $statusText = if ($Status) { " - $Status" } else { '' }

    Write-Progress -Activity $Activity -Status "$bar $percent%$statusText" -PercentComplete $percent
}

function Write-CargoBuildPhase {
    <#
    .SYNOPSIS
    Write build phase header with visual indicator.
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Preflight', 'Environment', 'Build', 'PostBuild', 'AutoCopy')]
        [string]$Phase,

        [switch]$Starting,
        [switch]$Complete,
        [switch]$Failed
    )

    if ($script:VerbosityLevel -lt 1) { return }

    $phaseColors = @{
        Preflight   = 'DarkYellow'
        Environment = 'DarkCyan'
        Build       = 'White'
        PostBuild   = 'DarkGreen'
        AutoCopy    = 'Cyan'
    }

    $color = $phaseColors[$Phase]

    if ($Starting) {
        Write-Host ""
        Write-Host "  === $Phase ===" -ForegroundColor $color
    } elseif ($Complete) {
        Write-Host "  === $Phase Complete ===" -ForegroundColor Green
    } elseif ($Failed) {
        Write-Host "  === $Phase FAILED ===" -ForegroundColor Red
    }
}

function Format-CargoDiagnostics {
    <#
    .SYNOPSIS
    Format cargo error output with enhanced debugging info.
    #>
    param(
        [int]$ExitCode,
        [string]$Command,
        [string[]]$Arguments,
        [datetime]$StartTime
    )

    $elapsed = (Get-Date) - $StartTime

    $diag = @"

  ============================================
  CARGO BUILD FAILED
  ============================================
  Exit Code    : $ExitCode
  Command      : $Command
  Arguments    : $($Arguments -join ' ')
  Duration     : $([Math]::Round($elapsed.TotalSeconds, 2))s
  Working Dir  : $(Get-Location)

  Environment:
    RUSTC_WRAPPER    : $env:RUSTC_WRAPPER
    CARGO_TARGET_DIR : $env:CARGO_TARGET_DIR
    SCCACHE_DIR      : $env:SCCACHE_DIR
    RUSTFLAGS        : $env:RUSTFLAGS

  Troubleshooting:
    1. Run 'cargo check' to see compile errors
    2. Run 'cargo clippy' for additional diagnostics
    3. Check 'sccache --show-stats' for cache issues
    4. Try 'cargo clean' then rebuild
    5. Check T:\RustCache\sccache\error.log for sccache errors
  ============================================
"@

    return $diag
}

function Show-SccacheStatus {
    <#
    .SYNOPSIS
    Display sccache statistics in a compact format.
    #>
    param([switch]$Compact)

    if ($script:VerbosityLevel -lt 2) { return }

    try {
        $sccacheCmd = Get-Command sccache -ErrorAction SilentlyContinue
        if (-not $sccacheCmd) { return }
        $stats = sccache --show-stats 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($Compact) {
                # Parse and show compact stats
                $hits = ($stats | Select-String 'Cache hits' | ForEach-Object { ($_ -split '\s+')[-1] }) -join ''
                $misses = ($stats | Select-String 'Cache misses' | ForEach-Object { ($_ -split '\s+')[-1] }) -join ''
                if ($hits -or $misses) {
                    Write-Host "  [sccache] hits: $hits, misses: $misses" -ForegroundColor DarkGray
                }
            } else {
                Write-Host "  [sccache stats]" -ForegroundColor DarkCyan
                $stats | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
            }
        }
    } catch {
        Write-Debug "[Progress] Failed to get sccache stats: $_"
    }
}

function Write-CargoDebug {
    <#
    .SYNOPSIS
    Write debug-level output only when verbosity >= 3.
    #>
    param([string]$Message)

    if ($script:VerbosityLevel -ge 3) {
        Write-Host "  [DEBUG] $Message" -ForegroundColor DarkGray
    }
}

function Initialize-CargoVerbosity {
    <#
    .SYNOPSIS
    Initialize verbosity from arguments and environment.
    #>
    param([string[]]$Arguments)

    $Arguments = Normalize-ArgsList $Arguments

    # Check env var first
    if ($env:CARGO_VERBOSITY) {
        $script:VerbosityLevel = [int]$env:CARGO_VERBOSITY
    }

    # Arguments override env
    foreach ($arg in $Arguments) {
        switch ($arg) {
            '-q' { $script:VerbosityLevel = 0 }
            '--quiet' { $script:VerbosityLevel = 0 }
            '-v' { $script:VerbosityLevel = 2 }
            '--verbose' { $script:VerbosityLevel = 2 }
            '-vv' { $script:VerbosityLevel = 3 }
            '--debug' { $script:VerbosityLevel = 3 }
        }
    }

    return $script:VerbosityLevel
}

function Get-VerbosityArgs {
    <#
    .SYNOPSIS
    Extract verbosity-related arguments for filtering.
    Returns filtered arguments without verbosity flags.
    #>
    param([string[]]$Arguments)

    $Arguments = Normalize-ArgsList $Arguments
    if ($null -eq $Arguments -or $Arguments.Count -eq 0) {
        return [string[]]@()
    }

    $verbosityArgs = @('-q', '--quiet', '-v', '--verbose', '-vv', '--debug')
    $filtered = New-Object System.Collections.Generic.List[string]

    foreach ($arg in $Arguments) {
        if ($verbosityArgs -notcontains $arg) {
            $filtered.Add($arg)
        }
    }

    return [string[]]$filtered.ToArray()
}

function Measure-CargoPhase {
    <#
    .SYNOPSIS
    Measure execution time of a build phase.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    $start = Get-Date
    Write-CargoBuildPhase -Phase $Phase -Starting

    try {
        $result = & $Action
        $elapsed = (Get-Date) - $start

        if ($script:VerbosityLevel -ge 2) {
            Write-Host "  [$Phase] completed in $([Math]::Round($elapsed.TotalSeconds, 2))s" -ForegroundColor DarkGray
        }

        Write-CargoBuildPhase -Phase $Phase -Complete
        return $result
    } catch {
        Write-CargoBuildPhase -Phase $Phase -Failed
        throw
    }
}
