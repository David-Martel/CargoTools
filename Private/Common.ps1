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
    <#
    .SYNOPSIS
    Appends flags to RUSTFLAGS, skipping any that are already there.
    .DESCRIPTION
    RUSTFLAGS is part of every sccache key, so it must be the same string on every call of the same
    build. The wrapper runs Initialize-CargoEnv and the linker/CPU helpers on each invocation in a
    long-lived session; appending unconditionally made RUSTFLAGS grow ("-C target-cpu=native -C
    target-cpu=native ...") and each length was a different cache key. Each argument is one flag
    (possibly several words, e.g. '-C lto=thin') and is added only if that exact word sequence is not
    already present. Several flags may be passed in one call.
    #>
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$NewFlags)

    foreach ($flag in @($NewFlags)) {
        if ([string]::IsNullOrWhiteSpace($flag)) { continue }
        $flag = ($flag.Trim() -replace '\s+', ' ')
        $current = if ($env:RUSTFLAGS) { ($env:RUSTFLAGS.Trim() -replace '\s+', ' ') } else { '' }
        if ((" $current ").Contains(" $flag ")) { continue }
        $env:RUSTFLAGS = if ($current) { "$current $flag" } else { $flag }
    }
}

# Variables this module defines and reads itself. They are not cargo settings.
$script:CargoToolsPrivateEnvPattern = '^CARGO_(USE_[A-Z]+|PREFLIGHT[A-Z_]*|RA_PREFLIGHT|ROUTE_[A-Z]+|WSL_[A-Z]+|LLM_[A-Z]+|DOCKER_[A-Z]+|AUTO_COPY(_EXAMPLES)?|QUICK_CHECK|VERBOSITY|PROFILE|RAW|LLD_PATH|TIMINGS|RELEASE_LTO|TOOLCHAIN)$'

function Add-CargoTargetDirArg {
    <#
    .SYNOPSIS
    Moves the target directory from CARGO_TARGET_DIR into a --target-dir argument.
    .DESCRIPTION
    sccache hashes every CARGO_* variable that rustc inherits, so an exported CARGO_TARGET_DIR makes
    each distinct directory a separate cache (a build in a second directory missed 57 of 57 units).
    A command-line flag is not in rustc's environment. This only builds the argument list;
    Invoke-RustupCargo removes the variable for the duration of the call.
    Returns the arguments unchanged when the variable is unset, the subcommand does not take the
    flag, or the caller already passed one. The flag goes before a bare `--` so it is never handed to
    a test harness or to `cargo run`.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()][string]$TargetDir = $env:CARGO_TARGET_DIR,
        [string]$PrimaryCommand,
        [string[]]$ArgsList
    )

    $supported = @('build', 'check', 'clippy', 'test', 'doc', 'run', 'bench', 'rustc', 'rustdoc', 'nextest', 'llvm-cov')
    if ([string]::IsNullOrWhiteSpace($TargetDir) -or $PrimaryCommand -notin $supported) { return $ArgsList }
    foreach ($a in $ArgsList) {
        if ($a -eq '--') { break }
        if ($a -eq '--target-dir' -or $a.StartsWith('--target-dir=')) { return $ArgsList }
    }

    $out = New-Object System.Collections.Generic.List[string]
    $inserted = $false
    foreach ($a in $ArgsList) {
        if ($a -eq '--' -and -not $inserted) {
            $out.Add('--target-dir'); $out.Add($TargetDir); $inserted = $true
        }
        $out.Add($a)
    }
    if (-not $inserted) { $out.Add('--target-dir'); $out.Add($TargetDir) }
    return $out.ToArray()
}

function Invoke-RustupCargo {
    <#
    .SYNOPSIS
    Runs `rustup run <toolchain> cargo ...` with the target directory passed as a flag.
    .DESCRIPTION
    See Add-CargoTargetDirArg for why. CARGO_TARGET_DIR is restored afterwards because the wrapper's
    own post-build steps read it. Output and $LASTEXITCODE behave as for a direct call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RustupPath,
        [Parameter(Mandatory)][string]$Toolchain,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$CargoArgs
    )

    $savedTargetDir = $env:CARGO_TARGET_DIR
    $finalArgs = @(Add-CargoTargetDirArg -TargetDir $savedTargetDir -PrimaryCommand (Get-PrimaryCommand $CargoArgs) -ArgsList $CargoArgs)
    if ($savedTargetDir -and $finalArgs.Count -ne $CargoArgs.Count) { Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue }

    # CargoTools' own switches (CARGO_USE_LLD, CARGO_PREFLIGHT_*, ...) are read by this module, not by
    # cargo, but they start with CARGO_ and so end up in every sccache key: a build with one toggled
    # cannot share a cache with a build without it. Hide them from cargo for the call.
    $savedToggles = @{}
    foreach ($entry in @(Get-ChildItem Env: | Where-Object { $_.Name -match $script:CargoToolsPrivateEnvPattern })) {
        $savedToggles[$entry.Name] = $entry.Value
        Remove-Item "Env:$($entry.Name)" -ErrorAction SilentlyContinue
    }
    try {
        & $RustupPath run $Toolchain cargo @finalArgs
    } finally {
        if ($savedTargetDir) { $env:CARGO_TARGET_DIR = $savedTargetDir }
        foreach ($name in $savedToggles.Keys) { Set-Item "Env:$name" $savedToggles[$name] }
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
    [CmdletBinding()]
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
    [CmdletBinding()]
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

    return (Split-CargoArgsAtDoubleDash -ArgsList $ArgsList).CargoArgs
}

