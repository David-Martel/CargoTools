# Agent Integration Guide

> Multi-agent coordination guide for CargoTools development. Pairs with [`.claude/rules/INDEX.md`](../.claude/rules/INDEX.md) and [`.claude/RULES_INTEGRATION.md`](../.claude/RULES_INTEGRATION.md).

## 1. Overview

**What agents are.** Specialist sub-agents are LLM personas defined in markdown files at `C:\Users\david\.claude\agents\` (~77 total). Each `.md` file declares a name, model tier (sonnet/opus), description, and an in-prompt instruction set.

**How to spawn one.** Use the `Task` tool with `subagent_type=<name>` (without the `.md`). Example:

```text
Task(subagent_type="powershell-pro",
     description="Add WSL native cache support",
     prompt="Add a --wsl-cache=native flag to Invoke-CargoWsl that ...")
```

**Coordination layer.** All agents on this machine MUST use the agent-bus (Redis + PostgreSQL service at `http://localhost:8400`). Protocol details: `C:\Users\david\.agents\AGENT_COORDINATION.md`. Quick commands appear in `C:\Users\david\.claude\CLAUDE.md` under AGENT BUS COORDINATION.

**Skills.** Skills (Skill tool) are reusable prompt fragments. The most relevant for CargoTools work: `cargo-build`, `superpowers:test-driven-development`, `superpowers:systematic-debugging`, `superpowers:requesting-code-review`, `tools:test-harness`, `tools:security-scan`.

---

## 2. Most-Relevant Agents

Each section: source path, one-paragraph profile, example CargoTools tasks, suggested companion skills.

### 2.1 powershell-pro (PRIMARY)

- **Source**: `C:\Users\david\.claude\agents\powershell-pro.md`
- **Model**: sonnet
- **Profile**: Elite PowerShell architect, debugger, and performance engineer with deep expertise across Windows PowerShell 5.1, PowerShell 7+, and PowerShell Core. Masters the runtime/pipeline/execution engine, .NET/.NET Core integration via `Add-Type`, performance optimization (StringBuilder, `List[T]`, runspaces, `ForEach-Object -Parallel`), and module deployment patterns (.psd1 manifests, Public/Private organization, Pester integration).

- **Example CargoTools tasks**:
  1. Refactor `Private/Environment.ps1` `Resolve-LldLinker` for clarity and add a `-PassThru` switch returning a structured object.
  2. Optimize `Private/BuildOutput.ps1` extension-based copy: replace string concatenation with `StringBuilder`, batch file enumeration.
  3. Add a new `Public/Invoke-CargoZigBuild.ps1` mirroring the manual `for`-loop arg-parser pattern documented in `.claude/CLAUDE.md`.

- **Companion skills**: `superpowers:test-driven-development`, `cargo-build`, `tools:refactor-clean`

### 2.2 rust-pro

- **Source**: `C:\Users\david\.claude\agents\rust-pro.md`
- **Model**: sonnet
- **Profile**: Rust expert specializing in safe, performant systems programming — ownership, lifetimes, traits, async/await, Tokio, safe concurrency, zero-cost abstractions. Already aware of CargoTools v0.9.0 and instructed to call `Invoke-CargoWrapper` instead of bare `cargo` on this machine.

- **Example CargoTools tasks**:
  1. Validate that `Initialize-CargoEnv` env-var defaults match what current Rust toolchains expect (e.g., new `RUSTFLAGS` semantics, lld linker invocation conventions).
  2. Author the canonical Rust example used in `Test-BuildEnvironment` to exercise sccache/lld/nextest end-to-end.
  3. Audit cargo flag pass-through in `Invoke-CargoRoute` against the latest stable cargo CLI surface.

- **Companion skills**: `cargo-build`, `superpowers:systematic-debugging`

### 2.3 code-reviewer

- **Source**: `C:\Users\david\.claude\agents\code-reviewer.md`
- **Model**: sonnet
- **Profile**: Senior code reviewer with deep expertise in configuration security and production reliability. Heightened scrutiny for configuration changes, magic numbers, connection-pool/threading defaults. Runs `git diff` first, classifies file types, applies type-specific review strategies.

