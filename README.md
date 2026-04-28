# CargoTools

> Routed cargo wrappers for Windows, WSL, Docker, and Apple cross-compile, with shared sccache, smart defaults, LLM-friendly diagnostics, and global Rust config management.

<!-- ci-badge -->
<!-- pester-badge -->
<!-- license-badge -->

## What it is

CargoTools is a PowerShell module that wraps `cargo` to make Rust builds on Windows fast, predictable, and AI-agent-friendly. It auto-detects and configures sccache, lld, nextest, and Ninja; sanitises PATH against well-known toolchain conflicts; and emits structured JSON diagnostics for LLM agents. The same module routes builds to WSL, Docker, or zigbuild containers based on the `--target` triple.

## Highlights

- **Smart defaults**: lld-link, cargo-nextest, Ninja, MSVC absolute paths, MAKEFLAGS — all auto-enabled when present.
- **Shared, machine-wide cache**: `T:\RustCache` (ReFS Dev Drive) hosts `cargo-home`, `cargo-target`, `sccache`, `rustup`. Falls back to `$LOCALAPPDATA\RustCache`.
- **Cross-target routing**: one `cargo build --target …` dispatches to Windows MSVC, WSL bash, Docker, or zigbuild automatically.
- **Self-healing wrappers**: sccache death is detected and the build retries once; OneDrive sharing violations on the module file are retried 3x; PATH conflicts (Strawberry Perl, Git mingw64) are sanitised in-process.
- **LLM-friendly output**: `--llm` flag emits NDJSON envelopes (`start`/`diagnostic`/`action`/`end`) on stderr while cargo output stays on stdout.
- **Standardised wrapper UX**: every shim supports `--help`, `--version`, `--doctor`, `--diagnose`, `--llm`, `--list-wrappers`, `--no-wrapper` with consistent exit codes 0-4.
- **Quality gate**: optional mandatory clippy `--fix` + fmt + post-build nextest + doctests, controllable via `CARGOTOOLS_ENFORCE_QUALITY`.
- **Global Rust config management**: `Initialize-RustDefaults` merges optimal defaults into `~/.cargo/config.toml`, `~/rustfmt.toml`, `~/.clippy.toml` without overwriting user customisations.

## Install

### From PowerShell Gallery

```powershell
PS C:\> Install-Module CargoTools -Scope CurrentUser
PS C:\> Import-Module CargoTools
```

### From source

```powershell
PS C:\> git clone <repo-url> "$HOME\Documents\PowerShell\Modules\CargoTools"
PS C:\> Import-Module CargoTools -Force
```

### Deploy CLI shims

The `cargo`, `rust-analyzer`, `maturin`, etc. wrappers in `~/bin` and `~/.local/bin` are not installed by `Install-Module`. Run the deployment script after the module is loaded:

```powershell
PS C:\> .\tools\Install-Wrappers.ps1 -DryRun    # preview
PS C:\> .\tools\Install-Wrappers.ps1            # install .ps1 + .cmd shims
PS C:\> .\tools\Install-Wrappers.ps1 -Uninstall # remove
```

The script also adds `~/bin` and `~/.local/bin` to the user PATH if absent. Restart the shell after first install.

> **Note on OneDrive paths**: this module is most commonly cloned into `~/Documents/PowerShell/Modules/CargoTools`, which is OneDrive-synced. Builds use a non-synced cache at `T:\RustCache` (or `$LOCALAPPDATA\RustCache`), so OneDrive does not see compilation artefacts. If `Import-Module` ever fails with a sharing-violation error, the wrapper retries automatically (`ONEDRIVE_LOCK` recovery — see [`docs/troubleshooting.md`](docs/troubleshooting.md#onedrive_lock)).

## Quickstart

The five most common commands using the deployed wrappers:

```powershell
PS C:\> cargo build --release                          # auto-routed Windows build
PS C:\> cargo --route wsl test --target x86_64-unknown-linux-gnu
PS C:\> cargo --doctor                                 # full environment diagnostic
PS C:\> cargo --llm build --release 2> build.ndjson    # JSON envelope on stderr
PS C:\> rust-analyzer --memory-limit 4096              # singleton with watchdog
```

For a non-routed direct invocation (when you don't want any backend dispatch):

```powershell
PS C:\> cargo-wrapper --raw build --release            # bypass everything
```

## Documentation

- [`docs/wrappers.md`](docs/wrappers.md) — full CLI reference for every wrapper, common flags, env vars, JSON envelope schema, cross-platform notes.
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — error codes, self-healing recovery, decision table for LLM agents, common build failures.
- [`docs/AGENTS.md`](docs/AGENTS.md) — guidance for AI agents working in this repo.
- [`CHANGELOG.md`](CHANGELOG.md) — version history (current: 0.9.0).
- [`CLAUDE.md`](CLAUDE.md) — architecture, design decisions, env vars, gotchas.
- platyPS-generated cmdlet help: `Get-Help Invoke-CargoWrapper -Full`, `Get-Help Invoke-CargoRoute -Full`, etc.

## For LLM Agents

CargoTools is designed for shared use by humans and AI coding agents.

- Pass `--llm` (or set `CARGO_VERBOSITY=llm`) to receive a structured NDJSON envelope on stderr. Schema and an annotated transcript live in [`docs/wrappers.md`](docs/wrappers.md#json-envelope---llm).
- Diagnostic codes (`MODULE_NOT_FOUND`, `ONEDRIVE_LOCK`, `SCCACHE_DEAD`, `RUSTUP_NOT_FOUND`, `PATH_SHADOWED`, `STALE_MUTEX`) come with a machine-readable [decision table](docs/troubleshooting.md#decision-table-for-llm-agents) mapping code → recommended action.
- Per-agent operating instructions and rule index live under [`.claude/`](.claude/) and [`docs/AGENTS.md`](docs/AGENTS.md).
- Standardised exit codes (0 success, 1 wrapper error, 2 module missing, 3 tool missing, 4 config error, ≥128 native passthrough) make programmatic dispatch reliable.

## Architecture summary

```text
cargo.ps1 -> cargo-route.ps1 -> Invoke-CargoRoute
                                      |
                   +------------------+------------------+
                   |                  |                  |
          Invoke-CargoWrapper   Invoke-CargoWsl    Invoke-CargoDocker
          (Windows / MSVC)      (WSL / bash -lc)   (Docker container)
                                                        |
                                                Invoke-CargoMacos
                                                (Docker + zigbuild)
```

`Invoke-CargoRoute` classifies `--target` triples and dispatches. All four backend commands parse CLI-style flags in a manual `for` loop (not `param()` binding), allowing wrapper flags to mix freely with passthrough cargo arguments. Module layout, design decisions, and the list of public/private functions are in [`CLAUDE.md`](CLAUDE.md#architecture).

## Contributing

```powershell
PS C:\> Import-Module CargoTools -Force
PS C:\> Invoke-Pester -Path .\Tests\ -Output Detailed       # ~350 tests, ~2 minutes, 5 expected skips
PS C:\> .\tools\Generate-Help.ps1                           # regenerate platyPS docs
```

Version bumps are coordinated in three places: `CargoTools.psd1` (`ModuleVersion`), `CHANGELOG.md` (new section), and `tools/Install-Wrappers.ps1` (banner). Wrapper-only changes bump the wrapper version emitted by `--version`.

## License

License placeholder — see `LICENSE` once published.
