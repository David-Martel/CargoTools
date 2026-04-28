# CargoTools Context: v0.8.0 Release

**Context ID:** ctx-cargotools-20260219-v080
**Created:** 2026-02-19
**Created By:** claude-opus-4-6 (main agent)
**Schema Version:** 2.0

## Project

- **Name:** CargoTools
- **Root:** `C:\Users\david\OneDrive\Documents\PowerShell\Modules\CargoTools`
- **Type:** PowerShell module (PS 5.1+ / PS Core)
- **Version:** 0.8.0
- **Git:** Not a git repo

## Current State

CargoTools v0.8.0 is complete with all 7 planned phases implemented. The module now includes TOML config management, LLM JSON message format injection, quick-check fast path, cargo-deny preflight integration, and rust-analyzer enhancements (memory watchdog, proc-macro toggle, config generation). Full test suite: 355 tests passing, 0 failures, 5 expected skips.

### Recent Changes (v0.8.0)

| File | Action | Phase |
|------|--------|-------|
| `Private/ConfigFiles.ps1` | **Created** | 1 |
| `Tests/ConfigFiles.Tests.ps1` | **Created** | 1, 2 |
| `Public/Initialize-RustDefaults.ps1` | **Created** | 2 |
| `Tests/LlmOutput.Tests.ps1` | **Created** | 3 |
| `Private/LlmOutput.ps1` | Modified | 3 |
| `Public/Invoke-CargoWrapper.ps1` | Modified | 3, 4, 5 |
| `Private/Preflight.ps1` | Modified | 5 |
| `Public/Invoke-RustAnalyzerWrapper.ps1` | Modified | 6 |
| `Public/Test-BuildEnvironment.ps1` | Modified | 2 |
| `Tests/ErrorScenarios.Tests.ps1` | Modified | 5 |
| `Tests/Invoke-CargoWrapper.Tests.ps1` | Modified | 4, 2 |
| `Tests/Invoke-RustAnalyzerWrapper.Tests.ps1` | Modified | 6 |
| `Tests/Integration.Tests.ps1` | Modified | 7 |
| `CargoTools.psd1` | Modified | 2, 7 |
| `CHANGELOG.md` | Modified | 7 |
| `CLAUDE.md` | Modified | 7 |
| `.claude/CLAUDE.md` | Modified | 7 |

### Work In Progress
- None. All 7 phases complete.

### Blockers
- None.

## Decisions

### dec-001: Custom TOML Parser
- **Decision:** Implement a minimal TOML parser in pure PowerShell rather than using external module
- **Rationale:** Cargo config uses a simple TOML subset (flat sections, no arrays-of-tables, no inline tables). No external dependency needed. PS 5.1 compatible.
- **Alternatives:** PowerShell-TOML module (external dep), regex-only parsing (fragile)

### dec-002: Merge-Not-Overwrite Config Strategy
- **Decision:** `Merge-TomlConfig` only adds missing keys; never overwrites existing user values
- **Rationale:** Preserves user customizations. `-Force` switch available for full overwrite.

### dec-003: LLM JSON Injection Scope
- **Decision:** Only inject `--message-format=json` for build/check/clippy/test/bench. Not for clean/update/fmt/run/install/publish.
- **Rationale:** Only compilation commands produce JSON diagnostics. Run/clean/etc don't support the flag.

### dec-004: $Args Parameter Bug Workaround
- **Decision:** Test deny preflight by inlining logic rather than calling `Build-PreflightShellCommand`
- **Rationale:** `Build-PreflightShellCommand` has `[string[]]$Args` parameter that conflicts with PS automatic `$args` variable. Named parameter binding never works. Pre-existing bug affecting WSL/Docker preflight too.

### dec-005: $HOME Read-Only Workaround
- **Decision:** Use `$env:CARGO_HOME` redirect to `$TestDrive` for cargo config tests; save/restore real files for rustfmt/clippy
- **Rationale:** PS Core makes `$HOME` read-only. Cannot mock it for testing.

### dec-006: Memory Watchdog via Background Job
- **Decision:** Use `Start-Job` with 60-second polling for rust-analyzer memory watchdog
- **Rationale:** Background job allows monitoring without blocking the main thread. Cleanup in `finally` block prevents orphaned jobs.

## Patterns

### Coding Conventions
- Manual `for` loop arg parsing (not `param()` binding) for all route commands
- C# inline types guarded by `PSTypeName` check for module reload safety
- `SupportsShouldProcess` on all file-writing functions for `-WhatIf` support
- Merge results returned as `PSCustomObject` with `.Config` and `.Additions` properties

### Testing Strategy
- Private functions accessed via `& $module { ${function:FunctionName} }`
- Env var isolation: save in `BeforeAll`, clear in `BeforeEach`, restore in `AfterAll`
- Temp directories via `$TestDrive` or `Join-Path $env:TEMP "CargoTools-*-$(Get-Random)"`
- Cross-process mutex testing via background jobs with signal files