function Get-ClippyFixArgs {
    [CmdletBinding()]
    param([string[]]$ArgsList)

    $cargoArgs = Normalize-ArgsList (Strip-ArgsAfterDoubleDash $ArgsList)
    $result = New-Object System.Collections.Generic.List[string]
    $commandRemoved = $false
    $optionsWithValues = @(
        '-p', '--package', '--exclude', '-m', '--manifest-path',
        '-F', '--features', '--target', '--target-dir', '--profile',
        '-j', '--jobs', '--bin', '--example', '--test', '--bench',
        '--config'
    )
    $standaloneOptions = @(
        '--workspace', '--all', '--all-features', '--no-default-features',
        '-r', '--release', '--locked', '--offline', '--frozen', '--keep-going',
        '--ignore-rust-version', '--lib', '--bins', '--examples', '--tests',
        '--benches', '--all-targets'
    )
    $valuePrefixes = @(
        '--package=', '--exclude=', '--manifest-path=', '--features=',
        '--target=', '--target-dir=', '--profile=', '--jobs=',
        '--bin=', '--example=', '--test=', '--bench=', '--config='
    )

    for ($i = 0; $i -lt $cargoArgs.Count; $i++) {
        $arg = [string]$cargoArgs[$i]

        if (-not $commandRemoved -and @('build', 'check', 'test', 'bench', 'run') -contains $arg) {
            $commandRemoved = $true
            continue
        }
        if ($arg.StartsWith('+')) { continue }

        if ($optionsWithValues -contains $arg) {
            if ($i + 1 -lt $cargoArgs.Count) {
                $result.Add($arg)
                $i++
                $result.Add([string]$cargoArgs[$i])
            }
            continue
        }
        if ($standaloneOptions -contains $arg) {
            $result.Add($arg)
            continue
        }

        $isValueOption = $false
        foreach ($prefix in $valuePrefixes) {
            if ($arg.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
                $isValueOption = $true
                break
            }
        }
        if ($isValueOption -or $arg -match '^-[pFjm].+') {
            $result.Add($arg)
        }
    }

    return $result.ToArray()
}

function Split-CargoArgsAtDoubleDash {
    param([string[]]$ArgsList)

    $ArgsList = Normalize-ArgsList $ArgsList
    if (-not $ArgsList -or $ArgsList.Count -eq 0) {
        return [pscustomobject]@{
            CargoArgs = @()
            ToolArgs = @()
            HasSeparator = $false
        }
    }

    $index = [Array]::IndexOf($ArgsList, '--')
    if ($index -lt 0) {
        return [pscustomobject]@{
            CargoArgs = $ArgsList
            ToolArgs = @()
            HasSeparator = $false
        }
    }

    $cargoArgs = if ($index -eq 0) { @() } else { @($ArgsList[0..($index - 1)]) }
    $toolArgs = if ($index + 1 -ge $ArgsList.Count) { @() } else { @($ArgsList[($index + 1)..($ArgsList.Count - 1)]) }

    return [pscustomobject]@{
        CargoArgs = $cargoArgs
        ToolArgs = $toolArgs
        HasSeparator = $true
    }
}

function Test-SccacheInfrastructureFailureText {
    <#
    .SYNOPSIS
    Detects sccache infrastructure failures, not Rust compiler diagnostics.
    #>
    param(
        [AllowNull()][string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    $patterns = @(
        'sccache:\s*error:\s*failed to execute compile',
        'sccache:\s*error:\s*timed out',
        'Failed to send data to or receive data from server',
        'Failed to read response header',
        'forcibly closed by the remote host',
        'failed to persist temporary file',
        'Only one usage of each socket address',
        'An attempt was made to access a socket in a way forbidden',
        'Failed to bind socket'
    )

    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) { return $true }
    }
    return $false
}

