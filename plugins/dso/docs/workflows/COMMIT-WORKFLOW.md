# Commit Workflow

Create a git commit with mandatory test, format, lint, and review gates.

<HARD-GATE>
Execute ALL steps in this workflow in order. Do NOT skip, abbreviate, or "run through key steps efficiently." Every step is mandatory — including format checks, lint, test recording, and review. Rationalizing that "these are simple changes" or "time pressure" justifies skipping steps is exactly the failure mode this gate prevents.
</HARD-GATE>

## Config Reference (from dso-config.conf)

Replace commands below with values from your `.claude/dso-config.conf`:

- `commands.lint` (default: `make lint-ruff`)
- `commands.type_check` (default: `make lint-mypy`)
- `commands.format` (default: `make format-modified`)
- `commands.test_changed` (optional — when absent, Step 1.5 is skipped)
- `commands.validate` (default: `validate.sh --ci`)

The artifacts directory is computed by `get_artifacts_dir()` in `hooks/lib/deps.sh` and resolves to `/tmp/workflow-plugin-<hash-of-REPO_ROOT>/`.

---

<!-- Schema reference: docs/designs/stage-boundary-preconditions/ -->

## Step 0: Gather Context

### Pre-flight: Ensure `pre-commit` Is Available

Before running any git commands, run the pre-flight check script. It activates the venv if needed and detects/repairs stale git hook shims (left behind when worktrees are cleaned up):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source ".claude/scripts/dso ensure-pre-commit.sh" || true
```

If the script warns that `pre-commit` is not found, the commit hooks may fail later. See `.claude/scripts/dso ensure-pre-commit.sh` for the full fallback chain.

### Breadcrumb Init

Truncate the breadcrumb log to prevent unbounded growth, then initialize it for this run:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Resolve CLAUDE_PLUGIN_ROOT if not set by the caller (e.g., manual run outside Claude Code)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _cfg="$REPO_ROOT/.claude/dso-config.conf"
    if [[ -f "$_cfg" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$_cfg" 2>/dev/null | cut -d= -f2-)"
    fi
    # Final fallback: read dso.plugin_root from config
    if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)"
    fi
fi
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
# Note: ARTIFACTS_DIR is computed from the repo root SHA hash by get_artifacts_dir().
# To override the artifacts path, use WORKFLOW_PLUGIN_ARTIFACTS_DIR=<path> — NOT ARTIFACTS_DIR.
# Setting ARTIFACTS_DIR externally has no effect; get_artifacts_dir() ignores it.
mkdir -p "$ARTIFACTS_DIR"
: > "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

### Preconditions Entry Check

Source the preconditions validator library and run the entry check for the commit stage (fail-open: `|| true` prevents blocking when no upstream event exists yet):

```bash
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/preconditions-validator-lib.sh" 2>/dev/null || true
_dso_pv_entry_check "commit" "sprint" "${STORY_OR_EPIC_ID:-}" || true
```

### Gather State

Run these commands and save their output:

```bash
git status
git diff HEAD --stat
git branch --show-current
git log --oneline -5
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-0-gather-context" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 0.5: Check for Non-Reviewable-Only Changes

Check if all changed files are non-reviewable. If every file matches a non-reviewable pattern, Steps 1-3a can be skipped. Otherwise a full review is required.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
git diff HEAD --name-only | bash ".claude/scripts/dso skip-review-check.sh" && SKIP_REVIEW=true || SKIP_REVIEW=false
```

**If `SKIP_REVIEW` is true**: Skip Steps 1.5-3a entirely. Go directly to Step 4 (Stage).

**Otherwise**: Continue to Step 1.5.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-0.5-skip-review-check" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 0.9: Emit Commit Workflow Start Event

Emit a durable start event **before** any timeout-prone steps (test, lint, review). This must be committed to the orphan branch so that SIGURG (exit 144) cannot lose it. Incomplete commits are detectable as unpaired start events (start without a matching end in the same session).

> **Failure exits**: If the commit workflow fails at any step (test failure after exhausting retries, lint failure, review escalation to user, commit rejection), emit an end-failure event before aborting:
>
> ```bash
> REPO_ROOT=$(git rev-parse --show-toplevel)
> ".claude/scripts/dso" emit-commit-workflow-event.sh --phase=end --success=false --failure-reason="<step and reason>"
> ```
>
> Replace `<step and reason>` with a concise description (e.g., `"Step 1.5: integration tests failed after 5 attempts"`, `"Step 5: review escalated to user"`). This pairs with the start event to close the observability window.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
".claude/scripts/dso" emit-commit-workflow-event.sh --phase=start
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-0.9-emit-start-event" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 1.5: Changed Integration/E2E Tests

If any integration or e2e test files changed, run only those files now. This prevents broken tests from being committed when the full suite is excluded from the standard commit gate.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
TEST_CHANGED_CMD="$(".claude/scripts/dso read-config.sh" commands.test_changed)"
if [ -z "$TEST_CHANGED_CMD" ]; then
    echo "commands.test_changed not configured — skipping changed-test step"
    # continue to Step 2
else
    "$REPO_ROOT/$TEST_CHANGED_CMD"
fi
```

