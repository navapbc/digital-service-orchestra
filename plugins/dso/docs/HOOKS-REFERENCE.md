# Hooks & Gates Reference

Self-enforcing pre-commit hooks, the test/review gates, the hook error handler, and the stack-agnostic gate pipeline. CLAUDE.md no longer enumerates these — agents learn the rules at error time. This file is the reference for plugin authors and for debugging hook failures.

## Pre-commit hooks (self-enforcing)

Each hook prints its own error and fix instructions. Suppression annotations are inline comments in the offending file.

| Hook | Purpose | Suppression |
|------|---------|-------------|
| `check-portability.sh` | Hardcoded paths in scripts | `# portability-ok` |
| `check-shim-refs.sh` | Direct plugin script refs in host-project files; use `.claude/scripts/dso <script-name>` shim instead | `# shim-exempt: <reason>` |
| `check-contract-schemas.sh` | Contract markdown structure | (none) |
| `check-referential-integrity.sh` | Dead path references in instruction files | (none) |
| `check-plugin-self-ref.sh` | Blocks literal plugin-root paths in plugin scripts; use `_PLUGIN_ROOT` / `_PLUGIN_GIT_PATH` | (no annotation — absolute) |
| `pre-commit-enforcement-boundary-check.sh` | Enforces that enforcement hooks do not source the hook-error-handler library | (none) |
| `check-rule-anchors.sh` | Validates backticked CLAUDE.md anchor citations (`` `rule:<slug>` ``, `` `invariant:<slug>` ``, `` `always:<slug>` ``) point at anchors defined in CLAUDE.md (PR-D / R13) | (none — fix the citation or add the anchor) |
| `post-commit-override-cleanup.sh` | Deletes `override.token` after a successful commit (contract: `commit-override-token.md`) | (none) |
| `write-reviewer-findings.sh` + `resolve-overlay-findings.sh` | Single-writer for `reviewer-findings.json`; resolve-overlay aggregates overlay findings JSONs through the single-writer (rule:reviewer-findings-write) | (none — only named code-reviewer sub-agents may write findings) |

## Review gate (two-layer)

- **Layer 1** — `pre-commit-review-gate.sh` (git hook) enforces `review-gate-allowlist.conf` allowlist + `review-status` + diff hash.
- **Layer 2** — under plugin-managed installs the live path is `plugin.json` PreToolUse Bash matcher → `dispatchers/pre-bash.sh` → `hook_review_bypass_sentinel` (in `hooks/lib/review-gate-bypass-sentinel.sh`). The wrapper `review-gate.sh` is preserved as the canonical entry point for **files-only installs** (host projects that install DSO as files, not as a Claude Code plugin, wire this wrapper directly via `settings.json`). Layer 2 blocks `--no-verify`, `core.hooksPath=` overrides, and git plumbing bypasses.

Both layers handle MERGE_HEAD and REBASE_HEAD via `merge-state.sh`. `--no-verify` cannot bypass Layer 2 — it is a Claude Code tool-use hook, not a git hook.

**Exception**: when `enforcement.strategy=ci`, both layers emit `HOOK_GATE: skipped reason=enforcement.strategy=ci` and skip enforcement; CI enforces via the parity-uplifted llm-review job.

## Plan-review gate (PreToolUse on ExitPlanMode)

Under plugin-managed installs: `plugin.json` PreToolUse ExitPlanMode matcher → `dispatchers/pre-exitplanmode.sh` → `hook_plan_review_gate` (in `hooks/lib/session-misc-functions.sh`). Wrapper `plan-review-gate.sh` is the files-only-install entry point. The gate blocks `ExitPlanMode` unless `$ARTIFACTS_DIR/plan-review-status` exists with first line `passed`. The marker is written by the `/dso:plan-review` skill after a successful review.

## PreToolUse / PostToolUse guards

Hooks that fire during agent tool-use to block bypass vectors or guard load-bearing invariants. Wired under plugin-managed installs via `plugin.json` matchers; under files-only installs, individually via `settings.json`.

