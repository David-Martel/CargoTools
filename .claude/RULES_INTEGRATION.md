# Rules Integration

> How CargoTools currently enforces (or could enforce) the rules indexed in [`rules/INDEX.md`](rules/INDEX.md).
> Pairs with [`../docs/AGENTS.md`](../docs/AGENTS.md) for which agent owns each enforcement gap.

## 1. Currently enforced

The "Mechanism" column lists the concrete artifact in this repo (Pester test, ast-grep rule, manual review checklist) that catches violations today.

| Rule | Mechanism | Notes |
|---|---|---|
| canonical-files (`C:\Users\david\.claude\rules\canonical-files.yml`) | Manual review + project rule "Search before creating ANY file — NO duplicates (*_v2, enhanced_*)" from `C:\Users\david\.claude\CLAUDE.md` CRITICAL RULES | No automation in module; agents and reviewers gatekeep |
| no-invoke-expression (`C:\Users\david\.claude\rules\powershell\no-invoke-expression.yml`) | Manual review; the wrapper exclusively uses `&` operator + arrays, NOT `Invoke-Expression` | The `CargoTools.ShellEscape` C# helper exists specifically to keep shell composition explicit |
| avoid-write-host (powershell) | Mostly enforced by the verbosity system in `Private/Progress.ps1` and `Private/LlmOutput.ps1` (use `Write-Verbose`/structured JSON) | A handful of `Write-Host` calls remain in `tools/` deploy scripts — the rule explicitly excludes those |
| Cross-process safety (analogue of Rust `avoid-static-mut`) | `CargoTools.ProcessMutex` (C# inline type, `Private/Common.ps1`) + tests in `Tests/Common.Tests.ps1` | Mutex-protected sccache startup is the production-grade equivalent of "no static mut" |
| `CARGO_INCREMENTAL=0` enforced when sccache active | Hard-coded in `Initialize-CargoEnv` (`Private/Environment.ps1`) | Documented in `CLAUDE.md` as Key Design Decision |
| Test isolation (env-var save/restore) | Pattern documented in `.claude/CLAUDE.md` Testing Patterns; applied across `Tests/*.ps1` `BeforeAll`/`AfterAll` | Manual discipline; no lint catches drift |
| Build-environment sanity | `Test-BuildEnvironment` (`Public/`) reports Dev Drive, Defender exclusions, linker, sccache, tool availability, config files | Runtime advisory; not a CI gate yet |
| Backup-before-write for config files | `Write-ConfigFile` (`Private/ConfigFiles.ps1`) writes `.bak` before overwrite, supports `-WhatIf` | Aligns with security-sensitive write pattern from `C:\Users\david\.claude\rules\utils\security-sensitive.yml` |
| TOML round-trip | `Read-TomlSections` + `ConvertTo-TomlString` + Pester tests in `Tests/ConfigFiles.Tests.ps1` (assumed by `.claude/CLAUDE.md` test-suite summary) | Edge cases (arrays-of-tables, inline tables, multi-line strings) explicitly out of scope per `.claude/CLAUDE.md` |

## 2. Gaps

Rules from `rules/INDEX.md` that apply to CargoTools but have no automation today. Each row includes effort and which agent could close the gap.

| Rule / Concern | Why it matters | Effort | Owning agent |
|---|---|---|---|
| prefer-strict-mode (`C:\Users\david\.claude\rules\powershell\prefer-strict-mode.yml`) | Public functions silently accept undeclared variables / typos | LOW (one-line addition per public function) | powershell-pro |
| avoid-write-host residual hits | Some diagnostic paths still call `Write-Host`; should pass through verbosity system | LOW | powershell-pro |
| PSScriptAnalyzer baseline | No `.psscriptanalyzer` config or `Invoke-ScriptAnalyzer` step in CI; would mechanically catch `PSAvoidUsingWriteHost`, `PSAvoidUsingInvokeExpression`, `PSUseShouldProcessForStateChangingFunctions` | MEDIUM | powershell-pro + deployment-engineer |
| no-hardcoded-secrets (analogue) | Wrapper handles env vars; need a guard that fails CI if a string literal matching `(?i)(password|secret|api_key|token)` appears in `Public|Private/*.ps1` | LOW | security-auditor |
| flag-hardcoded-defaults (analogue) | Cache-root fallbacks and tool-search paths in `Private/Environment.ps1` are literal strings; should be a single config table | MEDIUM | powershell-pro + legacy-modernizer |
| doc-status (`C:\Users\david\.claude\rules\core\doc-status.yml`) | `TODO`/`FIXME` markers in source go untracked; surface in CI as advisory | LOW | test-automator (CI step) |
| canonical-doc-sections (M-CANONICAL-DOCS analogue) | platyPS-generated docs in `docs/Invoke-Cargo*.md` lack a uniform structure check | MEDIUM | docs-architect |
| Cargo-deny preflight bypass | `CARGO_PREFLIGHT_FORCE` could let users skip security gate; needs a "strict" mode in CI that ignores override | LOW | security-auditor |
| sccache `RUSTC_WRAPPER` regression coverage | Behavior depends on sccache being on PATH at module-load time; no fixture exercises the absence/presence transition | MEDIUM | test-automator |
| Coverage measurement | `.claude/CLAUDE.md` cites 85% min coverage but no `Pester -CodeCoverage` integration documented | MEDIUM | test-automator |
| BuildEnvironment as CI gate | `Test-BuildEnvironment` exists but is advisory; CI could fail on critical issues (no Defender exclusion, no Dev Drive, missing sccache when expected) | LOW | devops-troubleshooter |
| Cross-process mutex test on Linux | Currently Windows-only; PS Core on Linux has different named-mutex semantics | HIGH | powershell-pro + debugger |

## 3. Pre-commit hook proposal (description, not implementation)

Goal: catch the highest-cost mistakes at `git commit` time without slowing the developer loop > ~5 seconds.

**Shape**:

- A PowerShell script `tools/pre-commit.ps1` invoked by `.git/hooks/pre-commit` (a thin shim — Bash on Linux/macOS, native PS on Windows; see Learned Rule #10 about `/bin/sh` not existing on Windows-only setups).
- Only runs on staged `.ps1`, `.psm1`, `.psd1` files (use `git diff --cached --name-only --diff-filter=ACM`).
- Steps:
  1. **Format check** — `Invoke-Formatter` (PSScriptAnalyzer) on each staged file; fail if changes would be made.
  2. **Lint** — `Invoke-ScriptAnalyzer -Severity Error,Warning -Setting <project-rules>.psd1` over staged files.
  3. **ast-grep scan** (if `sg.exe` is on PATH) — only the PowerShell rules from `C:\Users\david\.claude\rules\powershell\` and `no-hardcoded-secrets.yml`. Never run the Rust rule pack against `.ps1` files.
  4. **Smoke Pester** — `Invoke-Pester -Path Tests/ -Tag 'Smoke' -CI` (a small subset tagged for fast feedback; full suite is CI's job).
- Fast-path: skip entirely if `git config cargotools.skipPrecommit true` is set, or honor `--no-verify`.

**Tradeoffs**:

- Local hooks are advisory at best — users can `--no-verify`. CI must be the source of truth (Learned Rule #1 — Warnings ≠ Clean).
- `Invoke-ScriptAnalyzer` cold-start cost is ~1–2s; cache the rule-set object across files in a single hook run.
- Pester cold-start with module reload is ~3–5s; tag a `Smoke` subset of < 30 tests to stay under budget.
- Hook MUST NOT modify files (no auto-format) — it surfaces issues and exits non-zero. Auto-format belongs in editor/save hooks, not pre-commit.

## 4. CI workflow proposal (description, not YAML)

A GitHub Actions workflow that gates PRs on Windows + Linux PowerShell Core, mirroring the layer-3 pattern from `C:\Users\david\.claude\rules\ENFORCEMENT_PLAN.md`.

**Triggers**: `pull_request` on any branch into `main`; `push` to `main`; weekly `schedule` for the audit job.

**Jobs**:

1. **lint-windows** (`runs-on: windows-latest`):
   - Install PSScriptAnalyzer pinned to current major.
   - Run `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error,Warning -ReportSummary`.
   - Fail if any error or unsuppressed warning.

2. **lint-linux** (`runs-on: ubuntu-latest`):
   - Same PSScriptAnalyzer pass under `pwsh`.
   - Catches PS-Core-incompatible idioms early.

3. **test-windows** (`runs-on: windows-latest`):
   - Cache `~/.local/share/powershell/Modules` and `T:\RustCache` (where applicable on Windows runners — fall back to default).
   - `Import-Module ./CargoTools.psd1 -Force`.
   - `Invoke-Pester -Path ./Tests -CI -Output Detailed -CodeCoverage 'Public/*.ps1','Private/*.ps1' -CodeCoveragePath ./coverage.xml`.
   - Upload coverage artifact; fail if coverage < 85% (per CRITICAL RULES in `C:\Users\david\.claude\CLAUDE.md`).

4. **test-linux** (`runs-on: ubuntu-latest`):
   - PS-Core-only subset (skip Windows-specific MSVC/sccache integration tests via a Pester `-ExcludeTagFilter 'WindowsOnly'`).
   - Validates the cross-platform routing logic in `Invoke-CargoRoute`.

5. **environment-doctor** (`runs-on: windows-latest`, advisory only):
   - Run `Test-BuildEnvironment` and capture as a PR comment artifact.
   - Highlights configuration drift (missing Defender exclusion, no Dev Drive) without failing the build — failures here would block contributors who don't have the optimal local setup.

6. **secrets-scan**:
   - `gitleaks` or equivalent over the diff.
   - Backstops the no-hardcoded-secrets rule.

7. **weekly-audit** (`schedule: cron`):
   - Full Pester run (no smoke tag).
   - PSScriptAnalyzer with all `Severity` levels (Information included) — surface tech debt as advisory.
   - `cargo audit` over any sample crate that ships in `Tests/Fixtures` if added later.

**Cross-references**:

- Layer model: `C:\Users\david\.claude\rules\ENFORCEMENT_PLAN.md` Layers 1–4
- Reusable workflow pattern: same file, "Step 3"
- Learned Rule #1 (`C:\Users\david\.claude\CLAUDE.md`): `-D warnings` analogue here is `-Severity Error,Warning` AND failing on warnings — not just reporting them
- Learned Rule #4: any perf-related change must include before/after measurements; CI should NOT auto-pass perf claims without a benchmark artifact

## Cross-references

- Index of all external rules: [`rules/INDEX.md`](rules/INDEX.md)
- Agent map and recipes: [`../docs/AGENTS.md`](../docs/AGENTS.md)
- Project conventions: [`../CLAUDE.md`](../CLAUDE.md), [`./CLAUDE.md`](CLAUDE.md)
- Global framework: `C:\Users\david\.claude\CLAUDE.md`