- **Integration tests fail**: DB is not running. Start it with `make db-start` and re-run. Fix the test if it is broken.
- **E2E tests fail**: App is not running. Start it with `make start` and re-run. Fix the test if it is broken.
- **No changed integration/e2e files**: Script exits silently. Continue to Step 2.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-1.5-changed-tests" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

### Test Failure Delegation (Step 1.5)

If integration or E2E tests fail after environment checks (DB/app running), apply this decision gate:

**Fix inline**: Single obvious failure (typo, missing import, one-line fix) — fix it and re-run.

**Delegate to sub-agent** (via [TEST-FAILURE-DISPATCH.md](TEST-FAILURE-DISPATCH.md)):
- More than 1 test fails, OR
- 1 test fails and an inline fix attempt did not resolve it.

Dispatch procedure:

1. **Build the input payload** using the integration/E2E test command that failed:

```bash
TEST_CHANGED_CMD="$(".claude/scripts/dso read-config.sh" commands.test_changed)"
TEST_COMMAND="$REPO_ROOT/$TEST_CHANGED_CMD"
# EXIT_CODE and STDERR_TAIL come from the ALREADY-FAILED test run above.
# Do NOT re-run the tests — capture from the original failure.
# EXIT_CODE=<exit code from the failed test run>
# STDERR_TAIL=<last 50 lines of output from the failed test run>
CHANGED_FILES=$(git diff --name-only)
```

2. **Set context** based on failure type:
   - Integration test failure: `context="sprint-ci-failure"`
   - E2E test failure: `context="commit-time"`

3. **Model selection, sub-agent type, prompt template, Task dispatch, and result parsing**: See [TEST-FAILURE-DISPATCH.md](TEST-FAILURE-DISPATCH.md) for the full dispatch procedure.

4. **Parse the result**:
   - `RESULT: PASS` — re-run the config-driven test command (`$REPO_ROOT/$TEST_CHANGED_CMD`) to confirm the fix, then continue to Step 2.
   - `RESULT: FAIL` — increment attempt counter and retry with escalated model. If attempt exceeds `review.max_resolution_attempts` (default: 5), escalate to user.
   - `RESULT: PARTIAL` — log concerns via `.claude/scripts/dso ticket comment`, continue to Step 2 with caveats.

5. **Fallback**: Sub-agent timeout (>5 min) or malformed output — fall back to inline fix attempt and restart from Step 1.5.

## Step 2: Format

Run formatting on modified files so file edits are complete before staging.

```bash
cd app && make format-modified
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-2-format" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 3: Lint and Type Check

Run lint and type checks before staging. Any tool that may edit files must run before `git add`.

```bash
cd app && make lint-ruff 2>&1 | tail -3
```

```bash
cd app && make lint-mypy 2>&1 | tail -5
```

On success, only the summary lines are needed. If either exit code is non-zero, re-run with full output to see errors.

If either check fails, fix the issue and **restart from Step 1.5**.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-3-lint-typecheck" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 3a: Write Validation State File

After Steps 1.5-3 all pass, write a validation state file so the review workflow can skip redundant re-validation:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
# Resolve CLAUDE_PLUGIN_ROOT if not set by the caller (e.g., manual run outside Claude Code)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _cfg="$REPO_ROOT/.claude/dso-config.conf"
    if [[ -f "$_cfg" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$_cfg" 2>/dev/null | cut -d= -f2-)"
    fi
    # Final fallback: read dso.plugin_root from config
    if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)"
    fi
fi
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
echo "passed" > "$ARTIFACTS_DIR/validation-status"
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-3a-validation-state" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 4: Stage

If you intend to include new (untracked) files in this commit, add them explicitly by name first.

Then stage all tracked modifications (including any files touched by the format or lint steps) without accidentally staging untracked files:

```bash
git add -u
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-4-stage" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 4.5: Record Test Status

Run `record-test-status.sh` **after** `git add -u` (Step 4) so that the recorded diff hash matches the staged index — the pre-commit test gate validates against the staged hash, not the working-tree hash.

The invocation must be prefixed with `DSO_COMMIT_WORKFLOW=1` — the PreToolUse `hook_record_test_status_guard` rejects unprefixed direct calls to prevent casual misuse. See `${CLAUDE_PLUGIN_ROOT}/hooks/lib/pre-bash-functions.sh` for the allowlist and `${CLAUDE_PLUGIN_ROOT}/hooks/pre-commit-test-gate.sh` for the defense-in-depth diff_hash check that catches mismatched status regardless.

