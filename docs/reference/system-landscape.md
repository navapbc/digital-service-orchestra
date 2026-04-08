---
last_synced_commit: acb4331f172604692cdddec96c5814eb77abc37d
---

# System Landscape Reference

This document describes the structural components, boundaries, and resolution mechanisms of the DSO plugin. It reflects the current state of the system.

## Plugin Root Resolution (Shim)

The DSO shim (`.claude/scripts/dso`) resolves `DSO_ROOT` at dispatch time using a four-step priority chain. The first step that produces a value wins; subsequent steps are skipped.

| Step | Source | Mechanism |
|------|--------|-----------|
| 1 | Environment variable | `$CLAUDE_PLUGIN_ROOT` — explicit operator override; highest priority |
| 2 | Config file | `dso.plugin_root` key in `.claude/dso-config.conf` at the git repo root; supports relative paths (resolved against repo root) |
| 3 | Sentinel self-detection | `$REPO_ROOT/plugins/dso/.claude-plugin/plugin.json` exists → `DSO_ROOT` set to `$REPO_ROOT/plugins/dso` automatically; zero configuration required |
| 4 | Error exit | Non-zero exit with instructions to set `CLAUDE_PLUGIN_ROOT` or `dso.plugin_root` |

After resolution, `DSO_ROOT` is exported as `CLAUDE_PLUGIN_ROOT` (unless `CLAUDE_PLUGIN_ROOT` was already set by the caller). `PROJECT_ROOT` is also exported as the git repo root for use by dispatched scripts.

ADR: `docs/adr/0001-shim-sentinel-self-detection.md`

## Command Wrappers

`.claude/commands/*.md` files provide one wrapper per user-invocable skill (26 total). Each wrapper uses Claude Code's shell preprocessing to detect whether the DSO plugin is installed via the marketplace:

```
!`bash -c 'timeout 3 claude plugin list 2>/dev/null | grep -q "digital-service-orchestra" && echo "PLUGIN_DETECTED" || echo "LOCAL_FALLBACK"'`
```

- **PLUGIN_DETECTED**: Invoke the skill via the Skill tool (`/dso:<skill-name>`).
- **LOCAL_FALLBACK**: Read `plugins/dso/skills/<skill-name>/SKILL.md` inline and follow its instructions.

Wrapper files live in `.claude/commands/` and are named after the skill (e.g., `sprint.md`, `fix-bug.md`). They are not skill files — they are dispatch shims that choose between marketplace and local invocation.

## Portability Lint

`plugins/dso/scripts/check-portability.sh` detects hardcoded home-directory paths that break portability across machines and CI environments.

**Patterns flagged**:
- `/Users/<username>/` — macOS home directories
- `/home/<username>/` — Linux home directories

**Inline suppression**: Append `# portability-ok` to any line to exempt it from the check. Use this only for lines where the hardcoded path is intentional and documented (e.g., example output in documentation, test fixture data).

**Operation modes**:
- With file arguments: scans the specified files directly.
- Without arguments: discovers staged files via `git diff --cached --name-only --diff-filter=ACM`.

**Exit codes**: `0` — no violations; `1` — one or more violations.

**Hook registration**: Registered as a pre-commit hook in `.pre-commit-config.yaml`. Violations block commits. Violations are printed to stderr in `file:line` format.

**CI validation**: `.github/workflows/portability-smoke.yml` runs the shim self-detection path in a clean Ubuntu container to validate zero-config portability on each push.

## Sprint Self-Healing Loop

The `/dso:sprint` orchestrator includes a self-healing layer that detects and routes mid-implementation gaps at four lifecycle checkpoints. When a checkpoint fires, the orchestrator writes a `REPLAN_TRIGGER` comment to the epic ticket before acting and a `REPLAN_RESOLVED` comment after successful re-planning.

| Checkpoint | Phase | Detection Mechanism | Action |
|---|---|---|---|
| Drift detection | Phase 1 Step 6 | `sprint-drift-check.sh` compares git history since task creation against each story's file impact table | Re-invoke `implementation-plan` for affected stories |
| Confidence failure | Phase 5 Step 1a2 | Count `UNCERTAIN` signals per story across batch iterations; threshold: 2 | Re-invoke `implementation-plan` for the story (Phase 3 double-failure detection) |
| Validation failure | Step 10a | All tasks closed but story done-definition validation fails | Create TDD remediation tasks via `implementation-plan` |
| Out-of-scope review | Step 7a / Step 13a | `sprint-review-scope-check.sh` identifies review findings for files outside task scope | Create tasks for out-of-scope files via `implementation-plan` |

### Confidence Signal

Task-execution sub-agents emit exactly one confidence signal per task in their final report block:

- `CONFIDENT` — agent has high confidence the task is correctly and completely implemented.
- `UNCERTAIN:<reason>` — agent lacks confidence; reason must be non-empty.