| Hook | Trigger event | Purpose |
|------|---------------|---------|
| `cascade-circuit-breaker.sh` | PreToolUse Edit/Write | Blocks Edit/Write when the consecutive-fix cascade threshold is reached (`` `rule:cascade-circuit` ``) |
| `track-cascade-failures.sh` | PostToolUse Bash | Counter increment on test-fail commands; feeds the cascade-circuit-breaker |
| `tool-logging.sh` + `tool-logging-summary.sh` | PreToolUse + PostToolUse / Stop | Per-tool JSONL logging for session analytics; summary emitted at Stop |
| `review-integrity-guard.sh` | PreToolUse Bash | Blocks direct Bash writes to `review-status` / `reviewer-findings` files (`` `rule:reviewer-findings-write` ``) |
| `taskoutput-block-guard.sh` | PreToolUse TaskOutput | Blocks `block=false` (sub-agent suppression vector) |
| `worktree-bash-guard.sh` | PreToolUse Bash | Blocks `cd` into the main repo from a worktree session (`` `rule:no-edit-main-from-worktree` ``) |
| `worktree-edit-guard.sh` | PreToolUse Edit/Write/MultiEdit | Blocks edits targeting the main repo from a worktree (`` `rule:no-edit-main-from-worktree` ``) |
| `title-length-validator.sh` | PreToolUse Edit/Write | Blocks ticket title updates that exceed 255 chars (Jira sync limit) |
| `track-tool-errors.sh` | PostToolUse (failure path) | Categorizes and counts tool-use errors into `~/.claude/tool-errors.jsonl` |

## SessionStart / Stop hooks

| Hook | Trigger event | Purpose |
|------|---------------|---------|
| `hook_inject_using_dso` (lib function in `session-misc-functions.sh`, invoked via `dispatchers/session-start.sh`) | SessionStart | Injects the `using-dso` skill bootstrap (the rule that every session must invoke a matching skill before responding) |
| `session-safety-check.sh` | SessionStart | Scans `~/.claude/logs/dso-hook-errors.jsonl`; emits warnings and creates bug tickets for recurring errors |
| `review-stop-check.sh` | Stop | Warns about uncommitted, unreviewed changes when a session ends |

## Test gate

`pre-commit-test-gate.sh` verifies test status per staged file.

- Centrality-aware (`record-test-status.sh`): high fan-in files trigger full suite.
- Use `--restart` to clear stale status when stuck on a previous failed recording.
- Config: `test_gate.*` in `dso-config.conf`.
- `.test-index` maps source → tests.
- **RED marker format**: `tests/foo.sh [test_name]` (space before bracket required) tolerates intentionally failing RED tests at/after that boundary.

**Status values**: `passed`, `failed`, `timeout`, `resource_exhaustion` (distinct from `failed`; written by `record-test-status.sh` when exit 254 + EAGAIN stderr pattern is detected).

**Severity hierarchy**: `timeout > failed > resource_exhaustion > passed`.

## Test quality gate

`pre-commit-test-quality-gate.sh` detects anti-patterns in staged test files: source-file-grepping, tautological tests, change-detector tests, implementation-coupled assertions, existence-only assertions.

- Scoped to files matching `^tests/`.
- Config: `test_quality.enabled` (default `true`); `test_quality.tool` (`bash-grep` | `semgrep` | `disabled`, default `bash-grep`).
- When `semgrep` is selected, uses rules at `${CLAUDE_PLUGIN_ROOT}/hooks/semgrep-rules/test-anti-patterns.yaml`.
- Timeout budget: 15 seconds.

## Compliance verifier gate

`pre-commit-compliance-verifier` — pre-commit hook that blocks commits missing required per-step validation artifacts.

**What it reads**: for each of the 5 required steps (`test`, `format`, `lint`, `classifier-dispatch`, `reviewer-record`), it looks for `$ARTIFACTS_DIR/<step>.result` or `$ARTIFACTS_DIR/<step>.skipped`. At least one must be present per step.

**When it blocks**: when any required step artifact is absent (neither `.result` nor `.skipped` present for that step).

**Overlay verification**: also reads `$ARTIFACTS_DIR/classifier-dispatch.result` to check for flagged overlays; looks up findings filenames in `overlay-registry.json`; blocks if any referenced overlay findings file is absent.

**Feature flag**: `hooks.compliance_verifier.enabled` in `dso-config.conf` (default: `true`); or `DSO_COMPLIANCE_VERIFIER_ENABLED=true` env var.