- **Example CargoTools tasks**:
  1. Review version-bump diffs (`CargoTools.psd1` `ModuleVersion` + `CHANGELOG.md`) before each release.
  2. Critique any new env-var added to `Private/Environment.ps1` for naming consistency, default safety, and documentation completeness.
  3. Review the wrapper-rewrite branches owned by the parallel agent before merge.

- **Companion skills**: `superpowers:requesting-code-review`, `code-review:code-review`, `tools:parallel-review`

### 2.4 debugger

- **Source**: `C:\Users\david\.claude\agents\debugger.md`
- **Model**: sonnet
- **Profile**: Root-cause analysis specialist. Captures error/stack trace, isolates failure, implements minimal fix, verifies. Focuses on underlying issues, not symptoms.

- **Example CargoTools tasks**:
  1. Diagnose flaky `Invoke-Pester` runs, especially the cross-process mutex test in `Tests/Common.Tests.ps1`.
  2. Investigate why `Initialize-CargoEnv` sometimes fails to set `RUSTC_WRAPPER` on machines where sccache is on PATH but not yet started.
  3. Trace `Invoke-CargoWsl` shell-string mismatches when `bash -lc` quoting interacts with paths containing spaces.

- **Companion skills**: `superpowers:systematic-debugging`, `tools:smart-debug`, `tools:debug-trace`

### 2.5 error-detective

- **Source**: `C:\Users\david\.claude\agents\error-detective.md`
- **Model**: sonnet
- **Profile**: Log analysis and pattern recognition. Regex extraction, stack-trace correlation across systems, anomaly detection. Pairs with `debugger` when failures span multiple test runs or build outputs.

- **Example CargoTools tasks**:
  1. Pattern-mine cargo JSON diagnostic streams handled by `Private/LlmOutput.ps1` to surface common compile-failure shapes.
  2. Build a regex catalogue for the diagnostics formatter in `Private/Progress.ps1`.

- **Companion skills**: `tools:error-analysis`, `tools:error-trace`

### 2.6 test-automator

- **Source**: `C:\Users\david\.claude\agents\test-automator.md`
- **Model**: sonnet
- **Profile**: Test pyramid (unit-heavy, integration-mid, E2E-light), AAA pattern, deterministic tests, fixture/mock factories, CI integration, coverage analysis.

- **Example CargoTools tasks**:
  1. Expand `Tests/Environment.Tests.ps1` with a fixture for the WSL/Docker route classifier.
  2. Add Pester tests for the new TOML config primitives in `Private/ConfigFiles.ps1` (especially `Merge-TomlConfig` edge cases).
  3. Author E2E tests that build a small Rust crate end-to-end through `Invoke-CargoWrapper` with sccache enabled.

- **Companion skills**: `superpowers:test-driven-development`, `tools:test-harness`

### 2.7 security-auditor

- **Source**: `C:\Users\david\.claude\agents\security-auditor.md`
- **Model**: opus
- **Profile**: OWASP-aware reviewer focusing on auth flows, input validation, secret handling, and dependency scanning. Defense-in-depth; least privilege; never trust input.

- **Example CargoTools tasks**:
  1. Review every place wrapper code constructs shell strings (`bash -lc`, Docker `--entrypoint`) to confirm the `CargoTools.ShellEscape` whitelist still holds.
  2. Audit the cargo-deny preflight integration introduced in v0.8 — verify it cannot be silently bypassed by env-var override.
  3. Validate that `Private/ConfigFiles.ps1` TOML writes use `.bak` correctly and never write secrets.

- **Companion skills**: `tools:security-scan`, `superpowers:requesting-code-review`

### 2.8 performance-engineer

- **Source**: `C:\Users\david\.claude\agents\performance-engineer.md`
- **Model**: opus
- **Profile**: Profile → optimize bottlenecks → measure. Caching strategies, throughput tuning, p50/p99 budgets. Always measures before optimizing.