A missing or malformed confidence signal is treated as `UNCERTAIN` (fail-safe default). Signals are tracked per story (not per task ID) so that task replacement cannot reset the counter.

Contract: `plugins/dso/docs/contracts/confidence-signal.md`

### Observability Signals

The self-healing loop writes structured comments to the epic ticket for audit and resume-anchor scanning:

- `REPLAN_TRIGGER: <type> — <description>` — written before re-planning. Valid types: `drift`, `failure`, `validation`, `review`.
- `REPLAN_RESOLVED: <tier> — <description>` — written after successful re-planning. Valid tiers: `implementation-plan`, `brainstorm`.
- `INTERACTIVITY_DEFERRED: brainstorm — <reason>` — written in non-interactive mode when brainstorm escalation is needed but cannot block for user input. Replaced REPLAN_RESOLVED in this case.

Contract: `plugins/dso/docs/contracts/replan-observability.md`

### Scripts

- `plugins/dso/scripts/sprint-drift-check.sh` — detects codebase drift by comparing git history against story file impact tables.
- `plugins/dso/scripts/sprint-review-scope-check.sh` — identifies review findings for files outside the story's defined task scope.

## Agent Fallback

When a named sub-agent (dispatched via `subagent_type`) is unavailable or dispatch fails, agents read the agent definition inline from `plugins/dso/agents/<agent-name>.md`. The `<agent-name>` is the portion of `subagent_type` after the `dso:` prefix (e.g., `subagent_type: dso:complexity-evaluator` → `plugins/dso/agents/complexity-evaluator.md`). The file contents are used as a prompt and the agent logic runs inline.

All named agents are defined in `plugins/dso/agents/`. Agent routing configuration: `config/agent-routing.conf`.

## Test Quality Overlay

The `dso:code-reviewer-test-quality` agent (opus) is an overlay reviewer that evaluates test code in diffs for bloat patterns. It is dispatched by the review pipeline when the classifier flags `test_quality_overlay: true` (triggered when the diff modifies files under `tests/`).

**Detection patterns (5 categories)**:

| Pattern | Severity |
|---------|----------|
| Source-file-grepping (grep/cat/ast.parse in test assertions) | critical |
| Tautological tests (assert on mock setup, not behavior) | critical |
| Change-detector tests (asserts on private/internal names) | important |
| Implementation-coupled assertions (internal state, not outputs) | important |
| Existence-only assertions (sole assertion is hasattr/test -f) | important |

**Dispatch mode**: Parallel alongside the tier reviewer when classifier flags the overlay at classification time. Serial (after tier review) when the tier reviewer emits `test_quality_overlay_warranted: yes`. Overlay fallback (`overlay_dispatch_with_fallback`) ensures overlay failures do not block commits — findings are omitted and a warning is emitted.

**Authority**: `plugins/dso/skills/shared/prompts/behavioral-testing-standard.md` (5-rule standard). Agent definition: `plugins/dso/agents/code-reviewer-test-quality.md`.

**Sprint integration**: The redundant sprint-level test coverage enforcement step (previously Step 1a2/1a3) has been removed. Test quality enforcement is now exclusively handled by this overlay, which fires on any diff touching test files regardless of whether the diff was produced by sprint, fix-bug, or any other path.

## Pre-Commit Test Quality Gate

`plugins/dso/hooks/pre-commit-test-quality-gate.sh` is a pre-commit hook that statically detects test anti-patterns in staged test files before they enter the repository. It operates only on files matching `tests/` and only on diff-added lines to avoid flagging pre-existing code.

**Configuration** (`.claude/dso-config.conf`):

| Key | Values | Default | Effect |
|-----|--------|---------|--------|
| `test_quality.enabled` | `true` / `false` | `true` | `false` exits 0 immediately (no checks run) |
| `test_quality.tool` | `bash-grep` / `semgrep` / `disabled` | `bash-grep` | Selects detection engine |

**Tool selection**:
- `bash-grep`: zero-dependency grep-based detection; default fallback
- `semgrep`: uses custom rules at `plugins/dso/hooks/semgrep-rules/test-anti-patterns.yaml`; requires Semgrep installed (gate disables gracefully when Semgrep is absent)
- `disabled`: equivalent to `test_quality.enabled=false`

**Timeout budget**: 15 seconds (enforced via `pre-commit-wrapper.sh`). The gate exits 0 on timeout to avoid blocking commits on slow machines.

**Graceful degradation**: When `test_quality.tool=semgrep` and Semgrep is not installed, the gate logs a warning and exits 0. It does not fall back to `bash-grep` automatically — set `test_quality.tool=bash-grep` explicitly for zero-dependency detection.

**Hook registration**: `.pre-commit-config.yaml` entry `pre-commit-test-quality-gate`. Runs at `pre-commit` stage on files matching `^tests/`.
