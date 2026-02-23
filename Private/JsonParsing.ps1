function Parse-CargoJsonMessage {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string]$JsonLine
    )

    process {
        if ([string]::IsNullOrWhiteSpace($JsonLine)) { return }
        if (-not $JsonLine.StartsWith('{')) { return }

        try {
            $msg = $JsonLine | ConvertFrom-Json
            return $msg
        } catch {
            return $null
        }
    }
}

function Format-CargoDiagnosticJson {
    param(
        [Parameter(Mandatory)]
        [object]$Diagnostic
    )

    $level = $Diagnostic.level
    $message = $Diagnostic.message
    $code = ""
    if ($Diagnostic.code) { $code = $Diagnostic.code.code }
    
    $color = switch ($level) {
        'error'   { 'Red' }
        'warning' { 'Yellow' }
        'note'    { 'Cyan' }
        'help'    { 'Green' }
        default   { 'White' }
    }

    $file = ''
    $line = ''
    if ($Diagnostic.spans -and $Diagnostic.spans.Count -gt 0) {
        $span = $Diagnostic.spans[0]
        $file = $span.file_name
        $line = $span.line_start
    }

    $out = "[{0}]" -f $level
    if ($code) { $out += " ({0})" -f $code }
    if ($file) { $out += " {0}:{1}" -f $file, $line }
    $out += ": {0}" -f $message

    return [PSCustomObject]@{
        Text = $out
        Color = $color
        Level = $level
        File = $file
        Line = $line
        Code = $code
    }
}

function Invoke-CargoWithJson {
    param(
        [string]$RustupPath,
        [string[]]$CargoArgs
    )

    # Add --message-format=json-diagnostic-rendered-ansi if not present
    # Must be added BEFORE the -- separator
    $newArgs = New-Object System.Collections.Generic.List[string]
    $hasMsgFormat = $false
    $separatorIndex = [Array]::IndexOf($CargoArgs, '--')
    
    foreach ($arg in $CargoArgs) {
        if ($arg -like '--message-format*') { $hasMsgFormat = $true }
    }

    if ($separatorIndex -ge 0) {
        for ($i = 0; $i -lt $separatorIndex; $i++) { $newArgs.Add($CargoArgs[$i]) }
        if (-not $hasMsgFormat) { $newArgs.Add('--message-format=json-diagnostic-rendered-ansi') }
        for ($i = $separatorIndex; $i -lt $CargoArgs.Count; $i++) { $newArgs.Add($CargoArgs[$i]) }
    } else {
        $newArgs.AddRange($CargoArgs)
        if (-not $hasMsgFormat) { $newArgs.Add('--message-format=json-diagnostic-rendered-ansi') }
    }

    $diagnostics = New-Object System.Collections.Generic.List[object]
    
    # Run cargo and capture stdout/stderr
    & $RustupPath run stable cargo @newArgs 2>&1 | ForEach-Object {
        if ($_ -is [string]) {
            $line = $_
            if ($line.StartsWith('{')) {
                $msg = $line | Parse-CargoJsonMessage
                if ($msg -and $msg.reason -eq 'compiler-message') {
                    $diag = Format-CargoDiagnosticJson -Diagnostic $msg.message
                    Write-Host $diag.Text -ForegroundColor $diag.Color
                    $diagnostics.Add($diag)
                } elseif ($msg -and $msg.reason -eq 'build-finished') {
                    # Build finished
                } else {
                    # Write-Host $line # Too noisy
                }
            } else {
                Write-Host $line
            }
        } else {
            Write-Host $_.ToString() -ForegroundColor Red
        }
    }

    return $diagnostics
}


