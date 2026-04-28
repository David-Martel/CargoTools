# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

CargoTools is a PowerShell module (v0.8.0) that wraps `cargo` for Windows, WSL, and Docker builds with automatic sccache integration, smart tool detection, LLM-friendly diagnostics, cross-target routing, and global config management. Requires PowerShell 5.1+ (Desktop and Core).

## Build & Test Commands

```powershell
Import-Module CargoTools -Force

# Full test suite (~350 tests, ~2 minutes, 5 expected skips)
Invoke-Pester -Path .\Tests\ -Output Detailed

# Single test file
Invoke-Pester -Path .\Tests\Environment.Tests.ps1 -Output Detailed

# Integration tests only (may kill rust-analyzer processes)
Invoke-Pester -Path .\Tests\ -TagFilter 'Integration' -Output Detailed

# Regenerate platyPS help docs
.\tools\Generate-Help.ps1

# Deploy wrapper scripts
.\tools\Install-Wrappers.ps1          # Deploy to ~/bin and ~/.local/bin
.\tools\Install-Wrappers.ps1 -DryRun  # Preview only
```

## Architecture

### Routing Chain

```
cargo.ps1 -> cargo-route.ps1 -> Invoke-CargoRoute
                                      |
                   +------------------+------------------+
                   |                  |                  |
          Invoke-CargoWrapper  Invoke-CargoWsl  Invoke-CargoDocker
          (Windows/MSVC)       (WSL/bash -lc)   (Docker container)
                                                        |
                                                Invoke-CargoMacos
                                                (zigbuild for Apple)
```

`Invoke-CargoRoute` classifies `--target` triples via `Classify-Target` and dispatches: windows targets go to `Invoke-CargoWrapper`, linux/gnu/musl to `Invoke-CargoWsl`, apple to `Invoke-CargoMacos` (Docker+zigbuild), wasm defaults to WSL. All four commands parse raw CLI-style flags (`--route`, `--wsl-native`, `--sccache`, etc.) in a manual `for` loop, not via PowerShell parameter binding.

### Build Pipeline (Invoke-CargoWrapper)

1. **Parse wrapper flags** — strips `--use-lld`, `--preflight`, `--nextest`, `--raw`, etc. from args
2. **Raw mode check** — `--raw`/`CARGO_RAW=1` bypasses everything, runs bare `rustup run stable cargo`
3. **Initialize-CargoEnv** — sets ~30 env vars (sccache, MSVC cl.exe, PATH sanitization, smart defaults for lld/nextest/ninja/cmake)
4. **Linker resolution** — `Resolve-LldLinker` checks: explicit path > external lld-link > bundled rust-lld in toolchain
5. **Start-SccacheServer** — mutex-protected startup, health check, memory limit enforcement
6. **Preflight** — optional check/clippy/fmt before build (IDE-aware suppression)
7. **Nextest rewrite** — `cargo test` transparently becomes `cargo nextest run` when enabled
8. **Build** — `rustup run stable cargo @args` (never bare `cargo`)
9. **Sccache auto-retry** — if build fails and sccache is dead, restart and retry once
10. **Auto-copy** — copies build outputs from shared `T:\RustCache\cargo-target` to local `./target/`

### Module Layout

- `CargoTools.psm1` — dot-sources `Private/*.ps1` then `Public/*.ps1`, exports via `Export-ModuleMember`
- `CargoTools.psd1` — manifest; `FunctionsToExport` and `FileList` must stay in sync with `.psm1`
- `Private/Common.ps1` — C# inline types (`ShellEscape`, `ProcessMutex`, `FileCopy`) + shared utilities (`Test-Truthy`, `Normalize-ArgsList`, `Classify-Target`, `Convert-ArgsToShell`)
- `Private/Environment.ps1` — `Initialize-CargoEnv`, cache root resolution, PATH sanitization, MSVC resolution, sccache management, lld resolution, smart defaults
- `Private/Preflight.ps1` — preflight arg parsing, IDE guard, local/shell command generation
- `Private/BuildOutput.ps1` — extension-based profile directory copy with C# retry accelerator
- `Private/Progress.ps1` — verbosity system (0-3 + llm), build phases, diagnostics formatting
- `Private/LlmOutput.ps1` — AI-friendly structured output (JSON status, context snapshots, cargo JSON parsing)
- `Private/ConfigFiles.ps1` — TOML read/write/merge primitives, default config generators

### Key Design Decisions