- **Example CargoTools tasks**:
  1. Profile `Initialize-CargoEnv` cold-start cost; ~30 env vars + sccache health check are non-trivial on first call.
  2. Benchmark sccache hit-rate impact of `CARGO_INCREMENTAL=0` enforcement on representative crates.
  3. Quantify lld-link vs `link.exe` link-time delta on a representative project for the `--use-lld` decision matrix.

- **Companion skills**: `superpowers:systematic-debugging`, `cargo-build`

### 2.9 devops-troubleshooter

- **Source**: `C:\Users\david\.claude\agents\devops-troubleshooter.md`
- **Model**: sonnet
- **Profile**: Production-incident response. Logs/metrics/traces first, hypothesis-driven, document for postmortem, minimal-disruption fixes, add monitoring to prevent recurrence.

- **Example CargoTools tasks**:
  1. Diagnose CI failures once a GitHub Actions workflow is added (proposed in `.claude/RULES_INTEGRATION.md`).
  2. Investigate `Test-BuildEnvironment` warnings reported by users (Defender exclusions, Dev Drive misconfiguration).

- **Companion skills**: `superpowers:systematic-debugging`, `workflows:incident-response`

### 2.10 docs-architect

- **Source**: `C:\Users\david\.claude\agents\docs-architect.md`
- **Model**: opus
- **Profile**: Long-form technical documentation from existing codebases. Architecture analysis, design-decision extraction, navigable structure, diagrams.

- **Example CargoTools tasks**:
  1. Author `docs/architecture.md` describing the routing chain (`cargo.ps1` → `cargo-route.ps1` → `Invoke-CargoRoute` → four backends).
  2. Document the C# inline-types pattern (`ShellEscape`, `ProcessMutex`, `FileCopy`) and the AppDomain-persistence gotcha for new contributors.

- **Companion skills**: `tools:doc-generate`

### 2.11 legacy-modernizer (bonus)

- **Source**: `C:\Users\david\.claude\agents\legacy-modernizer.md`
- **Model**: sonnet
- **Profile**: Strangler-fig refactors, dependency upgrades, backward compatibility, test coverage on legacy code. Useful for graduating PS 5.1-only patterns to dual-edition (5.1 + 7+) cleanly.

- **Example CargoTools tasks**:
  1. Migrate any remaining `Hashtable` usage to `[ordered]@{}` for deterministic enumeration.
  2. Identify and update PS 5.1 idioms that have better PS 7 equivalents (ternary `?:`, `??`, `?.`).

- **Companion skills**: `workflows:legacy-modernize`

---

## 3. Workflow Recipes

Concrete multi-agent sequences for common CargoTools tasks. Spawn agents via the `Task` tool with the literal `subagent_type` shown.

### Recipe A — Add new wrapper feature

Use case: ship a new flag (e.g., `--wsl-native`) end-to-end with tests and review.

```text
1. Skill(superpowers:brainstorming)            # explore design first
2. Task(subagent_type="powershell-pro",
        prompt="Implement <feature> in Public/Invoke-CargoWsl.ps1 ...")
3. Task(subagent_type="test-automator",
        prompt="Add Pester tests for <feature> in Tests/Wsl.Tests.ps1 ...")
4. Skill(superpowers:requesting-code-review)
5. Task(subagent_type="code-reviewer",
        prompt="Review PR adding <feature>; focus on flag-parsing pattern and env var documentation")
6. Bus: post_message topic=ownership BEFORE editing Public/Invoke-CargoWsl.ps1
        post_message topic=*-findings schema=finding when each agent completes
```

### Recipe B — Diagnose flaky test

```text
1. Skill(superpowers:systematic-debugging)
2. Task(subagent_type="debugger",
        prompt="Tests/Common.Tests.ps1 'cross-process mutex' is flaky on CI; reproduce and diagnose")
3. If multi-machine pattern emerges:
     Task(subagent_type="error-detective",
          prompt="Search PowerShell module logs for mutex-handle disposal errors")
4. Task(subagent_type="powershell-pro",
        prompt="Apply fix from debugger; ensure CargoTools.ProcessMutex C# type unchanged
                so users do NOT need a session restart")
```