**Legitimate bypass**: use `dso commit-step skip <name> "<reason>"` to generate a `.skipped` marker before committing. Example for `enforcement.strategy=ci`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
_cfg="$REPO_ROOT/.claude/dso-config.conf"
CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$_cfg" | cut -d= -f2-)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
for step in test format lint classifier-dispatch reviewer-record; do
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit-step.sh" skip "$step" "enforcement.strategy=ci"  # shim-exempt: HOOKS-REFERENCE.md example doc — the canonical bypass procedure uses the full plugin-root path so operators can copy-paste verbatim
done
```

## Additional hooks (lifecycle / infrastructure / supporting)

Hook wrappers that don't fit the categories above — primarily lifecycle / infrastructure / artifact-recording. Wired variously: some via `plugin.json` matchers, some via `.pre-commit-config.yaml`, some invoked from other hooks or from agent dispatch.

| Hook | Role |
|------|------|
| `run-hook.sh` | Hook invoker — wraps every plugin.json hook entry, providing consistent logging, timing, and error trapping |
| `check-antipattern-scan-trailer.sh` | Commit-msg gate invoked from `/dso:fix-bug`'s commit step — active only under the `.fix-bug-active` marker; refuses commit when the `Antipattern-Scan` trailer is absent, or when `matches>0` lacks a per-match follow-up artifact (ticket id in trailer / match file in cached diff / capped `# antipattern-ok` annotation). Never gates other skills |
| `check-artifact-versions.sh` | Verifies that installed DSO artifacts (shim, config, pre-commit, ci.yml) carry compatible version stamps against the plugin manifest |
| `check-precondition-emit.sh` | Pre-commit gate — verifies that skills with `EMIT-PRECONDITIONS` landmarks have the corresponding emit logic intact |
| `check-tickets-boundary.sh` | Pre-commit gate — enforces the `<!-- tickets-boundary-ok -->` annotation requirement for files that touch ticket-tracker boundaries |
| `check-validation-failures.sh` | Surfaces accumulated validation failures so they don't get swallowed by individual gate exits |
| `commit-failure-tracker.sh` | PreToolUse Bash — tracks failed commit attempts to feed the cascade-circuit-breaker counter |
| `compute-diff-hash.sh` | Hashes the staged diff for the review-gate's diff-hash invariant (Layer 1); see `REVIEW-WORKFLOW.md` |
| `fix-bug-skill-directive.sh` | PreToolUse — emits the `/dso:fix-bug` skill-directive reminder when bug-class tasks are detected without the skill being invoked |
| `pre-commit-ticket-gate.sh` | Pre-commit gate — enforces ticket-tracker boundary rules; complements `check-tickets-boundary.sh` |
| `pre-push-merged-pr-check.sh` | Pre-push hook — blocks force-pushes that would overwrite a merged PR's content |
| `prepare-commit-msg-override-audit.sh` | prepare-commit-msg hook — audits commits that use override tokens |
| `pre-commit-design-md-lint.sh` | Pre-commit gate — thin wrapper that resolves plugin root and delegates to `design-md-lint.sh`; blocks commits with design.md violations in diff-touched lines; fail-open when `design-md-lint.sh` is absent or on timeout |
| `record-review.sh` | Single-writer for review status — invoked by named code-reviewer agents only (`` `rule:fabrication` ``); reads from `reviewer-findings.json` and writes the review-status sidecar |
| `record-test-exemption.sh` | Records intentional test exemptions (RED markers, xfail rationale) for the test gate's tolerance logic |

## Hook error handler

`${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-error-handler.sh` — shared ERR/EXIT trap library for **non-enforcement** hooks. Source with a fail-open guard, then call `_dso_register_hook_err_handler "hook-name.sh"`. Errors logged to `~/.claude/logs/dso-hook-errors.jsonl` (handler always exits 0, never blocks hook execution).

Enforcement hooks (annotated `# hook-boundary: enforcement`) MUST NOT source this library — `pre-commit-enforcement-boundary-check.sh` enforces this boundary at commit time.

## Gate-tier doctrine (F-02)

Every hook under `$PLUGIN_DIR/hooks/` declares its tier in the file header via a `# DSO-GATE-TIER: A|B|C` comment. The tier governs how the hook behaves on infrastructure failure (timeout, parse error, missing dependency):

- **Tier A — safety-critical.** Verdict routes execution. Must fail **closed** on infrastructure failure. Override requires a paired env-var bypass (`DSO_GATE_BYPASS_<UPPER_NAME>=1` AND non-empty `DSO_GATE_BYPASS_<UPPER_NAME>_REASON`), modeled on the `DSO_ALLOW_EDIT_ON_MAIN` pattern at `hooks/lib/pre-bash-functions.sh:546–551`. Each bypass writes a JSONL audit record to `~/.claude/logs/dso-gate-unavailable.jsonl` and an event-log entry.
- **Tier B — developer-experience.** Hook wrapper, dispatcher non-2 exits, error handler, formatting-hint hooks. Fail open is correct — a broken hook script must not brick an editor session.
- **Tier C — advisory model checks.** Heuristic verdicts that are routing hints, not gates. May degrade, but the degraded state must emit a `GATE_UNAVAILABLE` event the orchestrator can read (via the existing event-log channel).

