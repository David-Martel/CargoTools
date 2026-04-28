# C# accelerators for shell-escaping, argument manipulation, and concurrency.
# Falls back gracefully if Add-Type fails (e.g., locked assembly in same session).
if (-not ([System.Management.Automation.PSTypeName]'CargoTools.ShellEscape').Type) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace CargoTools
{
    public static class ShellEscape
    {
        private static readonly Regex UnsafePattern = new Regex(@"[^A-Za-z0-9_./:=@,+\-]", RegexOptions.Compiled);

        public static string QuoteArg(string value)
        {
            if (value == null) return "''";
            if (value.Length == 0) return "''";
            if (!UnsafePattern.IsMatch(value)) return value;
            return "'" + value.Replace("'", "'\"'\"'") + "'";
        }

        public static string JoinArgs(string[] values)
        {
            if (values == null || values.Length == 0) return "";
            var sb = new StringBuilder();
            for (int i = 0; i < values.Length; i++)
            {
                if (i > 0) sb.Append(' ');
                sb.Append(QuoteArg(values[i]));
            }
            return sb.ToString();
        }
    }

    /// <summary>
    /// Named mutex helper for cross-process synchronization.
    /// Used to prevent sccache startup races when multiple agents call cargo concurrently.
    /// </summary>
    public static class ProcessMutex
    {
        /// <summary>
        /// Acquires a named system mutex. Returns a disposable handle or null on timeout.
        /// Caller MUST dispose the result to release the mutex.
        /// </summary>
        public static MutexHandle TryAcquire(string name, int timeoutMs)
        {
            bool createdNew;
            Mutex mutex = null;
            try
            {
                mutex = new Mutex(false, @"Global\" + name, out createdNew);
                if (mutex.WaitOne(timeoutMs))
                {
                    return new MutexHandle(mutex);
                }
                mutex.Dispose();
                return null;
            }
            catch (AbandonedMutexException)
            {
                // Previous holder crashed - we now own the mutex
                if (mutex != null) return new MutexHandle(mutex);
                return null;
            }
            catch
            {
                if (mutex != null) mutex.Dispose();
                return null;
            }
        }
    }

    public class MutexHandle : IDisposable
    {
        private Mutex _mutex;
        private bool _disposed;

        public MutexHandle(Mutex mutex) { _mutex = mutex; }

        public void Dispose()
        {
            if (!_disposed && _mutex != null)
            {
                try { _mutex.ReleaseMutex(); } catch { }
                _mutex.Dispose();
                _disposed = true;
            }
        }
    }

    /// <summary>
    /// Robust file copy with retry logic for concurrent access scenarios.
    /// Handles file-in-use errors from parallel builds sharing CARGO_TARGET_DIR.
    /// </summary>
    public static class FileCopy
    {
        public static CopyResult CopyWithRetry(string source, string dest, int maxRetries, int retryDelayMs)
        {
            var result = new CopyResult { Source = source, Destination = dest };
            for (int attempt = 0; attempt <= maxRetries; attempt++)
            {
                try
                {
                    File.Copy(source, dest, true);
                    result.Success = true;
                    result.Attempts = attempt + 1;
                    return result;
                }
                catch (IOException ex)
                {
                    result.LastError = ex.Message;
                    if (attempt < maxRetries)
                    {
                        // Exponential backoff: 100ms, 200ms, 400ms, ...
                        Thread.Sleep(retryDelayMs * (1 << attempt));
                    }
                }
                catch (UnauthorizedAccessException ex)
                {
                    result.LastError = ex.Message;
                    if (attempt < maxRetries)
                    {
                        Thread.Sleep(retryDelayMs * (1 << attempt));
                    }
                }
            }
            result.Attempts = maxRetries + 1;
            return result;
        }
    }

    public class CopyResult
    {
        public string Source { get; set; }
        public string Destination { get; set; }
        public bool Success { get; set; }
        public int Attempts { get; set; }
        public string LastError { get; set; }
    }
}
'@ -Language CSharp -ErrorAction SilentlyContinue
    } catch {
        # Silently continue - PowerShell fallback will be used
    }
}

function Test-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $v = $Value.Trim().ToLowerInvariant()
    return ($v -ne '0' -and $v -ne 'false' -and $v -ne 'no' -and $v -ne 'off')
}

function Normalize-ArgsList {
    param($ArgsList)
    if ($null -eq $ArgsList) { Write-Output @() -NoEnumerate; return }
    if ($ArgsList -is [System.Array]) { Write-Output $ArgsList -NoEnumerate; return }
    Write-Output @($ArgsList) -NoEnumerate
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
    # Use C# accelerator when available for performance and correctness
    if (([System.Management.Automation.PSTypeName]'CargoTools.ShellEscape').Type) {
        return [CargoTools.ShellEscape]::JoinArgs([string[]]$Values)
    }
    # PowerShell fallback: whitelist approach (shlex.quote style)
    $single = "'"
    $double = '"'
    $replacement = $single + $double + $single + $double + $single
    $escaped = foreach ($v in $Values) {
        if ($v -match '[^A-Za-z0-9_./:=@,+\-]') {
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
    if ($ArgsList -contains '--') { return $ArgsList }

    $primary = Get-PrimaryCommand $ArgsList
    if ($primary -ne 'run') { return $ArgsList }

    $flagsWithValue = @(
        '--bin','--example','--package','-p','--profile','--target','--features','--target-dir'
    )
    $flagsNoValue = @(
        '--release','--all-features','--no-default-features','--quiet','-q','-vv','-v','--verbose'
    )

    $seenRun = $false
    $expectValue = $false
    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        $arg = $ArgsList[$i]
        if (-not $seenRun) {
            if ($arg -eq 'run') { $seenRun = $true }
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
