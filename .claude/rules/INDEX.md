# External Rules Index

> Hierarchical index of ast-grep rules and policy docs in `C:\Users\david\.claude\rules\` that apply to CargoTools.
> All paths are absolute and read-only — this file is a lookup map for LLM agents working on this repo.
> See companion file [`RULES_INTEGRATION.md`](../RULES_INTEGRATION.md) for which rules are currently enforced and which are gaps.

## How to use this index (for LLM agents)

1. **Identify the file you are editing**: `.ps1`/`.psm1`/`.psd1` under `Public/`, `Private/`, `Tests/`, `wrappers/`, or `tools/`.
2. **Look up applicable rules**: PowerShell rules apply to all module code. Rust rules apply ONLY when reasoning about cargo/Rust workflows the wrapper interacts with — never auto-apply Rust syntax rules to PowerShell files.
3. **Check the "Auto-enforced?" column**: `Yes (...)` means CI or a hook will catch violations. `Manual review` means you must verify by hand. `Not applicable to PowerShell` means the rule informs design decisions but cannot be mechanically enforced here.
4. **Resolve cross-cutting standards** (panic/unwrap, hardcoded secrets, empty catch) against the corresponding PowerShell construct (e.g., `try { } catch { }` ≅ Rust `match Result`).
5. **Cite the absolute path** when proposing a fix: `Per C:\Users\david\.claude\rules\rust\avoid-static-mut.yml ...`.
6. **Defer to project tests** — Pester tests in `Tests/` are the source of truth; rules are guardrails on top.

---

## Section 1 — PowerShell Rules (HIGH relevance)

Most directly applicable to the bulk of CargoTools source.

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| avoid-write-host | `C:\Users\david\.claude\rules\powershell\avoid-write-host.yml` | Use `Write-Output`/`Write-Verbose`/`Write-Information` instead of `Write-Host` in module code | HIGH — `Private/Progress.ps1`, `Private/LlmOutput.ps1` emit user-facing text; rule explicitly excludes `Tests/` and `Tools/` | Manual review (PSScriptAnalyzer rule `PSAvoidUsingWriteHost` covers it) |
| no-invoke-expression | `C:\Users\david\.claude\rules\powershell\no-invoke-expression.yml` | Block `Invoke-Expression`/`iex` (RCE risk) | HIGH — wrapper composes shell strings for WSL/Docker; must use `&` operator + arrays | Manual review (PSScriptAnalyzer `PSAvoidUsingInvokeExpression`) |
| prefer-strict-mode | `C:\Users\david\.claude\rules\powershell\prefer-strict-mode.yml` | Add `Set-StrictMode -Version Latest` to public functions | HIGH — applies to all `Public/*.ps1`; excludes `Private/` and `Tests/` | Manual review |
| prefer-write-verbose | `C:\Users\david\.claude\rules\powershell\prefer-write-verbose.yml` | Same intent as avoid-write-host but informational severity | HIGH — duplicate of avoid-write-host with broader file scope | Manual review |

## Section 2 — Rust Rules

Apply when reasoning about cargo/rustc behavior the wrapper orchestrates, when generating example Rust snippets in docs, or when validating user code in preflight scenarios. Do NOT mechanically apply to `.ps1` files.

### 2a — Panic Prevention (15 rules) — `C:\Users\david\.claude\rules\rust\panics\`

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| unwrap-call | `...\panics\unwrap-call.yml` | `.unwrap()` is forbidden in `src/` | LOW — diagnostic helper text could mention this when parsing user build failures | Yes (ast-grep + clippy `unwrap_used`) |
| expect-call | `...\panics\expect-call.yml` | `.expect("...")` discouraged | LOW | Yes (ast-grep) |
| panic-macro | `...\panics\panic-macro.yml` | `panic!()` is a bug-marker, not error handling | LOW | Yes (ast-grep) |
| todo-macro | `...\panics\todo-macro.yml` | `todo!()` cannot ship | LOW | Yes (ast-grep) |
| unimplemented-macro | `...\panics\unimplemented-macro.yml` | `unimplemented!()` cannot ship | LOW | Yes (ast-grep) |
| unreachable-macro | `...\panics\unreachable-macro.yml` | Document invariant or remove | LOW | Yes (ast-grep) |
| as-ref-unwrap | `...\panics\as-ref-unwrap.yml` | `.as_ref().unwrap()` panics | LOW | Yes (ast-grep) |
| library-unwrap | `...\panics\library-unwrap.yml` | Library code panics are doubly bad | LOW | Yes (ast-grep) |
| match-arm-unwrap | `...\panics\match-arm-unwrap.yml` | Unwrap in match arm | LOW | Yes (ast-grep) |
| try-into-unwrap | `...\panics\try-into-unwrap.yml` | `.try_into().unwrap()` | LOW | Yes (ast-grep) |
| string-slice-panic | `...\panics\string-slice-panic.yml` | `&s[..n]` panics on UTF-8 boundary | LOW | Yes (ast-grep) |
| unchecked-division | `...\panics\unchecked-division.yml` | Division panics on zero | LOW | Yes (ast-grep) |
| unchecked-index | `...\panics\unchecked-index.yml` | `vec[i]` panics on OOB | LOW | Yes (ast-grep) |
| fixed-size-init | `...\panics\fixed-size-init.yml` | `[0; N]` panics if N not const | LOW | Yes (ast-grep) |
| unsafe-with-panic | `...\panics\unsafe-with-panic.yml` | unsafe + panic = UB risk | LOW | Yes (ast-grep) |
| test-expect-todo | `...\panics\test-expect-todo.yml` | `expect("TODO")` in tests = tech debt | LOW | Yes (ast-grep) |

### 2b — Error Handling

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| avoid-unwrap | `C:\Users\david\.claude\rules\rust\avoid-unwrap.yml` | Same as panics/unwrap-call but warning level | LOW | Yes (ast-grep) |
| missing-error-context | `C:\Users\david\.claude\rules\rust\missing-error-context.yml` | `?` without `.context("...")` loses info | LOW | Yes (ast-grep) |
| prefer-collect-result | `C:\Users\david\.claude\rules\rust\prefer-collect-result.yml` | `Vec<Result<T,E>>` should fold to `Result<Vec<T>,E>` | LOW | Yes (ast-grep) |
| todo-expect-message | `C:\Users\david\.claude\rules\rust\todo-expect-message.yml` | `expect("TODO ...")` blocks merge | LOW | Yes (ast-grep) |

### 2c — Performance

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| clone-in-hot-loop | `C:\Users\david\.claude\rules\rust\clone-in-hot-loop.yml` | Avoid `.clone()` in for/while bodies | LOW (informs perf-engineer recommendations) | Yes (ast-grep) |
| vec-push-in-loop | `C:\Users\david\.claude\rules\rust\vec-push-in-loop.yml` | Pre-size with `Vec::with_capacity` | LOW | Yes (ast-grep) |
| inefficient-string-allocation | `C:\Users\david\.claude\rules\rust\inefficient-string-allocation.yml` | `format!`/`.to_string()` in tight loops | LOW | Yes (ast-grep) |
| avoid-sync-mutex-in-async | `C:\Users\david\.claude\rules\rust\avoid-sync-mutex-in-async.yml` | Use `tokio::sync::Mutex` in async | LOW | Yes (ast-grep) |
| use-char-indices | `C:\Users\david\.claude\rules\rust\use-char-indices.yml` | Iterate UTF-8 correctly | LOW | Yes (ast-grep) |

### 2d — Safety / API Design / Code Quality

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| avoid-static-mut | `C:\Users\david\.claude\rules\rust\avoid-static-mut.yml` | M-AVOID-STATICS — atomics or `OnceLock` | LOW | Yes (ast-grep + clippy) |
| no-glob-reexport | `C:\Users\david\.claude\rules\rust\no-glob-reexport.yml` | M-NO-GLOB-REEXPORTS — explicit re-exports | LOW (informs analogous PS export discipline) | Yes (ast-grep) |
| avoid-public-arc-box | `C:\Users\david\.claude\rules\rust\avoid-public-arc-box.yml` | M-AVOID-WRAPPERS — don't leak `Arc<T>`/`Box<T>` | LOW | Yes (ast-grep) |
| prefer-pathbuf | `C:\Users\david\.claude\rules\rust\prefer-pathbuf.yml` | M-STRONG-TYPES + M-IMPL-ASREF — `impl AsRef<Path>` | MEDIUM — informs `Resolve-CacheRoot` design (PS already uses string paths but the analogous principle: validate before use) | Yes (ast-grep) |
| require-mimalloc | `C:\Users\david\.claude\rules\rust\require-mimalloc.yml` | Binary crates set `#[global_allocator]` | LOW | Yes (ast-grep) |
| avoid-println | `C:\Users\david\.claude\rules\rust\avoid-println.yml` | Use structured logging (`tracing`) | MEDIUM — direct analogue to PS avoid-write-host | Yes (ast-grep) |
| prefer-expect-over-allow | `C:\Users\david\.claude\rules\rust\prefer-expect-over-allow.yml` | M-LINT-OVERRIDE-EXPECT — use `#[expect(...)]` | LOW | Yes (ast-grep) |

### 2e — Cargo Lints (TOML)

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| recommended-cargo-lints.toml | `C:\Users\david\.claude\rules\rust\recommended-cargo-lints.toml` | `[lints]` block to copy into Rust projects | MEDIUM — `Test-BuildEnvironment` could surface missing lints in user repos as advisory | Yes (rustc/clippy at build time, once deployed) |

---

## Section 3 — General / Core Rules

Cross-cutting structural rules. Most are language-tagged but the *intent* applies to PowerShell.

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| canonical-files | `C:\Users\david\.claude\rules\canonical-files.yml` | Block `enhanced_*`, `simple_*`, `improved_*` duplicates | HIGH — informs `Public/*.ps1` naming hygiene during refactors | Manual review (Rust-tagged but principle is universal) |
| solid-duplicated-http-proxy | `C:\Users\david\.claude\rules\solid-duplicated-http-proxy.yml` | DRY for HTTP proxy patterns | LOW (no HTTP code in module) | Not applicable |
| doc-status | `C:\Users\david\.claude\rules\core\doc-status.yml` | Flag `TODO`/`FIXME`/`INCOMPLETE`/`DEPRECATED` markers | MEDIUM — surfaces tech debt in PS comments | Yes (ast-grep) |
| fix-empty-catch | `C:\Users\david\.claude\rules\core\fix-empty-catch.yml` | C# `catch { }` → `catch (Exception) { }` | MEDIUM (analogue: PS `catch { }` should at least log via `Write-Verbose` or rethrow) | Not applicable to PowerShell |
| flag-absolute-paths-rs | `C:\Users\david\.claude\rules\core\flag-absolute-paths-rs.yml` | Detect hard-coded absolute paths in Rust | LOW (Rust-specific) | Yes (ast-grep) |
| flag-hardcoded-defaults-rs / -cs / -json | `C:\Users\david\.claude\rules\core\flag-hardcoded-defaults-*.yml` | Defaults should be in config, not source | MEDIUM — analogue: cache-root fallbacks in `Private/Environment.ps1` should be discoverable, not literal | Yes (ast-grep) |
| flag-hardcoded-endpoints-rs / -cs / -json | `C:\Users\david\.claude\rules\core\flag-hardcoded-endpoints-*.yml` | URLs/ports must be config-driven | LOW (no network endpoints) | Yes (ast-grep) |
| prefer-uv-python | `C:\Users\david\.claude\rules\core\prefer-uv-python.yml` | Bare `python`/`pip` is forbidden — use `uv run` | LOW (no Python in module) | Yes (ast-grep) |

---

## Section 4 — Security Rules — `C:\Users\david\.claude\rules\security\`

| Rule | Path | Enforces | CargoTools Relevance | Auto-enforced? |
|---|---|---|---|---|
| no-eval | `C:\Users\david\.claude\rules\security\no-eval.yml` | JS-tagged: block `eval()` (RCE) | HIGH (analogue) — paired with `no-invoke-expression` for PS | Not applicable to PowerShell directly |
| no-hardcoded-secrets | `C:\Users\david\.claude\rules\security\no-hardcoded-secrets.yml` | TS-tagged: secret-shaped variable names with literal strings | MEDIUM — wrapper handles env vars; ensure no literal credentials creep in | Yes (ast-grep, manual review for PS) |
| no-innerhtml | `C:\Users\david\.claude\rules\security\no-innerhtml.yml` | Block `.innerHTML` (XSS) | LOW (no HTML output) | Not applicable |

---

## Section 5 — Cross-Cutting Standards

Located in `C:\Users\david\.claude\rules\` root and `utils/`.

| Document | Path | Purpose | CargoTools Relevance |
|---|---|---|---|
| ENFORCEMENT_PLAN | `C:\Users\david\.claude\rules\ENFORCEMENT_PLAN.md` | Defines 4-layer enforcement: IDE → pre-commit → CI → weekly audit | HIGH — template for PS pre-commit hook + GH Actions workflow proposed in `RULES_INTEGRATION.md` |
| GUIDELINES_COMPLIANCE | `C:\Users\david\.claude\rules\GUIDELINES_COMPLIANCE.md` | M-* guideline → enforcement mechanism matrix | HIGH — pattern for documenting which CargoTools test/hook covers which design rule |
| utils/async-function | `C:\Users\david\.claude\rules\utils\async-function.yml` | Reference patterns | LOW |
| utils/common-patterns | `C:\Users\david\.claude\rules\utils\common-patterns.yml` | Reference patterns | LOW |
| utils/console-usage | `C:\Users\david\.claude\rules\utils\console-usage.yml` | Reference patterns | MEDIUM (mirrors avoid-write-host intent) |
| utils/security-sensitive | `C:\Users\david\.claude\rules\utils\security-sensitive.yml` | Reference patterns for security-critical regions | MEDIUM |

---

## Cross-references

- `RULES_INTEGRATION.md` — which of these are currently enforced in CargoTools, gaps to close, and CI proposal
- `docs/AGENTS.md` — which agent owns enforcement of each rule category
- `..\..\..\..\..\.claude\CLAUDE.md` (`C:\Users\david\.claude\CLAUDE.md`) — global framework, agent map, MCP servers