### Shared helper: `gate-unavailable.sh`

`${CLAUDE_PLUGIN_ROOT}/hooks/lib/gate-unavailable.sh` provides:

- `_dso_gate_unavailable <gate_name> <reason>` — writes a JSONL audit record + stderr signal. Returns 0; Tier A callers should `return 2` afterward to block. Tier C callers proceed with their existing degradation path.
- `_dso_gate_bypass_active <gate_name>` — returns 0 only when both env vars are present. Emits an audit record when active.

### Current tier assignment

| Hook | Tier | Notes |
|------|------|-------|
| `hooks/pre-commit-test-gate.sh` | **A** | Timeout (SIGTERM/SIGURG) emits `GATE_UNAVAILABLE` and exits 2 unless `DSO_GATE_BYPASS_TEST_GATE` set. |
| `hooks/pre-commit-review-gate.sh` | **A** | Empty `CURRENT_HASH` (`compute-diff-hash.sh` failure) emits `GATE_UNAVAILABLE` and exits 2 unless `DSO_GATE_BYPASS_REVIEW_GATE` set. |
| `scripts/pre-commit-wrapper.sh` | **B** | Wrapper fail-open on missing/broken hook is correct — broken hook must not brick session. |
| `hooks/lib/dispatcher.sh` | **B** | Non-2 exits → allow (Tier B contract). |
| `hooks/lib/hook-error-handler.sh` | **B** | Always-exit-0 after logging is correct. |

### Drift detection

`check-gate-tier-headers.sh` verifies every hook in `$PLUGIN_DIR/hooks/` declares a tier via the `# DSO-GATE-TIER:` header. Wired as the `gate-tier-headers-check` pre-commit hook.

## Stack-agnostic gate pipeline

`validate.sh`, `gate-2b`, `gate-2d`, and `auto-format.sh` read `commands.lint`, `commands.format`, and `commands.format_check` from config — replacing hardcoded Python/ruff calls. When a key is absent, each script emits `[DSO WARN]` and falls back gracefully (ruff for `.py`; skip for other extensions). Per-stack defaults: see `CONFIGURATION-REFERENCE.md`.

## CI workflow signals introduced by epic f691-681e

The PR/review-workflow remediation epic added several new CI-level signals and scripts that interact with hooks and gates. This section documents them as a reference for operators and plugin authors.

### `review-sub-pr` — per-sub-branch LLM review job

`.github/workflows/review-sub-pr.yml` runs LLM review on story/bug-batch sub-branch PRs that target the session branch (`session/**`, `session-**`, `session_**`, `bug-batch/**`). It is registered as a required check in `.github/required-checks.txt` and enforced via the main-branch Ruleset after the S_migration cutover.

Key signals:
- **Liveness invariant** (`c131-0f34`): the job writes a `findings.json` artifact (`DSO_CI_REVIEW_OUTPUT_PATH`) and then validates it exists and contains a `findings` array. A silent reviewer exit-0 with no output fails the liveness step.
- **`DSO_SUPPRESS_PRIOR_DEFENSES`**: environment variable consumed by `dso_ci_review/runner.py`. When `"true"` (set by the integration-review step in `ci.yml`), the runner skips prior-defense loading even on cycle ≥ 2. Prevents sub-PR defenses from suppressing findings that the integration (session→main) reviewer should see fresh. This variable is set by `ci.yml` — it is NOT a `dso-config.conf` key.

### `merge-pipeline-checks` — umbrella required-check job (S4)

A dedicated CI job in `ci.yml` that provides a **stable required-check name** for branch protection, decoupled from conditional steps it wraps. Registered in `.github/required-checks.txt`.

**Current member step:**

| Step | Trigger | Purpose |
|------|---------|---------|
| `red-test-blocker` | PR base == `main` AND head is `session/**`, `session-**`, `session_**`, or `bug-batch/**` | Blocks merge when RED-phase TDD markers remain in the merged `.test-index` |

`red-test-blocker` invokes `${CLAUDE_PLUGIN_ROOT}/scripts/scan-red-markers.sh`. It scans the **merged tree** (computed via `git merge-tree --write-tree`) rather than HEAD alone, so it catches RED markers from any merged sub-branch. Exit 0 = clean; exit 1 = RED markers remain.