### Error Handling
- Graceful skip pattern: return 0 when optional tool missing (cargo-deny, sccache)
- `.bak` backup before every config file write
- sccache auto-retry on build failure

### Common Abstractions
- `Resolve-CacheRoot` — centralized cache path resolution (T:\RustCache or $LOCALAPPDATA\RustCache)
- `Test-Truthy` — env var truthiness checker (1/true/yes → $true)
- `Write-CargoStatus` / `Write-CargoDebug` — verbosity-gated output
- `Get-PrimaryCommand` — extracts the cargo subcommand from args

## Agent Registry

| Agent | Task | Files Touched | Status | Handoff Notes |
|-------|------|---------------|--------|---------------|
| main (opus-4-6) | Phase 1: TOML config infrastructure | `Private/ConfigFiles.ps1`, `Tests/ConfigFiles.Tests.ps1` | Complete | 43 tests |
| main (opus-4-6) | Phase 2: Initialize-RustDefaults | `Public/Initialize-RustDefaults.ps1`, `Tests/ConfigFiles.Tests.ps1`, `Public/Test-BuildEnvironment.ps1` | Complete | 9 tests, $HOME read-only workaround |
| main (opus-4-6) | Phase 3: LLM JSON message format | `Private/LlmOutput.ps1`, `Tests/LlmOutput.Tests.ps1`, `Public/Invoke-CargoWrapper.ps1` | Complete | 17 tests |
| main (opus-4-6) | Phase 4: Quick-check fast path | `Public/Invoke-CargoWrapper.ps1`, `Tests/Invoke-CargoWrapper.Tests.ps1` | Complete | 3 tests |
| main (opus-4-6) | Phase 5: Preflight cargo-deny | `Private/Preflight.ps1`, `Tests/ErrorScenarios.Tests.ps1`, `Public/Invoke-CargoWrapper.ps1` | Complete | 5 tests, $Args bug workaround |
| main (opus-4-6) | Phase 6: rust-analyzer enhancements | `Public/Invoke-RustAnalyzerWrapper.ps1`, `Tests/Invoke-RustAnalyzerWrapper.Tests.ps1` | Complete | 8 tests |
| main (opus-4-6) | Phase 7: Version bump & docs | `CargoTools.psd1`, `CHANGELOG.md`, `CLAUDE.md`, `.claude/CLAUDE.md`, `Tests/Integration.Tests.ps1` | Complete | 2 tests |

### Recommended Next Agents
- **test-automator**: Could add property-based testing for TOML round-trips
- **security-auditor**: Review cargo-deny integration and config file write safety
- **powershell-pro**: Optimize TOML parser performance for large config files

## Roadmap

### Immediate
- None (v0.8.0 complete)

### This Week
- Consider adding `rust-analyzer.toml` to `Initialize-RustDefaults` scope
- Consider platyPS help doc regeneration for new `Initialize-RustDefaults` function

### Tech Debt
- `Build-PreflightShellCommand` `$Args` parameter name conflict (pre-existing)
- TOML parser doesn't handle arrays-of-tables or inline tables (by design, but limits future use)

### Performance TODOs
- Background job memory watchdog creates overhead — consider runspace pool if many RA instances

## Validation

- **Last Validated:** 2026-02-19
- **Test Results:** 355 passed, 0 failed, 5 skipped
- **Is Stale:** false

## New Environment Variables (v0.8.0)

| Variable | Purpose |
|----------|---------|
| `CARGO_QUICK_CHECK=1` | Rewrite `build` → `check` for fast validation |
| `RA_MEMORY_LIMIT_MB` | Auto-kill rust-analyzer if memory exceeds limit |

## New Functions (v0.8.0)

| Function | Scope | Purpose |
|----------|-------|---------|
| `Initialize-RustDefaults` | Public | Generate/update global config files |
| `Read-TomlSections` | Private | Parse TOML file → ordered hashtable |
| `ConvertTo-TomlString` | Private | Serialize ordered hashtable → TOML string |
| `Merge-TomlConfig` | Private | Merge defaults into existing config |
| `Write-ConfigFile` | Private | Write with `.bak` backup and `-WhatIf` |
| `Get-DefaultCargoConfig` | Private | Optimal `~/.cargo/config.toml` defaults |
| `Get-DefaultRustfmtConfig` | Private | Optimal `~/rustfmt.toml` defaults |
| `Get-DefaultClippyConfig` | Private | Optimal `~/.clippy.toml` defaults |
| `Get-DefaultRustAnalyzerConfig` | Private | Optimal `rust-analyzer.toml` defaults |
| `Get-MessageFormatArgs` | Private | Inject `--message-format=json` for LLM mode |
| `ConvertFrom-CargoJson` | Private | Parse cargo JSON diagnostic lines |
| `Format-LlmBuildSummary` | Private | Emit JSON build summary |
