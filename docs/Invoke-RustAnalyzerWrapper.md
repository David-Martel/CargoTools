---
external help file: CargoTools-help.xml
Module Name: CargoTools
online version:
schema: 2.0.0
---

# Invoke-RustAnalyzerWrapper

## SYNOPSIS
Single-instance rust-analyzer launcher.

## SYNTAX

```
Invoke-RustAnalyzerWrapper [[-ArgumentList] <String[]>] [-ProgressAction <ActionPreference>]
 [<CommonParameters>]
```

## DESCRIPTION
Launches rust-analyzer through CargoTools with a transport-aware wrapper.
Interactive/stdin LSP sessions default to `lspmux` when available, while
standalone commands such as `diagnostics`, `--help`, and `--version` run
directly against the resolved `rust-analyzer.exe`.

## EXAMPLES

### Example 1
```powershell
PS C:\> Invoke-RustAnalyzerWrapper
```

Start an editor-facing rust-analyzer session, using `lspmux` automatically when
available.

### Example 2
```powershell
PS C:\> Invoke-RustAnalyzerWrapper --transport direct diagnostics .
```

Run a standalone rust-analyzer diagnostics command without `lspmux`.

## PARAMETERS

### -ArgumentList
Raw rust-analyzer wrapper arguments.

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