- **All builds use `rustup run stable cargo`** — never bare `cargo`, ensures consistent toolchain
- **Shared cache at `T:\RustCache`** (ReFS Dev Drive) with `$LOCALAPPDATA\RustCache` fallback — contains `cargo-home`, `cargo-target`, `sccache`, `rustup`, `ra-cache`
- **Smart defaults auto-enable tools** — lld-link (external or bundled rust-lld), nextest, Ninja for CMake, MAKEFLAGS for parallel native deps. Users override with `CARGO_USE_*=0`
- **PATH sanitization** — `Get-SanitizedPath` strips Strawberry Perl and Git mingw64 directories that shadow MSVC cl.exe/link.exe
- **C# inline types for perf-critical code** — `Add-Type` with `PSTypeName` guard to survive module reloads (types persist in AppDomain)
- **Cross-process mutex** for sccache startup — prevents race conditions when multiple LLM agents invoke cargo simultaneously
- **CARGO_INCREMENTAL=0 enforced with sccache** — `CARGO_INCREMENTAL=1` silently destroys sccache hit rates (sccache#236)
- **rust-analyzer singleton** — mutex + atomic lock file, memory optimization env vars (`RA_LRU_CAPACITY=64`)

### Adding a New Public Function

1. Create `Public/YourFunction.ps1`
2. Add function name to `FunctionsToExport` in `CargoTools.psd1`
3. If it's a helper (not a main command), also add to `$helperFunctions` in `CargoTools.psm1`
4. Add to `FileList` in `CargoTools.psd1`
5. Add Pester tests in `Tests/`

## Development Gotchas

- **Private function testing**: Access via `& $module { ${function:FunctionName} }` where `$module = Get-Module CargoTools`
- **C# types persist across reloads**: `Add-Type` types survive `Import-Module -Force`. Guard with `if (-not ([PSTypeName]'CargoTools.ShellEscape').Type)`. If changing C# code, restart the PowerShell session
- **Backtick in double-quoted strings**: PS escapes `` `" `` as closing quote. Rust error messages containing backticks (`` `x` ``) must use single-quoted strings in tests
- **Named mutexes are re-entrant**: Windows named mutexes allow the same thread to acquire twice. Test cross-process contention using background jobs with signal file coordination
- **Env var test isolation**: Save env in `BeforeAll`, clear in `BeforeEach`, restore in `AfterAll`. Clear `CARGO_PREFLIGHT_MODE` explicitly — it can override preflight defaults
- **Initialize-CargoEnv sets RUSTC_WRAPPER**: Auto-sets `RUSTC_WRAPPER=sccache` if sccache is on PATH. Tests for env vars that interact with sccache must account for this
- **Pester assertions**: Use `-Match` (regex) instead of `-BeLike` (glob) when matching literal `[` brackets. Avoid `Should -Be` with inline string concatenation on piped values — assign to a variable first
- **`[Math]::Round(10.0, 2)` returns `10` not `10.00`**: Regex patterns matching formatted numbers must handle optional decimal places

## Environment Variables

**Routing**: `CARGO_ROUTE_DEFAULT` (auto|windows|wsl|docker), `CARGO_ROUTE_WASM`, `CARGO_ROUTE_MACOS`, `CARGO_ROUTE_DISABLE`
**WSL**: `CARGO_WSL_CACHE` (shared|native), `CARGO_WSL_SCCACHE`
**Docker**: `CARGO_DOCKER_SCCACHE`, `CARGO_DOCKER_ZIGBUILD`
**Preflight**: `CARGO_PREFLIGHT`, `CARGO_PREFLIGHT_MODE` (check|clippy|fmt|deny|all), `CARGO_PREFLIGHT_STRICT`, `CARGO_PREFLIGHT_BLOCKING`, `CARGO_PREFLIGHT_IDE_GUARD`, `CARGO_PREFLIGHT_FORCE`, `CARGO_RA_PREFLIGHT`
**Build**: `CARGO_USE_LLD`, `CARGO_USE_NATIVE`, `CARGO_USE_FASTLINK`, `CARGO_AUTO_COPY`, `CARGO_AUTO_COPY_EXAMPLES`, `CARGO_VERBOSITY` (0-3|llm)
**Quick-check**: `CARGO_QUICK_CHECK=1` (rewrite build to check for fast validation)
**Passthrough**: `CARGO_RAW=1` (bypass all wrapper behavior)
**Nextest**: `CARGO_USE_NEXTEST` (auto-enables when cargo-nextest installed)
**Timings**: `CARGO_TIMINGS=1` (HTML build timing report)
**Release LTO**: `CARGO_RELEASE_LTO=1` (thin LTO + codegen-units=1)
**rust-analyzer**: `RA_MEMORY_LIMIT_MB` (auto-kill RA if memory exceeds limit)
**Diagnostics**: `Test-BuildEnvironment` reports Dev Drive, Defender exclusions, linker, sccache, tool availability, config files
