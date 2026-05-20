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
| `record-review.sh` | Single-writer for review status — invoked by named code-reviewer agents only (`` `rule:fabrication` ``); reads from `reviewer-findings.json` and writes the review-status sidecar |
| `record-test-exemption.sh` | Records intentional test exemptions (RED markers, xfail rationale) for the test gate's tolerance logic |

## Hook error handler

`${CLAUDE_PLUGIN_ROOT}/hooks/lib/hook-error-handler.sh` — shared ERR/EXIT trap library for **non-enforcement** hooks. Source with a fail-open guard, then call `_dso_register_hook_err_handler "hook-name.sh"`. Errors logged to `~/.claude/logs/dso-hook-errors.jsonl` (handler always exits 0, never blocks hook execution).

Enforcement hooks (annotated `# hook-boundary: enforcement`) MUST NOT source this library — `pre-commit-enforcement-boundary-check.sh` enforces this boundary at commit time.

## Stack-agnostic gate pipeline

`validate.sh`, `gate-2b`, `gate-2d`, and `auto-format.sh` read `commands.lint`, `commands.format`, and `commands.format_check` from config — replacing hardcoded Python/ruff calls. When a key is absent, each script emits `[DSO WARN]` and falls back gracefully (ruff for `.py`; skip for other extensions). Per-stack defaults: see `CONFIGURATION-REFERENCE.md`.

## GitHub CI Ruleset enforcement

`.github/required-checks.txt` lists required GitHub check-context names (must match workflow `name:` fields exactly). Provisioned during `/dso:onboarding` via `github-bootstrap.sh` (fail-open — never blocks setup). After editing workflow job names, run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/validate-required-checks.sh` to catch alignment drift before pushing.  <!-- # shim-exempt: doc example — the canonical operator command path is shown verbatim so it can be copy-pasted -->
