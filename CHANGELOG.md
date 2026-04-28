# Changelog

## 0.9.0
- **Wrapper rewrite**: Replaced 9 ad-hoc wrapper shims with smart, self-healing scripts backed by a shared `wrappers/_WrapperHelpers.psm1` module. Each wrapper is now ≤60 lines of entry-point code.
- **Standardized wrapper flags**: All wrappers now support `--help`, `-h`, `-?`, `/?`, `--version`, `--doctor`, `--diagnose`, `--llm`/`--json-output`, `--list-wrappers`, and `--no-wrapper`. Flags are stripped before forwarding to cargo.
- **LLM JSON envelope**: `--llm` flag emits structured JSON events to stderr (`phase=start/diagnostic/action/end`) with `wrapper`, `wrapper_version`, `timestamp`, `exit_code`, `duration_ms`, and `actions_taken`.
- **Self-healing recovery**: Six failure modes handled with structured codes — `MODULE_NOT_FOUND`, `ONEDRIVE_LOCK` (retry 3x with 200ms backoff), `SCCACHE_DEAD`, `RUSTUP_NOT_FOUND`, `PATH_SHADOWED`, `STALE_MUTEX`.
- **Standardized exit codes**: 0=success, 1=wrapper internal error, 2=module not found, 3=required tool missing (rustup/cargo/maturin/rust-analyzer), 4=config error (--doctor red), ≥128 passed through from cargo.
- **`--doctor` and `--diagnose`**: On-demand environment diagnostic that checks module loadability, PSModulePath, wrapper deployment, PATH, rustup, sccache, lld-link, and OneDrive .psd1 lock risk.
- **Install-Wrappers.ps1 v0.9.0**: Deploys `_WrapperHelpers.psm1` alongside .ps1 wrappers to both `~/.local/bin` and `~/bin`. Added post-deploy verification step that imports the helper and asserts version matches manifest.
- **Pester test suite**: New `Tests/Wrappers.Tests.ps1` covering flag parsing, LlmEvent JSON shape, MODULE_NOT_FOUND recovery, argument pass-through fidelity, per-wrapper --help/--version/--list-wrappers, and --doctor JSON schema.

## Unreleased
- **Queued top-level builds**: Added `Private/BuildQueue.ps1` and public
  `Get-CargoQueueStatus` to serialize top-level Cargo invocations through a
  shared queue. Wrapper status output now reports when a build is queued and
  how deep the queue is, reducing the appearance of random failures during
  concurrent multi-project builds.
- **Shared cache, local outputs**: `Initialize-CargoEnv` now keeps
  `CARGO_HOME`, `RUSTUP_HOME`, and `SCCACHE_DIR` under the shared machine cache
  root while leaving `CARGO_TARGET_DIR` unset by default so project builds use
  normal local `target/` directories unless shared mode is explicitly requested.
- **Machine tuning defaults**: Added machine-config defaults for
  `MaxConcurrentBuilds`, queue polling, stale-ticket cleanup,
  `SCCACHE_CACHE_SIZE`, and `SCCACHE_IDLE_TIMEOUT` so CargoTools can act as a
  single policy point for aggressive sccache reuse.
- **Build output resolution**: Build output copy logic now resolves profile and
  target-triple paths from the current project root and effective Cargo args,
  which preserves normal Cargo layout for debug, release, and cross-target
  builds.

## 0.8.0
- **TOML config infrastructure**: New `Private/ConfigFiles.ps1` with TOML read/write/merge
  primitives (`Read-TomlSections`, `ConvertTo-TomlString`, `Merge-TomlConfig`, `Write-ConfigFile`).
  Merge-not-overwrite strategy preserves user customizations; `.bak` backups on every write.
- **Initialize-RustDefaults**: New public function to generate/update global config files
  (`~/.cargo/config.toml`, `~/rustfmt.toml`, `~/.clippy.toml`). Supports `-Scope`, `-Force`,
  `-PassThru`, and `-WhatIf`. Adds sparse registry, lld-link linker, sccache wrapper, and
  formatting defaults.
- **LLM JSON message format**: When `--llm-output` or `CARGO_VERBOSITY=llm` is active,
  auto-injects `--message-format=json` into build/check/clippy/test/bench commands. New
  `ConvertFrom-CargoJson` parses cargo JSON diagnostics into structured output. New
  `Format-LlmBuildSummary` emits single-line JSON status after builds.