### Recipe C — Audit security posture

```text
1. Task(subagent_type="security-auditor",
        prompt="Audit shell-string construction sites and cargo-deny preflight in v0.8")
2. Skill(tools:security-scan)
3. Task(subagent_type="powershell-pro",
        prompt="Implement remediations from security-auditor; preserve CargoTools.ShellEscape API")
4. Task(subagent_type="test-automator",
        prompt="Add regression tests for each finding")
```

### Recipe D — Optimize build perf

```text
1. Task(subagent_type="performance-engineer",
        prompt="Profile Initialize-CargoEnv cold-start; produce before/after measurements
                per Learned Rule #4 (Validate perf claims)")
2. Skill(cargo-build)
3. Task(subagent_type="powershell-pro",
        prompt="Apply optimizations recommended by performance-engineer;
                must include benchmark evidence in the commit message")
4. Task(subagent_type="code-reviewer",
        prompt="Verify benchmark methodology and that no behavior changed")
```

### Recipe E — Major refactor

```text
1. Skill(superpowers:writing-plans)
2. Task(subagent_type="legacy-modernizer",
        prompt="Plan migration of Hashtable -> [ordered]@{} across Private/*.ps1")
3. Skill(superpowers:executing-plans)
4. Task(subagent_type="powershell-pro",
        prompt="Execute plan, file by file")
5. Task(subagent_type="test-automator",
        prompt="Add tests pinning enumeration order where it now matters")
6. Task(subagent_type="code-reviewer",
        prompt="Final pass; surface any breaking-change risk for downstream wrappers/")
```

---

## 4. Agent-Bus Coordination

Quoted from `C:\Users\david\.claude\CLAUDE.md` (AGENT BUS COORDINATION section):

> Use the shared Redis-backed `agent-bus` as the default coordination channel when more than one agent is active on the same machine. ... Preferred commands (Rust CLI — `~/bin/agent-bus.exe`): `agent-bus health`, `agent-bus send`, `agent-bus read`, `agent-bus watch`, `agent-bus ack`, `agent-bus presence`, `agent-bus serve --transport stdio`.

The three commands an agent operating in this repo MUST run:

```powershell
# 1. Announce presence on session start
agent-bus-http.exe presence --agent claude --status online --capability mcp --ttl-seconds 300

# 2. Claim ownership of a file BEFORE editing it
agent-bus-http.exe send --from-agent claude --to-agent all --topic "ownership" --body "claiming Public/Invoke-CargoWsl.ps1 for wrapper rewrite" --tags "repo:CargoTools"

# 3. Acknowledge incoming directives addressed to you
agent-bus-http.exe ack --agent claude --message-id <id>
```

Best practices (full list in `C:\Users\david\.agents\AGENT_COORDINATION.md`):

- Use stable agent IDs: `claude`, `codex`, `gemini`, `copilot`.
- Start a watcher (`agent-bus watch --agent claude --history 10`) before parallel work.
- Schema discipline: `*-findings` → `--schema finding`; `status`/`ownership`/`coordination` → `--schema status`.
- Batch 3–5 findings per message (max 2000 chars). Tag with `repo:CargoTools`.
- Never send secrets through the bus.

Cross-references:

- Full protocol: `C:\Users\david\.agents\AGENT_COORDINATION.md`
- Skills mapping: `C:\Users\david\.agents\SKILLS.md`
- Rust development guide: `C:\Users\david\.agents\rust-development-guide.md`
- Global framework: `C:\Users\david\.claude\CLAUDE.md`
- Rules index: [`../.claude/rules/INDEX.md`](../.claude/rules/INDEX.md)
- Rules integration: [`../.claude/RULES_INTEGRATION.md`](../.claude/RULES_INTEGRATION.md)
