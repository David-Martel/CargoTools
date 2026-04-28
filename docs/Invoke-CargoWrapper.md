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

## NOTES

## RELATED LINKS