- **Quick-check fast path**: Added `--quick-check` flag and `CARGO_QUICK_CHECK=1` env var to
  rewrite `build` to `check` for fast validation without producing binaries.
- **Preflight cargo-deny**: Added `deny` as a preflight mode (`--preflight-mode deny`) for
  dependency license/advisory auditing. Gracefully skips when `cargo-deny` is not installed.
  Integrated into `all` mode.
- **rust-analyzer memory watchdog**: Added `--memory-limit <MB>` flag and `RA_MEMORY_LIMIT_MB`
  env var. Background job polls every 60s and kills rust-analyzer if memory exceeds the limit.
- **rust-analyzer proc-macro toggle**: Added `--no-proc-macros` flag to set
  `RA_PROC_MACRO_WORKERS=0`, saving ~500MB on large projects.
- **rust-analyzer config generation**: Added `--generate-config` flag to create/merge
  `rust-analyzer.toml` in the current directory with optimal defaults (clippy check, proc-macro
  enabled, cache priming threads).
- **Test-BuildEnvironment enhancements**: Now checks for `~/.cargo/config.toml` (sparse registry)
  and `~/rustfmt.toml` presence. Suggests `Initialize-RustDefaults` when configs are missing.

## 0.7.0
- **Bundled rust-lld support**: Auto-detects `rust-lld.exe` bundled in the active Rust toolchain
  as a fallback when external `lld-link.exe` is not installed. Sets `-C linker-flavor=lld-link`
  RUSTFLAG automatically. No external LLVM install required for fast linking.
- **sccache auto-retry**: When a build fails and sccache is detected as dead (common with
  concurrent LLM agents), automatically restarts sccache and retries the build once before
  reporting failure.