```bash
DSO_COMMIT_WORKFLOW=1 bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-test-status.sh"
```

- **exit 0**: all associated tests passed (or no associated tests found) — continue to Step 5 (Review Gate).
- **exit 144**: test runner was terminated; follow the actionable guidance printed by `record-test-status.sh`. Use `test-batched.sh` to run the tests in time-bounded chunks:
  ```bash
  .claude/scripts/dso test-batched.sh --timeout=50 "bash tests/hooks/test-<name>.sh"
  ```
  When `test-batched.sh` runs out of time, it emits a **Structured Action-Required Block**:
  ```
  ════════════════════════════════════════════════════════════
    ⚠  ACTION REQUIRED — TESTS NOT COMPLETE  ⚠
  ════════════════════════════════════════════════════════════
  RUN: TEST_BATCHED_STATE_FILE=... bash .../test-batched.sh ...
  DO NOT PROCEED until the command above prints a final summary.
  ════════════════════════════════════════════════════════════
  ```
  Run the command shown on the `RUN:` line in subsequent calls until the summary appears, then re-run Step 4.5.
- **exit non-zero (other)**: tests failed; fix the failures and **restart from Step 1.5**.

> **NEVER add RED markers to `.test-index` to bypass a test gate failure.** RED markers (`[test_name]` entries in `.test-index`) are exclusively for TDD — they mark tests that are expected to fail because the feature under test is not yet implemented. If the test gate blocks due to pre-existing failures unrelated to your change, create a bug ticket (`.claude/scripts/dso ticket create bug "<test failure description>"`) and fix the test. Do NOT add a marker to mask the failure.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-4.5-record-test-status" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 5: Review Gate

Decide whether a review is needed:

- **Review ran earlier this session and no files changed since**: Skip to Step 6.
- **No recent review, or files changed since the last review**: Execute the review workflow (REVIEW-WORKFLOW.md). If you have already read this file earlier in this conversation and have not compacted since, use the version in context. Note: Steps 1.5-3a above already ran format/lint/type-check and wrote the validation-status file, so REVIEW-WORKFLOW.md Step 1 (auto-fix pass) will skip via the fresh validation-status check. This ensures the diff hash captured in REVIEW-WORKFLOW.md Step 2 reflects the post-auto-fix state and will not be invalidated by pre-commit hooks.
- **The commit in Step 6 is blocked** with "Review is stale" or "No code review recorded": Run REVIEW-WORKFLOW.md, then retry Step 6. Do NOT inspect, copy, or modify review state files — the commit gate enforces correctness and any workaround will be caught at the merge step.

If review fails, the review workflow's Autonomous Resolution Loop handles fix/defend attempts automatically (up to `review.max_resolution_attempts`, default: 5). If it escalates to you (the orchestrator), fix the issues and **restart from Step 1.5** (not Step 5).

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-5-review-gate" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 6: Commit

Files are already staged from Step 4. The diff stat summary is already in context from Step 0 or the review workflow. Use that for the commit message — do not re-run `git diff --staged`. If you need a file list, use `git diff --staged --name-only` (minimal output).

Create a single git commit following the repository's commit message conventions visible in the recent commits from Step 0.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-6-commit" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

After a successful commit, emit the preconditions exit event (fail-open):

```bash
_dso_pv_exit_write "commit" "${_UPSTREAM_EVENT_ID:-}" "${DIFF_HASH:-}" "${STORY_OR_EPIC_ID:-}" || true
```

Then emit the end event:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
".claude/scripts/dso" emit-commit-workflow-event.sh --phase=end --success=true
```

After committing, report the SHA and **immediately return control to the caller** — do NOT wait for user input. Resume the calling workflow at the step after this commit invocation. If you were executing `/dso:debug-everything`, continue at the step after this commit invocation (Phase F Step 5 for auto-fix commits, or Phase H Step 11 for post-batch commits). If you were executing `/dso:sprint`, continue at Phase 5 Step 10 (Commit & Push) or the step that invoked this workflow. Do NOT output any text that implies the session is complete.

## After Commit: Merging to Main

If you need to merge the worktree branch to main and push, use `merge-to-main.sh` instead of manual `git merge` + `git push`. It handles .claude/scripts/dso ticket sync, merge, and push in a single step, avoiding the review-gate and pre-push hook issues that arise from ticket file changes on main.

```bash
".claude/scripts/dso merge-to-main.sh"
```

Do NOT manually `cd` to the main repo and run `git merge` / `git commit` / `git push` — the review gate hook runs in the worktree context and will block commits on main that aren't ticket-tracking-only.
