# CargoTools Troubleshooting

This document is organised by error code, then by symptom. Every code corresponds to a `diagnostic` line emitted in the [`--llm` JSON envelope](wrappers.md#json-envelope---llm). Programmatic agents can match on `code` and consult the [Decision Table](#decision-table-for-llm-agents) for remediation.

## Table of Contents

- [Self-Healing Failure Codes](#self-healing-failure-codes)
  - [MODULE_NOT_FOUND](#module_not_found)
  - [ONEDRIVE_LOCK](#onedrive_lock)
  - [SCCACHE_DEAD](#sccache_dead)
  - [RUSTUP_NOT_FOUND](#rustup_not_found)
  - [PATH_SHADOWED](#path_shadowed)
  - [STALE_MUTEX](#stale_mutex)
- [Reading --doctor Output](#reading---doctor-output)
- [Reading --llm JSON](#reading---llm-json)
- [Decision Table for LLM Agents](#decision-table-for-llm-agents)
- [Common Build Failures](#common-build-failures)
  - [Linker Errors](#linker-errors)
  - [MSVC Missing](#msvc-missing)
  - [sccache Not Caching](#sccache-not-caching)
  - [Quality Gate Surprises](#quality-gate-surprises)
- [Filing a Bug Report](#filing-a-bug-report)

## Self-Healing Failure Codes

Each section below documents one diagnostic code: what it means, when the wrapper emits it, what auto-recovery the wrapper attempts, and what manual steps remain if recovery fails.

### MODULE_NOT_FOUND

**Meaning:** The wrapper script could not locate the `CargoTools` module on `PSModulePath`.

**When emitted:** First action of every wrapper. The `_WrapperHelpers.psm1` helper probes `~/Documents/PowerShell/Modules/CargoTools`, `~/Documents/WindowsPowerShell/Modules/CargoTools`, `$env:PSModulePath` entries, and the `CARGOTOOLS_MODULE_PATH` override.

**Auto-recovery:** None. The wrapper cannot proceed.

**Exit code:** 2.

**Manual recovery:**

1. Confirm the module is installed:
   ```powershell
   PS C:\> Get-Module -ListAvailable CargoTools
   ```
2. If missing, install from gallery or clone:
   ```powershell
   PS C:\> Install-Module CargoTools -Scope CurrentUser
   ```
   or
   ```powershell
   PS C:\> git clone <repo-url> "$HOME\Documents\PowerShell\Modules\CargoTools"
   ```
3. If installed but not found, set the override:
   ```powershell
   PS C:\> $env:CARGOTOOLS_MODULE_PATH = 'C:\path\to\CargoTools\CargoTools.psd1'
   ```
4. Re-run the wrapper with `--diagnose` to confirm the module loads.

### ONEDRIVE_LOCK

**Meaning:** The module's `.psd1` or a `Private/*.ps1` file is currently locked by OneDrive sync. The CargoTools repo lives under `~/Documents/PowerShell/Modules/CargoTools`, which is OneDrive-synced on most installs.

**When emitted:** During `Import-Module`, when PowerShell encounters a sharing violation reading a module file.

**Auto-recovery:** The wrapper retries `Import-Module` up to **3 times** with **200 ms** backoff. The retry budget and delay are constants in `_WrapperHelpers.psm1`.

**Exit code (after exhausted retries):** 1.

**Manual recovery:**

1. Pause OneDrive sync (system tray -> OneDrive -> Pause syncing -> 2 hours).
2. Mark the module folder as "Always keep on this device" so OneDrive doesn't free files mid-import:
   ```powershell
   PS C:\> attrib -p "$HOME\Documents\PowerShell\Modules\CargoTools\*" /s
   ```
3. As a one-shot fix, copy the module to `$LOCALAPPDATA\PowerShell\Modules\CargoTools` and set `CARGOTOOLS_MODULE_PATH` to point there. That copy is not OneDrive-managed.

### SCCACHE_DEAD

**Meaning:** sccache server is unreachable. Either it never started, crashed, or its IPC port (`4400` on this workstation by default) is wedged.

**When emitted:** During `Initialize-CargoEnv` (startup probe) or after a build failure when `Test-SccacheHealth` reports unhealthy + not running.

**Auto-recovery:**

- **At startup:** if sccache is configured (`RUSTC_WRAPPER=sccache`) but unreachable, the wrapper unsets `RUSTC_WRAPPER` for this invocation. Build proceeds without caching but does not fail.
- **Mid-build:** if cargo fails and sccache is dead, the wrapper attempts `Start-SccacheServer -Force` and **retries the build once**. If sccache restart succeeds and the retry build succeeds, the wrapper exits 0. The action is reported as `restarted-sccache` in the JSON envelope.

**Exit code:** Whatever cargo returns after the retry. Wrapper does not synthesise its own.

**Manual recovery:**

1. Inspect health:
   ```powershell
   PS C:\> sccache --show-stats
   PS C:\> Get-Process sccache -ErrorAction SilentlyContinue
   ```
2. Force a restart:
   ```powershell
   PS C:\> sccache --stop-server
   PS C:\> Stop-SccacheServer
   PS C:\> Start-SccacheServer -Force
   ```
3. If the port is wedged, kill all sccache processes and clear stale state:
   ```powershell
   PS C:\> Get-Process sccache -ErrorAction SilentlyContinue | Stop-Process -Force
   PS C:\> Remove-Item "$env:LOCALAPPDATA\sccache\sccache-*.lock" -ErrorAction SilentlyContinue
   ```
4. If sccache is uninstalled or broken, build with `--raw` (or `--no-wrapper`) to bypass it entirely.

### RUSTUP_NOT_FOUND

**Meaning:** `rustup.exe` is not on PATH and CargoTools can't dispatch the build.

**When emitted:** Before any cargo invocation, when `Get-RustupPath` returns a non-existent path.

**Auto-recovery:** None.

**Exit code:** 3.

**Manual recovery:**

1. Install rustup: <https://rustup.rs/>
2. After install, restart the shell so PATH propagates.
3. Confirm:
   ```powershell
   PS C:\> rustup --version
   PS C:\> rustup show
   ```
4. If rustup is installed in a non-default location, set `RUSTUP_HOME` and put `rustup.exe` on PATH manually.

### PATH_SHADOWED

**Meaning:** A conflicting toolchain on PATH (Strawberry Perl, Git mingw64) has higher precedence than MSVC. Without sanitisation this causes `link.exe` / `cl.exe` to resolve to the wrong binary, producing inscrutable linker errors.

**When emitted:** During `Initialize-CargoEnv`, when `Get-SanitizedPath` detects `C:\Strawberry\c\bin`, `C:\Strawberry\perl\bin`, or `*\Git\mingw64\bin`, `*\Git\usr\bin` ahead of the MSVC bin directory.

**Auto-recovery:** Advisory only. The wrapper sanitises PATH for the duration of the build (the offending entries are stripped from the in-process `PATH`), but the user's shell session is not modified.

**Exit code:** N/A — diagnostic only, build continues.

**Manual recovery:**

1. Inspect PATH:
   ```powershell
   PS C:\> $env:PATH -split ';' | Select-String 'Strawberry|mingw64|Git'
   ```
2. Reorder or remove the offending entries from the User PATH:
   ```powershell
   PS C:\> [Environment]::GetEnvironmentVariable('PATH','User')
   PS C:\> # edit via System Properties or `setx PATH '...'`
   ```
3. Or accept the wrapper's per-invocation sanitisation and ignore the warning.

### STALE_MUTEX

**Meaning:** A `CargoTools.*` named mutex (sccache startup, build queue, rust-analyzer singleton) has been held for more than 60 seconds. Most legitimate operations release within 5-10 seconds, so this usually indicates a crashed earlier invocation.

**When emitted:** Advisory diagnostic during cross-process mutex acquisition. The wrapper still tries to acquire (the mutex may be released momentarily).

**Auto-recovery:** None — the wrapper does not unilaterally break a mutex held by another process.

**Exit code:** N/A — advisory only.

**Manual recovery:**

1. Identify the holder:
   ```powershell
   PS C:\> handle.exe -a CargoTools  # Sysinternals handle.exe
   ```
2. If a stale process is found, terminate it:
   ```powershell
   PS C:\> Stop-Process -Id <pid> -Force
   ```
3. Named mutexes are released automatically when the holding process exits, so killing it resolves the contention.

## Reading `--doctor` Output

`cargo --doctor` (and any other wrapper with `--doctor`) emits a tabular report. Each row is one check with a status:

| Status | Meaning |
|---|---|
| `[OK]` | Check passed. |
| `[WARN]` | Non-fatal: build will work but is suboptimal. |
| `[ERROR]` | Fatal: build will not function correctly until resolved. |

Example:

```text
$ cargo --doctor
Rustup           [OK]    rustup 1.27.1 (54dd3d00d 2024-04-24)
ActiveToolchain  [OK]    stable-x86_64-pc-windows-msvc
SelectedToolchain[OK]    stable-x86_64-pc-windows-msvc (healthy)
VisualStudio     [OK]    Visual Studio Community 2022 (C:\Program Files\Microsoft Visual Studio\2022\Community)
MSVC             [OK]    14.39.33519 (...\link.exe)
Linker           [OK]    bundled rust-lld (C:\Users\david\.rustup\toolchains\stable-x86_64-pc-windows-msvc\bin\rust-lld.exe)
Sccache          [OK]    healthy (C:\Users\david\.cargo\bin\sccache.exe, 412MB)
Nextest          [OK]    installed
Ninja            [WARN]  not installed
CacheRoot        [OK]    T:\RustCache (ReFS Dev Drive)
DefenderExclusion[WARN]  T:\RustCache not in Windows Defender exclusion list
PATH             [OK]    no conflicting toolchains
```

To get the same data as JSON (for an agent to parse), use `--diagnose`:

```text
$ cargo --diagnose
{"check":"Rustup","status":"ok","value":"rustup 1.27.1 ..."}
{"check":"VisualStudio","status":"ok","value":"Visual Studio Community 2022"}
{"check":"Sccache","status":"ok","value":"healthy","memory_mb":412}
{"check":"Ninja","status":"warn","detail":"not installed","recovery":"choco install ninja"}
{"summary":"ok","warnings":1,"errors":0}
```

`--doctor` exits 0 when all checks are OK or WARN; it exits 4 when any ERROR is present.

## Reading `--llm` JSON

The JSON envelope is NDJSON on stderr, one object per line. To capture and parse it:

```powershell
PS C:\> cargo --llm build --release 2> build.ndjson
PS C:\> Get-Content build.ndjson | ForEach-Object { $_ | ConvertFrom-Json }
```

Or in bash:

```bash
$ cargo --llm build --release 2> build.ndjson
$ cat build.ndjson | jq -c '.'
```

For schema details and an annotated transcript, see [`wrappers.md`](wrappers.md#json-envelope---llm).

## Decision Table for LLM Agents

This table is intended to be machine-readable. An agent reading this document can match diagnostic `code` -> recommended action without prose interpretation.

```json
{
  "MODULE_NOT_FOUND": {
    "severity": "error",
    "exit_code": 2,
    "auto_recover": false,
    "actions": [
      {"step": "verify", "command": "Get-Module -ListAvailable CargoTools"},
      {"step": "install", "command": "Install-Module CargoTools -Scope CurrentUser"},
      {"step": "override", "env": "CARGOTOOLS_MODULE_PATH"}
    ]
  },
  "ONEDRIVE_LOCK": {
    "severity": "warn",
    "exit_code": 1,
    "auto_recover": true,
    "auto_recover_strategy": "retry_3x_200ms",
    "actions": [
      {"step": "pause_sync", "manual": "OneDrive system tray -> Pause syncing"},
      {"step": "pin_local", "command": "attrib -p $HOME\\Documents\\PowerShell\\Modules\\CargoTools\\* /s"},
      {"step": "relocate", "env": "CARGOTOOLS_MODULE_PATH", "to": "$LOCALAPPDATA\\PowerShell\\Modules\\CargoTools"}
    ]
  },
  "SCCACHE_DEAD": {
    "severity": "warn",
    "exit_code": "passthrough",
    "auto_recover": true,
    "auto_recover_strategy": "unset_RUSTC_WRAPPER_or_restart_and_retry_once",
    "actions": [
      {"step": "inspect", "command": "sccache --show-stats"},
      {"step": "restart", "command": "Stop-SccacheServer; Start-SccacheServer -Force"},
      {"step": "bypass", "flag": "--raw"}
    ]
  },
  "RUSTUP_NOT_FOUND": {
    "severity": "error",
    "exit_code": 3,
    "auto_recover": false,
    "actions": [
      {"step": "install", "url": "https://rustup.rs/"},
      {"step": "verify", "command": "rustup --version"}
    ]
  },
  "PATH_SHADOWED": {
    "severity": "warn",
    "exit_code": "passthrough",
    "auto_recover": true,
    "auto_recover_strategy": "sanitize_path_in_process_only",
    "actions": [
      {"step": "inspect", "command": "$env:PATH -split ';' | Select-String 'Strawberry|mingw64'"},
      {"step": "fix_user_path", "manual": "Reorder or remove offending entries from User PATH"}
    ]
  },
  "STALE_MUTEX": {
    "severity": "warn",
    "exit_code": "passthrough",
    "auto_recover": false,
    "actions": [
      {"step": "identify", "command": "handle.exe -a CargoTools"},
      {"step": "kill", "command": "Stop-Process -Id <pid> -Force"}
    ]
  }
}
```

## Common Build Failures

Failures unrelated to wrapper-level codes. These show up as native cargo exits (typically 101) and require ordinary debugging.

### Linker Errors

**Symptom:** `error: linking with 'link.exe' failed`, `LNK1181`, `LNK2019`, `LINK : fatal error LNK1104`.

**Diagnostic commands:**

```powershell
PS C:\> cargo --doctor                    # confirm linker resolution
PS C:\> $env:RUSTFLAGS                    # show injected RUSTFLAGS
PS C:\> where.exe link.exe                # confirm link.exe is the MSVC one, not Git's
```

Common causes:

- `PATH_SHADOWED` warning (see above) — fix PATH or accept per-invocation sanitisation.
- Wrong VS edition selected — set `VCINSTALLDIR` or use Developer PowerShell.
- Bundled rust-lld vs external lld-link mismatch — use `--no-lld` to fall back to `link.exe`.

### MSVC Missing

**Symptom:** `--doctor` reports `VisualStudio: NOT FOUND`. Builds fail with `link.exe not found` or `cl.exe not found`.

**Recovery:** Install VS Build Tools 2019/2022 with the "Desktop development with C++" workload, or install VS Community. After install, run `cargo --doctor` to confirm detection.

### sccache Not Caching

**Symptom:** `sccache --show-stats` shows zero cache hits over multiple builds.

**Diagnostic commands:**

```powershell
PS C:\> sccache --show-stats
PS C:\> echo $env:CARGO_INCREMENTAL       # must be 0 with sccache
PS C:\> echo $env:RUSTC_WRAPPER           # should be 'sccache'
```

Causes:

- `CARGO_INCREMENTAL=1` set externally. CargoTools forces it to `0`, but a `.cargo/config.toml` override can re-enable it. (sccache#236)
- Wrapper-level builds that change RUSTFLAGS each invocation — every cache key is unique.
- sccache disk usage hit `SCCACHE_CACHE_SIZE` and entries are evicting faster than they accumulate.

### Quality Gate Surprises

**Symptom:** `cargo build` runs `cargo clippy --fix`, `cargo fmt`, and post-build `cargo nextest run` without you asking. Build seemingly hangs or modifies files unexpectedly.

**Cause:** `CARGOTOOLS_ENFORCE_QUALITY=1` is the default. The wrapper auto-enables `--fix` and runs nextest + doctests after a successful build.

**Disable:**

```powershell
PS C:\> $env:CARGOTOOLS_ENFORCE_QUALITY = '0'
PS C:\> cargo build --release
```

Or per-invocation:

```powershell
PS C:\> cargo --raw build --release
```

## Filing a Bug Report

When wrapper behaviour is wrong, attach the JSON envelope and `--doctor` output to the issue:

```powershell
PS C:\> cargo --diagnose > diagnose.json 2>&1
PS C:\> cargo --llm <args-that-fail> > stdout.log 2> envelope.ndjson
PS C:\> Get-Module CargoTools | Format-List Name, Version, ModuleBase
```

Include in the report:

1. CargoTools module version (`Get-Module CargoTools`).
2. Wrapper script version (`cargo --version`).
3. `diagnose.json`.
4. `envelope.ndjson` (the failing run).
5. The exact command line that triggered the issue.
6. `cargo --version`, `rustc --version`, `rustup show`.

---

See also:

- [`wrappers.md`](wrappers.md) — full CLI reference and JSON envelope schema.
- [`../CLAUDE.md`](../CLAUDE.md) — module architecture, env vars, design decisions.
- [`../CHANGELOG.md`](../CHANGELOG.md) — version history.