- **CARGO_INCREMENTAL conflict detection**: Warns and resets `CARGO_INCREMENTAL=1` to `0` when
  `RUSTC_WRAPPER=sccache` is active, preventing silently destroyed cache hit rates (sccache#236).
- **Build timings**: Added `--timings` flag and `CARGO_TIMINGS=1` env var to append `--timings`
  to cargo build commands, generating HTML timing reports.
- **Release-optimized builds**: Added `--release-optimized` flag and `CARGO_RELEASE_LTO=1` env
  var to enable thin LTO (`-C lto=thin -C codegen-units=1`) for release builds, producing
  4-20% faster binaries at the cost of longer compile times.
- **Test-BuildEnvironment**: New public diagnostic function that checks Dev Drive (ReFS),
  Windows Defender exclusions, linker availability, sccache health, PATH conflicts, and
  reports optimization opportunities.

## 0.6.0
- **Smart defaults**: `CARGO_USE_LLD` auto-enables when `lld-link.exe` is detected at
  `C:\Program Files\LLVM\bin\lld-link.exe` or via `CARGO_LLD_PATH`. No longer defaults to `'0'`.
- **Smart defaults**: `CARGO_USE_NEXTEST` auto-enables when `cargo-nextest` is found on PATH.
- **Smart defaults**: `CMAKE_GENERATOR` auto-sets to `Ninja` when `ninja` is installed.
- **Smart defaults**: `MAKEFLAGS` and `CMAKE_BUILD_PARALLEL_LEVEL` auto-set to optimal job count
  for native C/C++ dependency builds.
- **PATH sanitization**: Added `Get-SanitizedPath` function that strips Strawberry Perl
  (`C:\Strawberry\c\bin`, `C:\Strawberry\perl\bin`) and Git mingw64 (`\Git\mingw64\bin`,
  `\Git\usr\bin`) from PATH during builds to prevent shadowing MSVC `cl.exe`/`link.exe`.
- **MSVC resolution**: Added `Get-MsvcClExePath` function that resolves the absolute path to
  MSVC `cl.exe`. `CC`/`CXX` env vars now set to absolute paths instead of bare `cl.exe`.
- **Enhanced auto-copy**: Replaced per-package-name pattern matching with full profile directory
  copy. Now copies all `.exe`, `.dll`, `.pdb`, `.lib`, `.rlib`, `.so`, `.dylib`, `.wasm` files
  from the shared profile directory, regardless of package name.
- **Enhanced auto-copy**: Added `Copy-SingleFile` helper with C# `FileCopy` accelerator support.
- **Enhanced auto-copy**: Added `Copy-ProfileDirectory` helper with extension-based filtering,
  newer-only logic, and optional examples/ subdirectory copy.
- **Enhanced auto-copy**: Support `CARGO_AUTO_COPY_EXAMPLES=1` to include examples/ in auto-copy.
- **Install script**: Added `tools/Install-Wrappers.ps1` to deploy wrapper scripts to
  `~/.local/bin/` and `~/bin/` with `.cmd` shim generation and PATH validation.
- **Wrapper sources**: Added `wrappers/` directory containing canonical wrapper script sources.
- Added `Tests/BuildOutput.Tests.ps1` with comprehensive tests for build output copy functions.

## 0.5.0
- **BREAKING**: Removed unconditional TRACE hex dump from Invoke-CargoWrapper. Build output is
  now clean by default. Use `-vv` or `CARGO_VERBOSITY=3` to see argument debug output.
- Fixed `Convert-ArgsToShell` shell escaping: switched from blacklist to whitelist regex.
  Now properly quotes `$`, backticks, `!`, `()`, `&`, `|`, `;`, `<>`, `*`, `?`, `~`, `{}`.
- Fixed WSL argument joining in `Invoke-CargoWsl`: uses `Convert-ArgsToShell` instead of
  bare space-join, preventing argument corruption with special characters.
- Added `--raw`/`--passthrough` mode to `Invoke-CargoWrapper`: bypasses all wrapper behavior
  (no preflight, no env setup, no auto-copy). Also available via `CARGO_RAW=1` env var.
- Added `--nextest`/`--no-nextest` flags and `CARGO_USE_NEXTEST` env var: automatically
  rewrites `cargo test` to `cargo nextest run` when enabled. Graceful fallback if
  cargo-nextest is not installed.
- Added `--llm-output` flag and `CARGO_VERBOSITY=llm` mode: emits single-line JSON status
  messages for LLM agent consumption instead of decorated text.
- Aligned sccache defaults with `.cargo/config.toml`: `SCCACHE_STARTUP_TIMEOUT=30`,
  `SCCACHE_REQUEST_TIMEOUT=180`, `SCCACHE_MAX_CONNECTIONS=8`.
- Fixed `Normalize-ArgsList` type signature: changed from `[object]` to untyped parameter
  to avoid boxing issues.
- Added maturin wrapper (`~/.local/bin/maturin.ps1`) with auto venv detection, sccache
  support, and `--no-sccache` flag.
- Added comprehensive Pester test suite: Common.Tests.ps1, Invoke-CargoWrapper.Tests.ps1,
  Environment.Tests.ps1, Integration.Tests.ps1.

## 0.4.0
- Added preflight build system with configurable check/clippy/fmt modes.
- Added rust-analyzer singleton enforcement via Invoke-RustAnalyzerWrapper.
- Added LLM-friendly output helpers (Format-CargoOutput, ConvertTo-LlmContext, etc.).
- Added build output auto-copy from shared CARGO_TARGET_DIR to local ./target/.
- Added verbosity system (0-3 levels) with progress phase indicators.

## 0.3.0
- Added memory management helper functions to prevent paging file exhaustion:
  - `Initialize-CargoEnv` - Sets sccache, rust-analyzer, and cargo environment with memory-optimized defaults
  - `Start-SccacheServer` - Starts sccache with memory limit monitoring (auto-restart if >2GB)
  - `Stop-SccacheServer` - Gracefully stops sccache server
  - `Get-SccacheMemoryMB` - Returns current sccache memory usage
  - `Get-OptimalBuildJobs` - Returns 2 or 4 build jobs based on available system RAM
- Added rust-analyzer memory optimization settings (RA_LRU_CAPACITY, CHALK_SOLVER_MAX_SIZE)
- Added CARGO_BUILD_JOBS default of 4 to prevent memory exhaustion on large builds
- Added sccache process priority management (BelowNormal) to reduce system impact

## 0.2.1
- Added platyPS-generated external help and docs folder.
- Added argument validation for conflicting flags and env overrides.
- Expanded Pester coverage for invalid argument handling.
- Normalized argument list handling for single-argument invocations.

## 0.2.0
- Split monolithic module into Public/Private functions for SOLID separation.
- Added module loader with explicit exports.
- Added about_CargoTools help and module README.
- Updated wrapper scripts to import CargoTools module.
- Expanded Pester coverage for module import and help.

## 0.1.0
- Initial CargoTools module with routing and wrapper commands.
