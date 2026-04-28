# CargoTools

CargoTools provides routed Cargo wrappers for Windows, WSL, and Docker with
shared machine-level Rust caches, sccache defaults, queued top-level builds,
LLM-friendly diagnostics, and cross-target helpers.

## Installation

The canonical local module is located at:

C:\Users\david\Documents\PowerShell\Modules\CargoTools

The OneDrive and AppData copies should be treated as synchronized mirrors of the local installed tree, not the primary edit target.

PowerShell auto-loads modules on demand when `CargoTools` is on PSModulePath.

## Commands

- Invoke-CargoRoute
- Invoke-CargoWrapper
- Invoke-CargoWsl
- Invoke-CargoDocker
- Invoke-CargoMacos
- Invoke-RustAnalyzerWrapper

## Recommended Usage

Use the named-parameter wrapper invocation for consistent working-directory handling:

```powershell
Invoke-CargoWrapper -Command fmt -WorkingDirectory <path>
Invoke-CargoWrapper -Command clippy -AdditionalArgs @('--','-D','warnings') -WorkingDirectory <path>
Invoke-CargoWrapper -Command test -WorkingDirectory <path>
Invoke-CargoWrapper -Command build -AdditionalArgs @('--release') -WorkingDirectory <path>
```

For cross-target builds, prefer the router:

```powershell
Invoke-CargoRoute --route auto -- build --release
```

## Supplemental Commands

These are useful for diagnostics, caching, and editor integration:

- `Initialize-CargoEnv`: sets up environment defaults (cache paths, toolchains).
- `Initialize-RustDefaults`: manages the global stable Rust baseline files under the user profile, including a sanitized `~/rustfmt.toml` that serves as the default when a project does not define its own local formatter config.
- `Start-SccacheServer` / `Stop-SccacheServer`: manage the sccache daemon.
- `Get-BuildVersionInfo` / `Set-BuildVersionEnvironment`: derive a git-backed build version and stamp `BUILD_*`, `PCAI_*`, or other prefixed env vars for Rust and .NET builds.
- `Resolve-CargoTargetDirectory`: resolve the effective cargo profile output path, including shared `CARGO_TARGET_DIR` scenarios.
- `Publish-BuildArtifact`: promote a compiled artifact into a stable local output directory and emit a `.buildinfo.json` sidecar manifest.
- `Get-CargoQueueStatus`: inspect the shared CargoTools build queue.
- `Get-OptimalBuildJobs`: suggest parallel build job count for the host.
- `Get-SccacheMemoryMB` / `Get-RustAnalyzerMemoryMB`: size cache and RA memory settings.
- `Resolve-RustAnalyzerPath` / `Invoke-RustAnalyzerWrapper`: validate and launch rust-analyzer.
- `Get-RustAnalyzerTransportStatus`: report whether CargoTools will use direct rust-analyzer or `lspmux` for the current invocation shape, plus resolved config/shim state and a timeout-bounded `lspmux status --json` probe.
- `Test-RustAnalyzerHealth` / `Test-RustAnalyzerSingleton`: RA health and process checks.
- `Get-CargoContextSnapshot` / `Get-RustProjectContext` / `ConvertTo-LlmContext`: collect project context for diagnostics.
- `Format-CargoOutput` / `Format-CargoError`: normalize cargo output in logs.

## Help

- Get-Help about_CargoTools
- Get-Help Invoke-CargoRoute -Full
- External help is generated via platyPS into `docs\` and `en-US\CargoTools-help.xml`.
- Regenerate help: `tools\Generate-Help.ps1`

## Wrapper Scripts

CLI shims in `C:\Users\david\.local\bin` call into this module:

- cargo.ps1 (preferred PowerShell entry point)
- cargo-route.ps1
- cargo-wrapper.ps1
- cargo-wsl.ps1
- cargo-docker.ps1
- cargo-macos.ps1
- rust-analyzer.ps1
- rust-analyzer-wrapper.ps1

cmd.exe shims forward into PowerShell:

- cargo.cmd / cargo.bat -> cargo.ps1 (pwsh)
- rust-analyzer.cmd -> rust-analyzer.ps1 (pwsh)

## Notes

- Preflight behavior is controlled by `CARGO_PREFLIGHT_*` env vars.
- Routing defaults can be overridden by `CARGO_ROUTE_*` env vars.
- Shared cache defaults target `T:\RustCache`.
- `CARGO_HOME`, `RUSTUP_HOME`, and `SCCACHE_DIR` are shared machine-wide by default.
- `sccache` and best-practice build defaults are on by default when the tools are available.
- `~/rustfmt.toml` is treated as a CargoTools-managed stable fallback baseline; project-local `rustfmt.toml` files still override it normally.
- rust-analyzer transport defaults to `lspmux` for interactive/stdin LSP sessions when `lspmux.exe` is available, and falls back to direct `rust-analyzer` for standalone commands such as `diagnostics`, `--help`, and `--version`.
- Build outputs stay project-local by default unless `CARGO_TARGET_DIR` or shared target mode is explicitly enabled; when shared targets are used, prefer `Resolve-CargoTargetDirectory` plus `Publish-BuildArtifact` or `Copy-BuildOutputToLocal` so local runtime folders receive the successful DLL/EXE outputs deterministically.
- Top-level build commands are queued by default so concurrent callers see backpressure instead of startup races.
