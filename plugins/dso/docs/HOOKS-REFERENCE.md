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

## Review gate (two-layer)

- **Layer 1** — `pre-commit-review-gate.sh` (git hook) enforces `review-gate-allowlist.conf` allowlist + `review-status` + diff hash.
- **Layer 2** — `review-gate.sh` (PreToolUse hook) blocks `--no-verify`, `core.hooksPath=` overrides, and git plumbing bypasses.

Both layers handle MERGE_HEAD and REBASE_HEAD via `merge-state.sh`. `--no-verify` cannot bypass Layer 2 — it is a Claude Code tool-use hook, not a git hook.

**Exception**: when `enforcement.strategy=ci`, both layers emit `HOOK_GATE: skipped reason=enforcement.strategy=ci` and skip enforcement; CI enforces via the parity-uplifted llm-review job.

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
    bash "${CLAUDE_PLUGIN_ROOT}/scripts/commit-step.sh" skip "$step" "enforcement.strategy=ci"
done
```

## Hook error handler

`${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-error-handler.sh` — shared ERR/EXIT trap library for **non-enforcement** hooks. Source with a fail-open guard, then call `_dso_register_hook_err_handler "hook-name.sh"`. Errors logged to `~/.claude/logs/dso-hook-errors.jsonl` (handler always exits 0, never blocks hook execution).

Enforcement hooks (annotated `# hook-boundary: enforcement`) MUST NOT source this library — `pre-commit-enforcement-boundary-check.sh` enforces this boundary at commit time.

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

`.github/required-checks.txt` lists required GitHub check-context names (must match workflow `name:` fields exactly). As of epic f691-681e, required checks include `review-sub-pr` (S1) and `merge-pipeline-checks` (S4) in addition to existing entries. Provisioned during `/dso:onboarding` via `github-bootstrap.sh` (fail-open — never blocks setup). Managed post-cutover via `${CLAUDE_PLUGIN_ROOT}/scripts/update-required-checks-manifest.sh` (additive, idempotent) and `${CLAUDE_PLUGIN_ROOT}/scripts/promote-ruleset-required.sh` (stages as non-required, then promotes). After editing workflow job names, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/validate-required-checks.sh` to catch alignment drift before pushing.