function Test-SccacheInfrastructureFailureFromLog {
    <#
    .SYNOPSIS
    Checks whether the current build window logged an sccache infrastructure failure.
    #>
    [CmdletBinding()]
    param(
        [datetime]$SinceUtc = (Get-Date).ToUniversalTime().AddMinutes(-5),
        [string]$LogPath = $env:SCCACHE_ERROR_LOG,
        [int]$Tail = 400
    )

    if (-not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) {
        return $false
    }

    $since = if ($SinceUtc.Kind -eq [DateTimeKind]::Utc) {
        $SinceUtc
    } else {
        $SinceUtc.ToUniversalTime()
    }
    $windowStart = $since.AddSeconds(-5)
    $logItem = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
    $untimestampedMatch = $false

    foreach ($line in @(Get-Content -LiteralPath $LogPath -Tail $Tail -ErrorAction SilentlyContinue)) {
        if (-not (Test-SccacheInfrastructureFailureText -Text $line)) { continue }

        $match = [regex]::Match($line, '^\[(?<ts>\d{4}-\d{2}-\d{2}T[^\s\]]+)')
        if ($match.Success) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse(
                    $match.Groups['ts'].Value,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AdjustToUniversal,
                    [ref]$parsed
                ) -and $parsed.ToUniversalTime() -ge $windowStart) {
                return $true
            }
        } else {
            $untimestampedMatch = $true
        }
    }

    if ($untimestampedMatch -and $logItem -and $logItem.LastWriteTimeUtc -ge $windowStart) {
        return $true
    }
    return $false
}

function Add-NoSccacheCargoConfigArgs {
    <#
    .SYNOPSIS
    Prepends a cargo config override that clears build.rustc-wrapper.
    #>
    param(
        [AllowNull()][string[]]$ArgsList
    )

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add('--config')
    $args.Add('build.rustc-wrapper=""')
    foreach ($arg in @($ArgsList)) {
        if ($null -ne $arg) { $args.Add($arg) }
    }
    return $args.ToArray()
}

function Test-SccacheRustcWrapper {
    <#
    .SYNOPSIS
    Tests whether a rustc-wrapper value resolves to the sccache executable.

    .DESCRIPTION
    Callers may configure RUSTC_WRAPPER as either the command name (`sccache`)
    or an absolute executable path. Comparing only to the command name misses
    repositories that deliberately pin the canonical workstation binary.
    #>
    param(
        [AllowNull()][string]$Wrapper = $env:RUSTC_WRAPPER
    )

    if ([string]::IsNullOrWhiteSpace($Wrapper)) { return $false }

    $wrapperPath = $Wrapper.Trim().Trim('"')
    $wrapperName = [System.IO.Path]::GetFileNameWithoutExtension($wrapperPath)
    return $wrapperName -ieq 'sccache'
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

        if ($flagsWithValue -ccontains $arg) {
            $expectValue = $true
            continue
        }

        if ($flagsNoValue -ccontains $arg) { continue }
        if ($arg -like '--*=*') { continue }
        if ($arg -like '-*' -and $flagsWithValue -cnotcontains $arg -and $flagsNoValue -cnotcontains $arg) {
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

function Insert-ArgSeparatorAt {
    param(
        [string[]]$ArgsList,
        [int]$Index
    )

    $ArgsList = Normalize-ArgsList $ArgsList
    if ($Index -lt 0 -or $Index -ge $ArgsList.Count) { return $ArgsList }

    $result = New-Object System.Collections.Generic.List[string]
    for ($j = 0; $j -lt $Index; $j++) { $result.Add([string]$ArgsList[$j]) }
    $result.Add('--')
    for ($j = $Index; $j -lt $ArgsList.Count; $j++) { $result.Add([string]$ArgsList[$j]) }
    return $result.ToArray()
}

function Ensure-CargoDriverArgSeparator {
    param([string[]]$ArgsList)

    $ArgsList = Normalize-ArgsList $ArgsList
    if (-not $ArgsList -or $ArgsList.Count -eq 0) { return $ArgsList }
    if ($ArgsList -contains '--') { return $ArgsList }

    $primary = Get-PrimaryCommand $ArgsList
    if (-not $primary) { return $ArgsList }

    $rustcExactFlags = @(
        '-A', '-W', '-D', '-F', '-C', '-L', '-l',
        '--cap-lints', '--cfg', '--check-cfg', '--crate-name', '--crate-type',
        '--diagnostic-width', '--edition', '--emit', '--error-format', '--extern',
        '--out-dir', '--remap-path-prefix', '--sysroot', '--target-feature'
    )
    $rustcPrefixFlags = @('-A', '-W', '-D', '-F', '-C', '-L', '-l')
    $testHarnessFlags = @(
        '--bench', '--exact', '--format', '--ignored', '--include-ignored',
        '--list', '--nocapture', '--show-output', '--skip', '--test-threads'
    )

    for ($i = 0; $i -lt $ArgsList.Count; $i++) {
        $arg = $ArgsList[$i]
        if ($i -eq 0 -and $arg -like '+*') { continue }
        if ($arg -eq $primary) { continue }

        if ($primary -in @('clippy', 'rustc')) {
            if ($rustcExactFlags -contains $arg) {
                return Insert-ArgSeparatorAt -ArgsList $ArgsList -Index $i
            }
            foreach ($prefix in $rustcPrefixFlags) {
                if ($arg.StartsWith($prefix) -and $arg.Length -gt $prefix.Length) {
                    return Insert-ArgSeparatorAt -ArgsList $ArgsList -Index $i
                }
            }
        }

        if ($primary -in @('test', 'bench') -and $testHarnessFlags -contains $arg) {
            return Insert-ArgSeparatorAt -ArgsList $ArgsList -Index $i
        }
    }

    return $ArgsList
}
