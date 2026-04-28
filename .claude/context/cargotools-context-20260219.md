# CargoTools Context Save — 2026-02-19

## Schema Version: 2.0
## Context ID: ctx-cargotools-20260219-v060

## Project State

### Summary
CargoTools v0.6.0 is a PowerShell module providing routed Cargo wrappers for Windows, WSL, and Docker with sccache defaults, LLM-friendly diagnostics, memory management, smart build defaults, PATH sanitization, and cross-target helpers. The v0.6.0 release adds smart auto-detection of build tools (lld, nextest, ninja), PATH sanitization to prevent MSVC shadowing, enhanced full-profile auto-copy, and a wrapper deployment script. 249 tests pass with 0 failures.

### Recent Changes (v0.5.0 -> v0.6.0)

**Modified files:**
- `Private/Environment.ps1`: Added `Get-SanitizedPath` (strips Strawberry Perl/Git mingw from PATH), `Get-MsvcClExePath` (absolute MSVC cl.exe resolution), smart defaults (lld/nextest/cmake/makeflags auto-enable), CC/CXX set to absolute paths
- `Private/BuildOutput.ps1`: Added `Copy-SingleFile` (C# accelerator + fallback), `Copy-ProfileDirectory` (extension-based filtering, newer-only, optional examples/), rewrote `Copy-BuildOutputToLocal` for full profile directory copy
- `Tests/Environment.Tests.ps1`: 18 new tests for PATH sanitization, MSVC resolution, smart defaults, preserve-existing-env
- `Tests/Integration.Tests.ps1`: Version check updated to 0.6.0
- `CargoTools.psd1`: Version 0.6.0, expanded FileList with new files
- `CLAUDE.md`: Updated architecture docs, new env vars, Install-Wrappers usage
- `CHANGELOG.md`: Full v0.6.0 release notes

**Created files:**
- `tools/Install-Wrappers.ps1`: Wrapper deployment script (-DryRun, -Force, -Uninstall, .cmd shim generation, PATH validation)
- `Tests/BuildOutput.Tests.ps1`: 28 tests for Copy-SingleFile, Copy-ProfileDirectory, Copy-BuildOutputToLocal, Test-AutoCopyEnabled, Get-PackageNames
- `wrappers/`: 8 canonical wrapper scripts (cargo, cargo-route, cargo-wrapper, cargo-wsl, cargo-docker, cargo-macos, maturin, rust-analyzer-wrapper)

### Work in Progress
None — v0.6.0 is complete and all tests pass.

## Decisions

### dec-001: Shell escaping approach (v0.5.0)
- **Decision**: Whitelist regex `[^A-Za-z0-9_./:=@,+\-]` (shlex.quote style)
- **Rationale**: Blacklist approach missed $, backticks, !, (), &, |, ;, <>, *, ?, ~

### dec-002: Cross-process synchronization (v0.5.0)
- **Decision**: Named system mutex via C# ProcessMutex
- **Rationale**: Multiple LLM agents call cargo simultaneously; prevents sccache startup races

### dec-003: File copy concurrency (v0.5.0)
- **Decision**: C# FileCopy.CopyWithRetry with exponential backoff (3 retries, 100ms base)
- **Rationale**: Concurrent builds sharing CARGO_TARGET_DIR cause file-in-use errors

### dec-004: Smart defaults strategy (v0.6.0)
- **Decision**: Auto-detect and enable lld/nextest/ninja instead of requiring manual env vars
- **Rationale**: Installed tools should be used automatically; users can override with CARGO_USE_LLD=0 etc.
- **Alternatives**: Keep disabled-by-default (rejected: leaves performance on the table)

### dec-005: PATH sanitization approach (v0.6.0)
- **Decision**: Remove known conflicting directories (Strawberry Perl, Git mingw64) from PATH within Initialize-CargoEnv
- **Rationale**: Strawberry's gcc.exe and Git's link.exe shadow MSVC cl.exe/link.exe, causing build failures
- **Alternatives**: Warn only (rejected: silent build failures worse than PATH modification)

### dec-006: Auto-copy rewrite (v0.6.0)
- **Decision**: Replace per-package-name pattern matching with extension-based full profile directory copy
- **Rationale**: Old $CopyPattern parameter was dead code; extension filtering is simpler and more comprehensive
- **Alternatives**: Fix $CopyPattern (rejected: extension-based approach captures all outputs)

### dec-007: Wrapper deployment (v0.6.0)
- **Decision**: Canonical wrapper sources in wrappers/ deployed by tools/Install-Wrappers.ps1
- **Rationale**: Single source of truth; automated deployment with .cmd shim generation

## Current Architecture

### Module Structure
```
CargoTools.psm1          # Module loader
CargoTools.psd1          # Manifest (v0.6.0)
Private/
  Common.ps1             # Shared utils, C# inline types (ShellEscape, ProcessMutex, FileCopy)
  Environment.ps1        # Env setup, PATH sanitization, MSVC resolution, smart defaults, sccache mgmt
  BuildOutput.ps1        # Copy-SingleFile, Copy-ProfileDirectory, Copy-BuildOutputToLocal
  Preflight.ps1          # Pre-build checks (check/clippy/fmt)
  Progress.ps1           # Verbosity system (0-3 + llm), build phases
  LlmOutput.ps1          # AI-friendly output formatting
Public/
  Invoke-CargoRoute.ps1  # Top-level router
  Invoke-CargoWrapper.ps1 # Windows native builds
  Invoke-CargoWsl.ps1    # WSL builds
  Invoke-CargoDocker.ps1 # Docker builds
  Invoke-CargoMacos.ps1  # macOS cross-compile
  Invoke-RustAnalyzerWrapper.ps1 # RA singleton
  Test-RustAnalyzerHealth.ps1    # RA diagnostics
  Install-RustWindowsService.ps1 # Windows service helper
Tests/                   # 8 test files, 249 tests
wrappers/                # 8 canonical wrapper scripts
tools/
  Generate-Help.ps1      # platyPS help generation
  Install-Wrappers.ps1   # Wrapper deployment
```

### Routing Chain
`cargo.ps1` -> `cargo-route.ps1` -> `Invoke-CargoRoute` -> dispatches to:
- `Invoke-CargoWrapper` (Windows native via rustup)
- `Invoke-CargoWsl` (WSL via wsl.exe)
- `Invoke-CargoDocker` (Docker containers)
- `Invoke-CargoMacos` (macOS cross-compile via Docker/zigbuild)

### Build Tool Chain
rustup -> sccache (mutex-protected) -> preflight (check/clippy/fmt) -> build -> auto-copy (full profile)

### Environment
- Cache root: `T:\RustCache` (cargo-home, cargo-target, sccache, rustup, ra-cache)
- sccache port: 4226
- Build jobs: 4 (2 in low-memory)
- lld-link.exe: `C:\Program Files\LLVM\bin\lld-link.exe` (auto-enabled)
- PATH sanitized: Strawberry Perl + Git mingw removed during builds
- CC/CXX: Set to absolute MSVC cl.exe path

## Agent Work Registry

| Agent | Task | Files | Status | Handoff |
|-------|------|-------|--------|---------|
| powershell-pro | v0.5.0 Phases 1-7 | All private/public/test files | Complete | 200 tests pass |
| (main) | v0.6.0 Phase 2: PATH sanitization | Environment.ps1 | Complete | Get-SanitizedPath, Get-MsvcClExePath |
| (main) | v0.6.0 Phase 1: Smart defaults | Environment.ps1 | Complete | lld/nextest/cmake auto-enable |
| (main) | v0.6.0 Phase 3: Enhanced auto-copy | BuildOutput.ps1 | Complete | Full profile directory copy |
| (main) | v0.6.0 Phase 4: Install script | tools/Install-Wrappers.ps1, wrappers/* | Complete | .cmd shim generation |
| (main) | v0.6.0 Phase 6: Tests | Environment.Tests, BuildOutput.Tests | Complete | 46 new tests |
| (main) | v0.6.0 Phase 7: Docs/manifest | psd1, CHANGELOG, CLAUDE.md | Complete | Version 0.6.0 |

## Recommended Next Agents

1. **test-automator**: Integration tests for Install-Wrappers.ps1 deployment
2. **powershell-pro**: Review PS 5.1 compatibility of new functions
3. **security-auditor**: Review PATH sanitization for edge cases
4. **docs-architect**: Regenerate platyPS help for new functions

## Patterns

### Coding Conventions
- PowerShell 5.1 compatible (no PS 7-only features)
- C# inline types for perf-critical ops (Add-Type with PSTypeName guard)
- Private functions in Private/*.ps1, public in Public/*.ps1
- Test with Pester 5.x, access private functions via `& $module { ${function:Name} }`
- Single-quoted strings for Rust error output with backticks

### Testing Strategy
- Unit tests per private module (Common, Environment, BuildOutput)
- Integration tests for module import and cross-function deps
- Error scenario tests for failure paths
- Concurrency tests for mutex, file copy, env isolation
- Background job tests for cross-process synchronization
- Env var save/restore pattern: save in BeforeAll, clear in BeforeEach, restore in AfterAll

## Roadmap

### Tech Debt
- `Install-RustWindowsService.ps1` in Public/ lacks tests
- platyPS help docs not regenerated for new v0.6.0 functions
- wrappers/ scripts could use version header comments

### Future Enhancements
- Evaluate cranelift backend, split-debuginfo, parallel frontend, thin-lto
- Consider making Install-Wrappers.ps1 a public module function
- CI/CD pipeline for automated testing (currently manual)

## Validation
- **Last validated**: 2026-02-19
- **Test results**: 249 passed, 0 failed, 4 skipped
- **Module loads**: Clean import at v0.6.0
