# CargoTools Wrappers Reference

Complete CLI reference for the wrapper scripts deployed by `tools/Install-Wrappers.ps1`. These shims sit on `PATH` (in `~/bin` and `~/.local/bin`) and forward into the `CargoTools` PowerShell module.

This document describes the **rewritten wrapper surface** introduced in 0.9.0: a unified set of wrapper-level flags (`--help`, `--version`, `--doctor`, `--diagnose`, `--llm`, `--list-wrappers`, `--no-wrapper`), standardized exit codes, and a structured JSON envelope for LLM agents.

For module-level architecture, see [`../CLAUDE.md`](../CLAUDE.md). For error remediation, see [`troubleshooting.md`](troubleshooting.md).

## Table of Contents

- [Overview](#overview)
- [Common Wrapper Flags](#common-wrapper-flags)
- [Standardized Exit Codes](#standardized-exit-codes)
- [JSON Envelope (--llm)](#json-envelope---llm)
- [Wrapper: cargo](#wrapper-cargo)
- [Wrapper: cargo-wrapper](#wrapper-cargo-wrapper)
- [Wrapper: cargo-route](#wrapper-cargo-route)
- [Wrapper: cargo-wsl](#wrapper-cargo-wsl)
- [Wrapper: cargo-docker](#wrapper-cargo-docker)
- [Wrapper: cargo-macos](#wrapper-cargo-macos)
- [Wrapper: maturin](#wrapper-maturin)
- [Wrapper: rust-analyzer](#wrapper-rust-analyzer)
- [Wrapper: rust-analyzer-wrapper](#wrapper-rust-analyzer-wrapper)
- [Environment Variable Reference](#environment-variable-reference)
- [Cross-Platform Notes](#cross-platform-notes)

## Overview

CargoTools deploys nine PowerShell wrappers plus their `.cmd` shims:

| Wrapper | Location | Purpose |
|---|---|---|
| `cargo` | `~/.local/bin` | Primary cargo entry point. Forwards to `cargo-route` for target-aware dispatch. |
| `cargo-route` | `~/.local/bin` | Classifies `--target` triples and dispatches to one of the four backend wrappers. |
| `cargo-wrapper` | `~/.local/bin`, `~/bin` | Direct Windows/MSVC backend. sccache, lld, preflight, auto-copy. |
| `cargo-wsl` | `~/.local/bin` | Linux/musl backend via `wsl bash -lc`. |
| `cargo-docker` | `~/.local/bin` | Container backend (rust:slim image). |
| `cargo-macos` | `~/.local/bin` | Apple cross-compile via Docker + cargo-zigbuild. |
| `maturin` | `~/.local/bin` | Python wheel builder with sccache + venv detection. |
| `rust-analyzer` | `~/.local/bin` | Default rust-analyzer shim with singleton enforcement. |
| `rust-analyzer-wrapper` | `~/.local/bin` | Direct singleton launcher with memory-limit watchdog. |

Two helper modules ride alongside: `~/bin/_WrapperHelpers.psm1` and `~/.local/bin/_WrapperHelpers.psm1`. They define `Resolve-CargoToolsModule`, `Invoke-WrapperWithEnvelope`, and the JSON-envelope writer used by every wrapper.

### Decision tree: which wrapper do I invoke?

```text
Is this a Rust build/check/test/clippy/run?
|
+- yes -> cargo (default; auto-routes by --target)
|
+- I want to skip routing entirely
|     -> cargo-wrapper (Windows MSVC build, no routing layer)
|
+- I want a specific backend
|     -> cargo-wsl   (Linux/musl)
|     -> cargo-docker (containerized; gnu/musl/freebsd)
|     -> cargo-macos  (Apple cross via zigbuild)
|
+- Python wheel (PyO3, maturin)
|     -> maturin
|
+- Editor LSP / diagnostics
|     -> rust-analyzer (interactive)
|     -> rust-analyzer-wrapper (CI / batch / explicit memory limits)
```

## Common Wrapper Flags

These flags are recognised by **all** CargoTools wrappers. They are intercepted before any cargo arguments are forwarded, so they never reach the underlying `cargo`/`maturin`/`rust-analyzer` binary.

| Flag | Behaviour | Output | Exit |
|---|---|---|---|
| `--help`, `-h`, `-?`, `/?` | Subcommand-aware help: emits wrapper help, then merges native cargo help if a cargo subcommand is detected (e.g. `cargo build --help`). | stdout (text) | 0 |
| `--version` | Prints wrapper script version, `CargoTools` module version, `cargo --version`, `rustc --version`. | stdout (text) | 0 |
| `--doctor` | Full environment diagnostic. Delegates to [`Test-BuildEnvironment`](../Public/Test-BuildEnvironment.ps1) plus wrapper-layer checks (PATH, OneDrive, mutex liveness). | stdout (text) | 0 healthy / 4 misconfigured |
| `--diagnose` | Same checks as `--doctor`, JSON output only (machine-readable). | stdout (JSON) | 0 / 4 |
| `--llm`, `--json-output` | Activates JSON envelope on stderr for the lifetime of the invocation. Cargo output continues on stdout. | stderr (NDJSON) | passthrough |
| `--list-wrappers` | Enumerates installed CargoTools wrappers from `~/bin` and `~/.local/bin`, with version + path. | stdout (text or JSON if `--llm`) | 0 |
| `--no-wrapper` | Equivalent to `CARGO_RAW=1`. Bypass all wrapper behaviour and invoke the underlying tool directly. | passthrough | passthrough |

Notes:
- `--llm` is composable with all other wrapper flags. `cargo --doctor --llm` emits a JSON envelope summarising every check.
- `--no-wrapper` is honoured *before* env-var setup, so `RUSTC_WRAPPER`, `CARGO_TARGET_DIR`, and the like are never injected.

## Standardized Exit Codes

Every wrapper uses the same exit-code policy:

| Code | Meaning | Recovery |
|---|---|---|
| 0 | Success. | --- |
| 1 | Wrapper internal error (bug, unhandled exception). | File a bug; rerun with `--llm` for envelope. |
| 2 | `CargoTools` module not found / not loadable. | `Install-Module CargoTools` or check `PSModulePath`. See [`troubleshooting.md`](troubleshooting.md#module_not_found). |
| 3 | Required external tool missing (`rustup`, `cargo`, `maturin`, `rust-analyzer`). | Install the missing tool. See [`troubleshooting.md`](troubleshooting.md#rustup_not_found). |
| 4 | Configuration error: `--doctor` reports red. | Run `--doctor` to see the offending check; fix and retry. |
| 5..127 | Reserved for future wrapper conditions; not currently issued. | --- |
| ≥128 | Native exit code from cargo, maturin, or rust-analyzer. Passed through unchanged. | Treat as native failure (linker, compile, test failure, etc.). |

Cargo's own non-zero exits (101 for compile failure, etc.) are **passed through unchanged**. The wrapper never overrides a real cargo exit code.

## JSON Envelope (`--llm`)

When `--llm` (or `--json-output`, or `CARGO_VERBOSITY=llm`) is active, each wrapper emits **one JSON object per stderr line** (NDJSON). Cargo stdout is unaffected — agents can consume both streams independently.

### Schema

```json
{"phase":"start","wrapper":"cargo","wrapper_version":"0.9.0","args":["build","--release"],"timestamp":"2026-04-28T18:42:01Z"}
{"phase":"diagnostic","level":"warn","code":"PATH_SHADOWED","detail":"C:\\Strawberry\\c\\bin precedes MSVC on PATH","recovery":"Remove or reorder PATH entries"}
{"phase":"action","name":"restarted-sccache","detail":"sccache was unreachable; restarted on port 4400"}
{"phase":"end","exit_code":0,"duration_ms":12483,"wrapper":"cargo","actions_taken":["restarted-sccache"]}
```

### Phase definitions

| Phase | Required fields | Optional fields |
|---|---|---|
| `start` | `wrapper`, `wrapper_version`, `args` (string[]), `timestamp` (ISO 8601 UTC) | `module_version`, `cwd` |
| `diagnostic` | `level` (`info`/`warn`/`error`), `code`, `detail` | `recovery`, `path` |
| `action` | `name` | `detail`, `target`, `result` |
| `end` | `exit_code` (int), `duration_ms` (int), `wrapper` | `actions_taken` (string[]), `error_code` |

### Annotated transcript

A successful release build that survives an sccache hiccup:

```text
$ cargo build --release --llm
{"phase":"start","wrapper":"cargo","wrapper_version":"0.9.0","args":["build","--release"],"timestamp":"2026-04-28T18:42:01Z"}
{"phase":"diagnostic","level":"info","code":"ROUTE_SELECTED","detail":"target=x86_64-pc-windows-msvc -> windows backend"}
{"phase":"diagnostic","level":"warn","code":"SCCACHE_DEAD","detail":"sccache server unreachable on 127.0.0.1:4400","recovery":"Restarting server"}
{"phase":"action","name":"restarted-sccache","detail":"sccache restarted; build will retry"}
   Compiling mycrate v0.1.0
    Finished `release` profile [optimized] in 8.42s
{"phase":"end","exit_code":0,"duration_ms":8421,"wrapper":"cargo","actions_taken":["restarted-sccache"]}
```

## Wrapper: cargo

**Synopsis:** `cargo [<wrapper-flags>] [<cargo-args>]`

The default user-facing entry point. Forwards into `Invoke-CargoRoute`, which classifies any `--target` triple and dispatches to the matching backend (`Invoke-CargoWrapper`, `Invoke-CargoWsl`, `Invoke-CargoDocker`, `Invoke-CargoMacos`).

**Use case:** day-to-day Rust work. `cargo build`, `cargo test`, `cargo clippy`, `cargo run`. Routing happens automatically based on the target triple; if no target is given, the host triple is assumed.

**Routing flags** (consumed by `cargo-route`):

| Flag | Purpose |
|---|---|
| `--route <auto\|windows\|wsl\|docker>` | Force a specific backend regardless of target. |
| `--no-route` | Bypass routing entirely; run native `cargo` from `rustup`. |
| `--route-wasm <windows\|wsl\|docker>` | Override default backend for `wasm32-*` targets. |
| `--route-macos <wsl\|docker>` | Override default backend for `*-apple-darwin` targets. |
| `--wsl-native` | When routed to WSL, use `~/.cargo` + `~/.rustup` inside the distro instead of the shared cache. |
| `--wsl-shared` | Force shared cache mode for WSL backend. |
| `--wsl-sccache` / `--wsl-no-sccache` | Toggle sccache inside WSL. |
| `--docker-sccache` / `--docker-no-sccache` | Toggle sccache inside the Docker container. |
| `--docker-zigbuild` / `--docker-no-zigbuild` | Force/disable cargo-zigbuild for Apple cross. |

**Env vars consumed:** `CARGO_ROUTE_DEFAULT`, `CARGO_ROUTE_WASM`, `CARGO_ROUTE_MACOS`, `CARGO_ROUTE_DISABLE`, `CARGO_WSL_CACHE`, `CARGO_WSL_SCCACHE`, `CARGO_DOCKER_SCCACHE`, `CARGO_DOCKER_ZIGBUILD`, plus everything consumed by the dispatched backend.

**Examples:**

```powershell
PS C:\> cargo build --release
PS C:\> cargo --route wsl test --target x86_64-unknown-linux-gnu
PS C:\> cargo --no-route --version
PS C:\> cargo --doctor
PS C:\> cargo --llm build --release 2> build.ndjson
```

**Exit codes:** standard wrapper exit codes (above). Routing failure -> 4. Cargo failures -> passthrough.

## Wrapper: cargo-wrapper

**Synopsis:** `cargo-wrapper [<wrapper-flags>] [<cargo-args>]`

Direct Windows/MSVC backend. This is the wrapper invoked by `cargo-route` when the target classifies as Windows. Use it directly when you want to skip the routing layer (for example, you know you're never cross-compiling).

**What it does:**

1. Strips wrapper-only flags (the table below) from `args`.
2. Resolves the cache root (`T:\RustCache`, falling back to `$LOCALAPPDATA\RustCache`).
3. Calls `Initialize-CargoEnv`: sets ~30 environment variables for sccache, MSVC, lld, ninja, etc.
4. Resolves and applies the linker (external `lld-link`, bundled `rust-lld`, or default `link.exe`).
5. Starts (or reuses) sccache via cross-process mutex.
6. Runs preflight (`check`/`clippy`/`fmt`/`deny`) if enabled.
7. Rewrites `cargo test` -> `cargo nextest run` if cargo-nextest is installed.
8. Executes `rustup run <toolchain> cargo @args`.
9. On failure with sccache dead, restarts sccache and retries once.
10. Auto-copies build outputs from shared `CARGO_TARGET_DIR` to local `./target/` if applicable.

**Wrapper-only flags:**

| Flag | Default | Effect |
|---|---|---|
| `--raw`, `--passthrough` | off | Bypass everything; run bare `rustup run <toolchain> cargo`. |
| `--use-lld` / `--no-lld` | auto-detect | Toggle LLVM lld linker. |
| `--use-native` / `--no-native` | off | Toggle `-C target-cpu=native`. |
| `--fastlink` / `--no-fastlink` | off | Toggle MSVC `/DEBUG:FASTLINK`. |
| `--llm-debug` | off | Set `RUST_BACKTRACE=full`, `CARGO_TERM_COLOR=always`, debuginfo=1, verbosity=3. |
| `--auto-copy` / `--no-auto-copy` | auto | Force/skip local output copy from shared target dir. |
| `--preflight` | off | Run `cargo check` before build. |
| `--preflight-mode <check\|clippy\|fmt\|deny\|all>` | check | Preflight type. |
| `--preflight-ra` | off | Run rust-analyzer diagnostics before build. |
| `--preflight-strict` | off | Treat clippy warnings as errors during preflight. |
| `--preflight-blocking` / `--preflight-nonblocking` | blocking | Whether preflight failures abort the build. |
| `--preflight-force` | off | Force preflight even when an IDE context is detected. |
| `--fix` | off (auto-on with quality gate) | Auto-apply clippy + fmt fixes during preflight. |
| `--quick-check` / `--no-quick-check` | off | Rewrite `build` -> `check` for fast validation. |
| `--nextest` / `--no-nextest` | auto | Force or skip cargo-nextest test runner. |
| `--timings` / `--no-timings` | off | Append `--timings` for HTML build report. |
| `--release-optimized` | off | Add thin LTO + codegen-units=1 for release builds. |
| `--llm-output` | off | Emit per-line JSON status (alias of `--llm` for compatibility). |
| `--wrapper-help` | --- | Show wrapper-only help (cargo help is not invoked). |

**Env vars consumed:** see [Environment Variable Reference](#environment-variable-reference).

**Examples:**

```powershell
PS C:\> cargo-wrapper build --release --use-lld
PS C:\> cargo-wrapper --preflight-mode all clippy
PS C:\> cargo-wrapper --raw build --release    # bypass everything
PS C:\> $env:CARGO_VERBOSITY = 'llm'; cargo-wrapper build --release
```

**Exit codes:** standard wrapper codes; cargo failures are passthrough.

## Wrapper: cargo-route

**Synopsis:** `cargo-route [<route-flags>] [<cargo-args>]`

The dispatcher. Same flag surface as the routing flags listed under [`cargo`](#wrapper-cargo). Use this directly when you want to be explicit that routing is happening, but don't want the `cargo` shim's name.

**Examples:**

```powershell
PS C:\> cargo-route --route auto build
PS C:\> cargo-route --route docker build --target aarch64-unknown-linux-musl
PS C:\> cargo-route --no-route --help    # bare cargo help
```

## Wrapper: cargo-wsl

**Synopsis:** `cargo-wsl [<wsl-flags>] [<cargo-args>]`

Linux/gnu/musl backend. Invokes `wsl bash -lc "<escaped-cargo-cmd>"` after setting up the WSL-side environment.

**Wrapper-only flags:**

| Flag | Effect |
|---|---|
| `--wsl-native` | Use `~/.cargo` + `~/.rustup` inside the distro. |
| `--wsl-shared` | Use the shared cache root (default; `$CARGOTOOLS_WSL_CACHE_ROOT` or `~/.cargotools/wsl`). |
| `--wsl-sccache` / `--wsl-no-sccache` | Enable/disable sccache inside WSL. |

**Env vars:** `CARGO_WSL_CACHE` (`shared`/`native`), `CARGO_WSL_SCCACHE` (`1`/`0`).

**Examples:**

```bash
$ cargo-wsl build --target x86_64-unknown-linux-musl --release
$ cargo-wsl --wsl-native test
```

**Exit codes:** standard wrapper codes; WSL distro errors surface as exit 3.

## Wrapper: cargo-docker

**Synopsis:** `cargo-docker [<docker-flags>] [<cargo-args>]`

Container backend. Mounts the project and runs cargo inside `rust:slim` (or a configured image). Useful for reproducible builds and for cross-compiling from non-WSL hosts.

**Wrapper-only flags:**

| Flag | Effect |
|---|---|
| `--docker-sccache` / `--docker-no-sccache` | Enable/disable sccache in container. |
| `--docker-zigbuild` / `--docker-no-zigbuild` | Use `cargo-zigbuild` (required for Apple, optional for Linux musl). |

**Env vars:** `CARGO_DOCKER_SCCACHE`, `CARGO_DOCKER_ZIGBUILD`.

**Exit codes:** standard wrapper codes; missing Docker daemon -> exit 3.

## Wrapper: cargo-macos

**Synopsis:** `cargo-macos [<cargo-args>]`

Apple cross-compile via Docker + `cargo-zigbuild`. The only supported way to produce `*-apple-darwin` artefacts from a Windows host without an actual Mac. Internally this is `cargo-docker --docker-zigbuild` with macOS SDK support.

**Examples:**

```powershell
PS C:\> cargo-macos build --release --target aarch64-apple-darwin
```

**Exit codes:** standard wrapper codes.

## Wrapper: maturin

**Synopsis:** `maturin [<maturin-flags>] [<maturin-args>]`

Python wheel builder for PyO3 / pyo3-async-runtimes / cffi-style projects. Auto-detects the active virtual environment, applies sccache, and forwards arguments to maturin.

**Wrapper-only flags:**

| Flag | Effect |
|---|---|
| `--no-sccache` | Skip `RUSTC_WRAPPER=sccache` for this invocation. |

**Env vars consumed:** `VIRTUAL_ENV`, plus all cargo-wrapper env vars (sccache, lld, etc.).

**Examples:**

```powershell
PS C:\> maturin develop --release
PS C:\> maturin build --release --strip
```

**Exit codes:** standard wrapper codes; missing maturin -> exit 3.

## Wrapper: rust-analyzer

**Synopsis:** `rust-analyzer [<wrapper-flags>] [<ra-args>]`

Default rust-analyzer shim. Editors invoking `rust-analyzer` from PATH end up here. Enforces single-instance execution by default and applies memory-optimisation env vars (`RA_LRU_CAPACITY=64`, etc.).

**Wrapper-only flags:** see `rust-analyzer-wrapper` below.

**Examples:**

```powershell
PS C:\> rust-analyzer --version
PS C:\> rust-analyzer --memory-limit 4096
PS C:\> rust-analyzer --transport direct diagnostics
```

## Wrapper: rust-analyzer-wrapper

**Synopsis:** `rust-analyzer-wrapper [<flags>]`

Direct singleton launcher. Use this when you want the singleton + memory-watchdog behaviour but need to be explicit about it (CI, batch diagnostics, scripts).

**Wrapper-only flags:**

| Flag | Effect |
|---|---|
| `--allow-multi` | Skip singleton enforcement. |
| `--force` | Force-take the lock; kill any existing rust-analyzer first. |
| `--global-singleton` | Use a global mutex (also `RA_SINGLETON=1`). |
| `--lock-file <path>` | Override default lock file path. |
| `--memory-limit <MB>` | Background watchdog kills RA if RSS exceeds this. (Also `RA_MEMORY_LIMIT_MB`.) |
| `--no-proc-macros` | Set `RA_PROC_MACRO_WORKERS=0` (saves ~500MB on large projects). |
| `--generate-config` | Create or merge `rust-analyzer.toml` in the current directory with optimal defaults. |
| `--transport <auto\|direct\|lspmux>` | Pick LSP transport. `lspmux` is the default for interactive sessions when `lspmux.exe` is on PATH. |
| `--direct` | Shortcut for `--transport direct`. |
| `--lspmux` | Shortcut for `--transport lspmux`. |

**Env vars:** `RA_LOG`, `RA_LRU_CAPACITY`, `RA_PROC_MACRO_WORKERS`, `RA_MEMORY_LIMIT_MB`, `RA_SINGLETON`, `RA_DIAGNOSTICS_FLAGS`, `CHALK_SOLVER_MAX_SIZE`.

## Environment Variable Reference

Consolidated table. For wrapper-specific defaults, see the per-wrapper sections above. For routing internals, see [`Invoke-CargoRoute`](../Public/Invoke-CargoRoute.ps1) and [`Invoke-CargoWrapper`](../Public/Invoke-CargoWrapper.ps1).

### Routing

| Variable | Values | Default | Purpose |
|---|---|---|---|
| `CARGO_ROUTE_DEFAULT` | `auto`, `windows`, `wsl`, `docker` | `auto` | Force a backend regardless of target triple. |
| `CARGO_ROUTE_WASM` | `windows`, `wsl`, `docker` | `wsl` | Override for `wasm32-*` targets. |
| `CARGO_ROUTE_MACOS` | `wsl`, `docker` | `docker` | Override for Apple targets. |
| `CARGO_ROUTE_DISABLE` | `1` | unset | Bypass routing entirely. |

### WSL backend

| Variable | Values | Purpose |
|---|---|---|
| `CARGO_WSL_CACHE` | `shared`, `native` | Cache layout used inside WSL. |
| `CARGO_WSL_SCCACHE` | `1`, `0` | Enable/disable sccache inside WSL. |

### Docker backend

| Variable | Values | Purpose |
|---|---|---|
| `CARGO_DOCKER_SCCACHE` | `1`, `0` | Enable/disable sccache in container. |
| `CARGO_DOCKER_ZIGBUILD` | `1`, `0` | Use cargo-zigbuild (auto-on for Apple). |

### Preflight

| Variable | Values | Purpose |
|---|---|---|
| `CARGO_PREFLIGHT` | `1`, `0` | Enable preflight phase. |
| `CARGO_PREFLIGHT_MODE` | `check`, `clippy`, `fmt`, `deny`, `all` | Preflight type. |
| `CARGO_PREFLIGHT_STRICT` | `1` | Treat clippy warnings as errors. |
| `CARGO_PREFLIGHT_BLOCKING` | `1`, `0` | Whether preflight failure aborts build. |
| `CARGO_PREFLIGHT_IDE_GUARD` | `1` | Disable preflight in IDE contexts. |
| `CARGO_PREFLIGHT_FORCE` | `1` | Force preflight even in IDE contexts. |
| `CARGO_RA_PREFLIGHT` | `1` | Run rust-analyzer diagnostics during preflight. |

### Build behaviour

| Variable | Values | Purpose |
|---|---|---|
| `CARGO_USE_LLD` | `1`, `0` | Toggle lld-link (auto-detected if unset). |
| `CARGO_LLD_PATH` | path | Explicit path to `lld-link.exe`. |
| `CARGO_USE_NATIVE` | `1`, `0` | Toggle `-C target-cpu=native`. |
| `CARGO_USE_FASTLINK` | `1`, `0` | Toggle MSVC `/DEBUG:FASTLINK`. |
| `CARGO_USE_NEXTEST` | `1`, `0` | Auto-rewrite `cargo test` -> `cargo nextest run`. |
| `CARGO_TIMINGS` | `1` | Append `--timings` to build commands. |
| `CARGO_RELEASE_LTO` | `1` | Thin LTO + codegen-units=1 for `--release`. |
| `CARGO_QUICK_CHECK` | `1` | Rewrite `build` -> `check`. |
| `CARGO_AUTO_COPY` | `1`, `0` | Copy outputs from shared target dir to local `target/`. |
| `CARGO_AUTO_COPY_EXAMPLES` | `1` | Include `examples/` subdirectory in auto-copy. |

### Verbosity & output

| Variable | Values | Purpose |
|---|---|---|
| `CARGO_VERBOSITY` | `0`, `1`, `2`, `3`, `llm` | Output verbosity. `llm` activates JSON envelope. |
| `CARGO_RAW` | `1` | Bypass all wrapper behaviour (same as `--no-wrapper`). |
| `CARGO_TERM_COLOR` | `always`, `never`, `auto` | Cargo passthrough. |
| `RUST_BACKTRACE` | `0`, `1`, `full` | Cargo passthrough. |

### Toolchain & quality gate

| Variable | Values | Purpose |
|---|---|---|
| `CARGOTOOLS_RUST_TOOLCHAIN` | toolchain name (e.g. `stable`, `1.78.0`) | Pin wrapper toolchain. |
| `CARGOTOOLS_ENFORCE_QUALITY` | `1`, `0` | Mandatory quality gate (autofix + clippy + fmt). Default `1`. |
| `CARGOTOOLS_RUN_TESTS_AFTER_BUILD` | `1`, `0` | Mandatory post-build nextest. Default = quality-gate value. |
| `CARGOTOOLS_RUN_DOCTESTS_AFTER_BUILD` | `1`, `0` | Mandatory post-build doctests. Default = quality-gate value. |

### rust-analyzer

| Variable | Values | Purpose |
|---|---|---|
| `RA_LOG` | log level | Default `error`. |
| `RA_LRU_CAPACITY` | int | LRU cache size. Default `64`. |
| `RA_PROC_MACRO_WORKERS` | int | `0` disables proc-macro expansion. |
| `RA_MEMORY_LIMIT_MB` | int | Watchdog memory ceiling. |
| `RA_SINGLETON` | `1` | Force global singleton. |
| `RA_DIAGNOSTICS_FLAGS` | string | Forwarded to `rust-analyzer diagnostics`. |
| `CHALK_SOLVER_MAX_SIZE` | int | Trait solver memory bound. |

### Cache & sccache

| Variable | Values | Purpose |
|---|---|---|
| `CARGO_HOME` | path | Default `T:\RustCache\cargo-home`. |
| `RUSTUP_HOME` | path | Default `T:\RustCache\rustup`. |
| `CARGO_TARGET_DIR` | path | Unset by default; project-local `target/`. |
| `SCCACHE_DIR` | path | Default `T:\RustCache\sccache`. |
| `SCCACHE_CACHE_SIZE` | size string | Default machine-tuned (see machine config). |
| `SCCACHE_IDLE_TIMEOUT` | seconds | sccache server idle timeout. |
| `SCCACHE_STARTUP_TIMEOUT` | seconds | Default `30`. |
| `SCCACHE_REQUEST_TIMEOUT` | seconds | Default `180`. |
| `SCCACHE_MAX_CONNECTIONS` | int | Default `8`. |
| `RUSTC_WRAPPER` | `sccache` or unset | Auto-set when sccache resolves. |
| `CARGO_INCREMENTAL` | `0`, `1` | Forced to `0` when sccache is active (sccache#236). |

## Cross-Platform Notes

### Windows native (cargo-wrapper)

- MSVC toolchain: cl.exe and link.exe resolved by `Get-MsvcClExePath` to absolute paths to defeat PATH shadowing.
- PATH sanitization strips Strawberry Perl (`C:\Strawberry\c\bin`, `C:\Strawberry\perl\bin`) and Git mingw64 (`...\Git\mingw64\bin`, `...\Git\usr\bin`) for the duration of the build.
- Cache root: `T:\RustCache` (ReFS Dev Drive) by default; falls back to `$LOCALAPPDATA\RustCache` if the drive is missing.
- sccache cross-process mutex prevents race conditions when multiple LLM agents invoke cargo simultaneously.

### WSL (cargo-wsl)

- Default distro is whatever `wsl.exe` resolves first; pin via `WSL_DISTRO_NAME`.
- Shared cache mode mounts the Windows cache root into WSL via the 9p file system. Native mode keeps everything inside the distro for performance.
- sccache inside WSL listens on a Unix socket, isolated from the Windows-side server.

### Docker (cargo-docker, cargo-macos)

- Default image: `rust:slim` for Linux targets, custom zigbuild image for Apple.
- The project root is bind-mounted at `/workspace`; cargo runs with `CARGO_HOME=/cargo-home` (volume) for cache reuse.
- Apple cross builds require macOS SDK; supplied by the zigbuild image and the `--target` triple.

### macOS host

- CargoTools is Windows-first. On macOS, you can install the module under `~/.local/share/powershell/Modules/CargoTools` and use `Invoke-CargoWrapper -Command build` from pwsh; the wrapper scripts target Windows-style `~/.local/bin` and may need adjustment.

---

See also:

- [`troubleshooting.md`](troubleshooting.md) — error codes, recovery, common failures.
- [`../CLAUDE.md`](../CLAUDE.md) — module architecture, design decisions, gotchas.
- [`../CHANGELOG.md`](../CHANGELOG.md) — version history.
