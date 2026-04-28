# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Agent-Specific Development Context

This supplements the root `CLAUDE.md` with patterns and conventions for AI agents working on CargoTools.

## Testing Patterns

### Accessing Private Functions in Tests

Private functions (in `Private/*.ps1`) aren't exported. Tests access them via module scope injection:

```powershell
BeforeAll {
    $modulePath = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $modulePath 'CargoTools.psd1') -Force
    $module = Get-Module CargoTools

    # Capture private functions for testing
    $script:ResolveCacheRoot = & $module { ${function:Resolve-CacheRoot} }
    $script:GetSanitizedPath = & $module { ${function:Get-SanitizedPath} }
}

# Call them with:
& $script:ResolveCacheRoot
```

### Environment Variable Isolation

Tests that call `Initialize-CargoEnv` or modify env vars must save/restore state:

```powershell
BeforeAll {
    $script:SavedEnv = @{}
    @('CARGO_USE_LLD', 'CC', 'CXX', 'PATH', 'CARGO_PREFLIGHT_MODE') | ForEach-Object {
        if (Test-Path "Env:$_") { $script:SavedEnv[$_] = (Get-Item "Env:$_").Value }
    }
}
BeforeEach {
    # Clear vars that could leak between tests
    Remove-Item Env:CARGO_PREFLIGHT_MODE -ErrorAction SilentlyContinue
}
AfterAll {
    foreach ($entry in $script:SavedEnv.GetEnumerator()) {
        Set-Item -Path ("Env:" + $entry.Key) -Value $entry.Value
    }
}
```

### Cross-Process Mutex Testing

Named mutexes are re-entrant within the same thread. To test contention, use background jobs with signal file coordination:

```powershell
$signalFile = Join-Path $TestDrive 'ready.signal'
$job = Start-Job -ScriptBlock {
    $handle = [CargoTools.ProcessMutex]::TryAcquire('TestMutex', 30000)
    Set-Content -Path $using:signalFile -Value 'locked'
    Start-Sleep -Seconds 5
    $handle.Dispose()
}
# Wait for signal file before attempting acquire in main thread
```

## C# Inline Types

Defined in `Private/Common.ps1`. These persist in the AppDomain across module reloads — the `PSTypeName` guard prevents `Add-Type` failures on reload:

```powershell
if (-not ([System.Management.Automation.PSTypeName]'CargoTools.ShellEscape').Type) {
    Add-Type -TypeDefinition @'...'@ -Language CSharp -ErrorAction SilentlyContinue
}
```

**If you modify C# type definitions, the user must restart their PowerShell session.** The types cannot be unloaded from the AppDomain. Always note this when making C# changes.

Types:
- `CargoTools.ShellEscape` — `QuoteArg(string)`, `JoinArgs(string[])` — whitelist-based shell escaping
- `CargoTools.ProcessMutex` — `TryAcquire(name, timeoutMs)` returns `MutexHandle` (IDisposable) or null
- `CargoTools.FileCopy` — `CopyWithRetry(source, dest, maxRetries, retryDelayMs)` returns `CopyResult`

## Argument Parsing Pattern

All four route commands use a manual `for` loop to parse CLI-style flags, NOT PowerShell `param()` binding. This is intentional — it allows mixing wrapper-specific flags (`--use-lld`, `--preflight-mode`) with pass-through cargo arguments:

```powershell
for ($i = 0; $i -lt $rawArgs.Count; $i++) {
    $arg = $rawArgs[$i]
    switch ($arg) {
        '--preflight-mode' {
            $i++  # consume next arg as value
            $state.Mode = $rawArgs[$i]; continue
        }
        '--use-lld' { $useLld = $true; continue }
        default { $passThrough.Add($arg); continue }
    }
}
```

Flags with values (like `--preflight-mode check`) increment `$i` to consume the next argument. Boolean flags just set a variable. Everything else goes into `$passThrough` for cargo.

## Cargo Build Context

CargoTools wraps `cargo` — the Rust build system. Key concepts for understanding the codebase:

- **Target triples** like `x86_64-pc-windows-msvc`, `x86_64-unknown-linux-gnu`, `wasm32-unknown-unknown`, `aarch64-apple-darwin` determine which platform a build targets. CargoTools routes to the appropriate build environment based on the triple
- **sccache** is a shared compilation cache (like ccache for C). It wraps `rustc` via `RUSTC_WRAPPER=sccache`. Incremental compilation (`CARGO_INCREMENTAL=1`) is incompatible — it prevents sccache from caching
- **lld-link** is LLVM's linker, 2-5x faster than MSVC's `link.exe`. Available externally (LLVM install) or bundled as `rust-lld` in the Rust toolchain since ~1.70
- **cargo-nextest** is a faster test runner that replaces `cargo test` — runs tests in separate processes with better parallelism and output
- **CARGO_TARGET_DIR** sets the shared build artifact directory. CargoTools points this at `T:\RustCache\cargo-target` so multiple projects share cached dependencies
- **Cargo profiles** (debug, release, custom) determine optimization levels. `--release` maps to the `release` profile. The auto-copy system uses the profile name to find the right output directory

## TOML Config Pattern

`Private/ConfigFiles.ps1` provides a minimal TOML parser for cargo/rustfmt/clippy/rust-analyzer config files. Key functions:

- `Read-TomlSections -Path` — returns `[ordered]@{ 'section' = [ordered]@{ key = value } }`
- `ConvertTo-TomlString -Data -Header` — serializes back to TOML string
- `Merge-TomlConfig -Existing -Defaults` — returns `PSCustomObject` with `.Config` (merged ordered dict) and `.Additions` (string list of changes)
- `Write-ConfigFile -Path -Content` — writes with `.bak` backup, supports `-WhatIf`
- `Get-Default*Config` — returns optimal defaults for cargo, rustfmt, clippy, rust-analyzer

The TOML parser handles flat sections (`[section]` and `[section.subsection]`), quoted strings, booleans, integers, and comments. It does NOT handle arrays-of-tables, inline tables, or multi-line strings.

## Test Suite Summary

10 test files, ~350 tests total. 5 expected skips:
1. sccache not running (skips sccache-dependent tests)
2. `T:` drive not present (cache root fallback test)
3. `VCINSTALLDIR` not set (MSVC path resolution test)
4. rust-analyzer singleton integration (requires process management)
5. cargo-deny installed (skips absent-case test)

## Version History Context

The module evolved through clear phases:
- **v0.1-0.2**: Basic routing and module structure
- **v0.3**: Memory management (sccache limits, build job optimization)
- **v0.4**: Preflight system, rust-analyzer singleton, LLM output, verbosity
- **v0.5**: Shell escaping rewrite, raw/passthrough mode, nextest, maturin wrapper
- **v0.6**: Smart defaults (auto-detect lld/nextest/ninja), PATH sanitization, enhanced auto-copy, wrapper deployment
- **v0.7**: Bundled rust-lld, sccache auto-retry, CARGO_INCREMENTAL conflict detection, build timings, release LTO, Test-BuildEnvironment
- **v0.8**: TOML config management, Initialize-RustDefaults, LLM JSON message format, quick-check, cargo-deny preflight, rust-analyzer memory watchdog/config generation
