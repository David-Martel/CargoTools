function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim().ToLowerInvariant()
    return ($v -ne '0' -and $v -ne 'false' -and $v -ne 'no' -and $v -ne 'off')
}

function Normalize-ArgsList {
    param([object]$ArgsList)
    if ($null -eq $ArgsList) { return @() }
    if ($ArgsList -is [System.Array]) { return $ArgsList }
    return @($ArgsList)
}

function Get-EnvValue {
    param([string]$Name)
    try {
        $item = Get-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
        if ($item) { return $item.Value }
    } catch {}
    return $null
}

function Add-RustFlags {
    param([string]$NewFlags)
    if ([string]::IsNullOrWhiteSpace($NewFlags)) { return }
    if ($env:RUSTFLAGS) {
        $env:RUSTFLAGS = "$env:RUSTFLAGS $NewFlags"
    } else {
        $env:RUSTFLAGS = $NewFlags
    }
}

function Get-PrimaryCommand {
    param([string[]]$ArgsList)
    $ArgsList = Normalize-ArgsList $ArgsList
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        $arg = $ArgsList[$i]
        if ($arg.StartsWith('-') -or $arg.StartsWith('+')) { continue }
        return $arg
    }
    return $null
}

function Ensure-MessageFormatShort {
    param([string[]]$ArgsList)
    $ArgsList = Normalize-ArgsList $ArgsList
    foreach ($arg in $ArgsList) {
        if ($arg -eq '--message-format' -or $arg -like '--message-format=*') {
            return $ArgsList
        }
    }
    $out = New-Object System.Collections.Generic.List[string]
    $out.AddRange($ArgsList)
    $out.Add('--message-format=short')
    return $out
}

function Convert-ArgsToShell {
    param([string[]]$Values)
    $Values = Normalize-ArgsList $Values
    $single = "'"
    $double = '"'
    $replacement = $single + $double + $single + $double + $single
    $escaped = foreach ($v in $Values) {
        if ($v -match '[\s''"\]') {
            $safe = $v.Replace($single, $replacement)
            $single + $safe + $single
        } else {
            $v
        }
    }
    return ($escaped -join ' ')
}

function Get-TargetFromArgs {
    param([string[]]$ArgsList)
    $ArgsList = Normalize-ArgsList $ArgsList
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        $arg = $ArgsList[$i]
        if ($arg -eq '--target') {
            if ($i + 1 -lt $ArgsList.Count) { return $ArgsList[$i + 1] }
        }
        if ($arg -like '--target=*') {
            return $arg.Substring(9)
        }
    }
    if ($env:CARGO_BUILD_TARGET) { return $env:CARGO_BUILD_TARGET }
    return $null
}

function Classify-Target {
    param([string]$Target)
    if (-not $Target) { return 'unknown' }
    if ($Target -match 'windows') { return 'windows' }
    if ($Target -match 'wasm') { return 'wasm' }
    if ($Target -match 'apple') { return 'apple' }
    if ($Target -match 'linux' -or $Target -match 'gnu' -or $Target -match 'musl') { return 'linux' }
    return 'other'
}

function Assert-AllowedValue {
    param(
        [string]$Name,
        [string]$Value,
        [string[]]$Allowed
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    if ($Allowed -contains $Value) { return $true }

    $allowedText = $Allowed -join ', '
    Write-Error "$Name must be one of: $allowedText. Got: $Value"
    return $false
}

function Assert-NotBoth {
    param(
        [string]$Name,
        [bool]$A,
        [bool]$B
    )

    if ($A -and $B) {
        Write-Error "$Name options are mutually exclusive."
        return $false
    }

    return $true
}

function Strip-ArgsAfterDoubleDash {
    param([string[]]$ArgsList)

    $ArgsList = Normalize-ArgsList $ArgsList
    if (-not $ArgsList -or $ArgsList.Count -eq 0) { return $ArgsList }
    $index = [Array]::IndexOf($ArgsList, '--')
    if ($index -lt 0) { return $ArgsList }
    if ($index -eq 0) { return @() }
    return $ArgsList[0..($index - 1)]
}

function Ensure-RunArgSeparator {
    param([string[]]$ArgsList)

    $ArgsList = Normalize-ArgsList $ArgsList
    if (-not $ArgsList -or $ArgsList.Count -eq 0) { return $ArgsList }
    
    # If it already has a separator, respect it
    if ([Array]::IndexOf($ArgsList, '--') -ge 0) { return $ArgsList }

    $primary = Get-PrimaryCommand $ArgsList
    # Allow separator auto-insertion for run, test, and clippy
    if ($primary -ne 'run' -and $primary -ne 'test' -and $primary -ne 'clippy') { return $ArgsList }

    $flagsWithValue = @(
        '--bin','--example','--package','-p','--profile','--target','--features','--target-dir','--test','--bench','--message-format'
    )
    $flagsNoValue = @(
        '--release','--all-features','--no-default-features','--quiet','-q','-vv','-v','--verbose','--workspace','--all-targets','--doc','--lib','--bins','--tests','--benches'
    )

    $seenPrimary = $false
    $expectValue = $false
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        $arg = $ArgsList[$i]
        if (-not $seenPrimary) {
            if ($arg -eq $primary) { $seenPrimary = $true }
            continue
        }

        if ($expectValue) {
            $expectValue = $false
            continue
        }

        if ($flagsWithValue -contains $arg) {
            $expectValue = $true
            continue
        }

        if ($flagsNoValue -contains $arg) { continue }
        if ($arg -like '--*=*') { continue }
        if ($arg -like '-*' -and $flagsWithValue -notcontains $arg -and $flagsNoValue -notcontains $arg) {
            $result = New-Object System.Collections.Generic.List[string]
            for ($j = 0; $j -lt $i; $j++) { $result.Add([string]$ArgsList[$j]) }
            $result.Add('--')
            for ($j = $i; $j -lt $ArgsList.Count; $j++) { $result.Add([string]$ArgsList[$j]) }
            return $result.ToArray()
        }
        if (-not $arg.StartsWith('-')) {
            $result = New-Object System.Collections.Generic.List[string]
            for ($j = 0; $j -lt $i; $j++) { $result.Add([string]$ArgsList[$j]) }
            $result.Add('--')
            for ($j = $i; $j -lt $ArgsList.Count; $j++) { $result.Add([string]$ArgsList[$j]) }
            return $result.ToArray()
        }
    }

    return $ArgsList
}