**DEFERRED exemptions**: a `# DEFERRED: <path>:<test_name> reason=<text> ticket=<id>` line in `.test-index` exempts matching RED markers from blocking. Unmatched RED markers still fail the step.

#### CI auto-disable of RED-zone marker tolerance

`SUITE_TEST_INDEX` enables RED-zone tolerance in the bash/pytest runners (failing tests at/after a `.test-index [marker]` are reclassified as passing — useful during TDD red phase). Tolerance is **unconditionally disabled** when `CI=true` or `GITHUB_ACTIONS=true` is set, regardless of whether `SUITE_TEST_INDEX` is exported. Defense-in-depth ensures a stale env var in a new workflow cannot let a RED-tolerated failure reach main.

Implementation: `tests/lib/suite-engine.sh` and `${CLAUDE_PLUGIN_ROOT}/scripts/runners/bash-runner.sh` short-circuit the marker-map build when the CI envs are set. Regression test: `tests/scripts/test-bash-runner-red-zone.sh` (Tests 4 and 5).

Together with the `red-test-blocker` step above, this gives two enforcement layers against RED tests reaching main:
1. **`scan-red-markers.sh`** blocks PRs where the merged `.test-index` still has `[marker]` brackets (TDD intent leaking into integration).
2. **Runner CI-override** ensures that even if a marker slipped through, the underlying test failure surfaces — never silently tolerated in CI.

### `llm-review-dispatch-or-skip.sh` — provenance-aware dispatch wrapper

`${CLAUDE_PLUGIN_ROOT}/scripts/llm-review-dispatch-or-skip.sh` wraps `ci-llm-review-runner.sh` for the integration (session→main) review. Calls `verify-session-provenance.sh` first and routes:

| Verifier exit | Wrapper behavior |
|---------------|-----------------|
| `0` — all provenanced | Skip dispatch; emit `skipped` conclusion |
| `1` — unprovenanced | Invoke full-diff LLM review |
| `2` — budget exhausted | Invoke full-diff LLM review (safe fallback) |
| `3` — `OVER_BOUND` | Emit OVER_BOUND summary; route to admin; exit 0 |

`OVER_BOUND` (exit 3) fires when a PR exceeds the `max_files × max_calls` hard upper bound. It is NOT an FP — no LLM reviewer ran. `check-fp-recovery-eligibility.sh` (consumed by `/dso:fp-recovery`) rejects such PRs. See `CI-INTEGRATION.md §OVER_BOUND status`.

### `check-fp-recovery-eligibility.sh` — FP-recovery pre-gate

`${CLAUDE_PLUGIN_ROOT}/scripts/check-fp-recovery-eligibility.sh` is a pre-check gate for `/dso:fp-recovery`. Reads `DSO_CI_LOG` (path to the CI output log) and exits 1 if an `OVER_BOUND:` marker is detected. When `DSO_CI_LOG` is absent or the file does not exist, exits 0 (eligible — no signal). Documented in `docs/workflows/FP-RECOVERY-WORKFLOW.md`.

### Worktree-removal-guards library

`${CLAUDE_PLUGIN_ROOT}/scripts/lib/worktree-removal-guards.sh` — shared library of four safety guards used by `claude-safe` (interactive) and `harvest-worktree.sh` (batched). Source with `_GUARDS_SOURCE_ONLY=1`. Guards: `guard_protected_branch`, `guard_uncommitted`, `guard_unpushed`, `guard_open_pr`. The `assert_worktree_removable` orchestrator runs all four without short-circuiting.

For full semantics (3-tier PR detection, `--force` bypass, fail-CLOSED contract, TOCTOU double-check in `claude-safe`), see `WORKTREE-GUIDE.md §Worktree removal safety guards`.

## GitHub CI Ruleset enforcement

`.github/required-checks.txt` lists required GitHub check-context names (must match workflow `name:` fields exactly). As of epic f691-681e, required checks include `review-sub-pr` (S1) and `merge-pipeline-checks` (S4) in addition to existing entries. Provisioned during `/dso:onboarding` via `github-bootstrap.sh` (fail-open — never blocks setup). Managed post-cutover via `${CLAUDE_PLUGIN_ROOT}/scripts/update-required-checks-manifest.sh` (additive, idempotent) and `${CLAUDE_PLUGIN_ROOT}/scripts/promote-ruleset-required.sh` (stages as non-required, then promotes). After editing workflow job names, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/validate-required-checks.sh` to catch alignment drift before pushing.  <!-- # shim-exempt: doc example — the canonical operator command path is shown verbatim so it can be copy-pasted -->
