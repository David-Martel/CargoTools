---
external help file: CargoTools-help.xml
Module Name: CargoTools
online version:
schema: 2.0.0
---

# Invoke-CargoWrapper

## SYNOPSIS
Centralized cargo wrapper with sccache and diagnostics support.

## SYNTAX

```
Invoke-CargoWrapper [[-ArgumentList] <String[]>] [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

```
Invoke-CargoWrapper -Command <String> [-AdditionalArgs <String[]>] [-WorkingDirectory <String>]
 [-ProgressAction <ActionPreference>] [<CommonParameters>]
```

## DESCRIPTION
Sets sccache defaults, optional linkers, and runs preflight diagnostics before cargo builds.

## EXAMPLES

### EXAMPLE 1
```
Invoke-CargoWrapper --wrapper-help
```

### EXAMPLE 2
```
Invoke-CargoWrapper -Command build -AdditionalArgs @('--release') -WorkingDirectory C:\codedev\socat\rsocat
```

### EXAMPLE 3
```
pwsh -NoProfile -c "Import-Module CargoTools; Invoke-CargoWrapper check && Invoke-CargoWrapper clippy --all-targets -- -D warnings"
```
Build gate.
A non-zero cargo result makes the call write a non-terminating error, so `$?` is false, `&&` stops
the chain and the process exits 1.

### EXAMPLE 4
```
pwsh -NoProfile -c "Import-Module CargoTools; Invoke-CargoWrapper test; exit `$LASTEXITCODE"
```
Exits with cargo's own code (for example 101 for a failed test run).

## PARAMETERS

### -ArgumentList
Raw cargo arguments to pass through.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Command
Primary cargo subcommand (e.g. build, test, clippy).

```yaml
Type: String
Parameter Sets: Named
Aliases:

Required: True
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -AdditionalArgs
Additional cargo arguments (e.g. --release, -- --nocapture).

```yaml
Type: String[]
Parameter Sets: Named
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WorkingDirectory
Working directory containing Cargo.toml for the build.

```yaml
Type: String
Parameter Sets: Named
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction
{{ Fill ProgressAction Description }}

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### System.Int32
The exit code of the last command the wrapper ran (0 on success).

## NOTES
Status contract: the exit code is returned as the last output item and published in
`$LASTEXITCODE`.
A non-zero code also writes a non-terminating error (ErrorId `CargoToolsNonZeroExit`,
TargetObject = the exit code) so `$?` is `$false`.
That is what `pwsh -Command`, `&&` and `if ($?)` read; `$LASTEXITCODE` alone does not fail a
`-Command` process.
The process exit code is then 1; use `; exit $LASTEXITCODE` for the exact cargo code.

The error does not become an exception for callers that set `$ErrorActionPreference = 'Stop'`
(the wrapper scripts do, and read the returned code).
Pass `-ErrorAction Stop` explicitly to get one, or `-ErrorAction SilentlyContinue` to hide the
message while keeping `$?` false.

Separate statements joined with `;` are independent: `-Command` reflects only the last one, so a
failure in an earlier statement is masked.
Chain gates with `&&` (PowerShell 7+) or test `$?` between statements.
Covered by `Tests/Invoke-CargoWrapper.ExitStatus.Tests.ps1`.

PowerShell resolves `-p` as an ambiguous prefix of common parameters (`-PipelineVariable`,
`-ProgressAction`).
Write `--package`, or pass `-ArgumentList @('-p', 'name')`.

## RELATED LINKS
