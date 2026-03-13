# Commit Workflow

Create a git commit with mandatory test, format, lint, and review gates.

## Config Reference (from workflow-config.yaml)

Replace commands below with values from your `workflow-config.yaml`:

- `commands.test_unit` (default: `make test-unit-only`)
- `commands.lint` (default: `make lint-ruff`)
- `commands.type_check` (default: `make lint-mypy`)
- `commands.format` (default: `make format-modified`)
- `commands.test_changed` (default: `scripts/run-changed-tests.sh`)
- `commands.validate` (default: `validate.sh --ci`)

The artifacts directory is computed by `get_artifacts_dir()` in `hooks/lib/deps.sh` and resolves to `/tmp/workflow-plugin-<hash-of-REPO_ROOT>/`.

---

## Step 0: Gather Context

### Pre-flight: Ensure `pre-commit` Is Available

Before running any git commands, run the pre-flight check script. It activates the venv if needed and detects/repairs stale git hook shims (left behind when worktrees are cleaned up):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/lockpick-workflow/scripts/ensure-pre-commit.sh" || true
```

If the script warns that `pre-commit` is not found, the commit hooks may fail later. See `lockpick-workflow/scripts/ensure-pre-commit.sh` for the full fallback chain.

### Gather State

Run these commands and save their output:

```bash
git status
git diff HEAD --stat
git branch --show-current
git log --oneline -5
```

## Step 0.5: Check for Non-Reviewable-Only Changes

Check if all changed files are non-reviewable. If every file matches a non-reviewable pattern, Steps 1-3a can be skipped. Otherwise a full review is required.

```bash
CHANGED_FILES=$(git diff HEAD --name-only)
SKIP_REVIEW=true
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    # Agent guidance always requires review (checked first, overrides docs/* below)
    case "$file" in
        .claude/skills/*|.claude/hooks/*|.claude/hookify.*) SKIP_REVIEW=false; break ;;
        lockpick-workflow/skills/*|lockpick-workflow/hooks/*|lockpick-workflow/docs/workflows/*) SKIP_REVIEW=false; break ;;
        CLAUDE.md) SKIP_REVIEW=false; break ;;
    esac
    # .checkpoint-needs-review always requires a full review (see Note below)
    case "$file" in
        .checkpoint-needs-review) SKIP_REVIEW=false; break ;;
    esac
    # Non-reviewable files
    case "$file" in
        .tickets/*) ;;                                                              # ticket metadata
        .sync-state.json) ;;                                                       # sync state metadata
        app/tests/e2e/snapshots/*|app/tests/unit/templates/snapshots/*.html) ;;   # visual snapshots
        *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.webp) ;;                            # images
        *.pdf|*.docx) ;;                                                           # binary docs
        .claude/session-logs/*|.claude/docs/*|docs/*) ;;                          # logs and non-agent docs
        *) SKIP_REVIEW=false; break ;;
    esac
done <<< "$CHANGED_FILES"
```

**If `SKIP_REVIEW` is true**: Skip Steps 1-3a entirely. Go directly to Step 4 (Stage).

**Otherwise**: Continue to Step 1.

**Note on `.checkpoint-needs-review`**: This file is written when code is auto-committed during a context-compaction event. It signals that the code has never been reviewed. The only correct path through is to run `/commit` from the beginning — Steps 1-3a must execute so the review can read the sentinel nonce and delete the file. Skipping to Step 4 or later will cause the commit to be blocked; restart from Step 1.

## Step 1: Test

Run unit tests to catch breakage before investing in review.

```bash
cd app && make test-unit-only 2>&1 | tail -5
```

On success, only the summary is needed. If the exit code is non-zero, re-run with full output to see failures:
```bash
cd app && make test-unit-only
```

If tests fail, fix the code and restart from Step 1. Do NOT proceed with a failing test suite.

### Test Failure Delegation (Step 1)

When unit tests fail, apply this decision gate before attempting a fix:

**Fix inline** (preserve existing behavior):
- Single obvious failure (typo, missing import, one-line fix) — fix it and restart from Step 1.

**Delegate to sub-agent** (via [TEST-FAILURE-DISPATCH.md](TEST-FAILURE-DISPATCH.md)):
- More than 1 test fails, OR
- 1 test fails and an inline fix attempt did not resolve it.

Do NOT spend orchestrator context on multi-test debugging — delegate immediately.

#### Dispatch Procedure

1. **Build the input payload**:

```bash
TEST_COMMAND="cd app && make test-unit-only"
# EXIT_CODE and STDERR_TAIL come from the ALREADY-FAILED test run above.
# The orchestrator should have captured stdout/stderr and exit code when
# running the test command. Do NOT re-run the tests here.
# EXIT_CODE=<exit code from the failed test run>
# STDERR_TAIL=<last 50 lines of output from the failed test run>
CHANGED_FILES=$(git diff --name-only)
```

> **Note**: `EXIT_CODE` and `STDERR_TAIL` must come from the test run that already
> failed (the one that triggered this delegation gate). Do NOT re-run tests to
> capture them — that would execute tests twice and may yield different results.

2. **Select model** (by attempt number):
   - Attempt 1: `sonnet`
   - Attempt 2: `opus`
   - Attempt >= 3: **Escalate to user** — do not retry further.

3. **Select sub-agent type** (from TEST-FAILURE-DISPATCH.md):
   - Unit test failure (assertion, runtime error): `unit-testing:debugger`
   - Type error (mypy): `debugging-toolkit:debugger`
   - Lint violation (ruff): `code-simplifier:code-simplifier`
   - Multi-file / complex (cross-module): `error-debugging:error-detective`

4. **Select prompt template**: `lockpick-workflow/skills/debug-everything/prompts/test-failure-fix.md`
   - Behavioral failure (assertion, runtime error): TDD path
   - Mechanical failure (import, type, lint): Mechanical path

5. **Dispatch via Task tool**:

```
Task(
  subagent_type=<selected_type>,
  model=<selected_model>,
  prompt=<filled template from test-failure-fix.md>,
  input={
    test_command: <TEST_COMMAND>,
    exit_code: <EXIT_CODE>,
    stderr_tail: <STDERR_TAIL>,
    changed_files: <CHANGED_FILES>,
    task_id: <current_task_id>,
    context: "commit-time",
    attempt: <attempt_number>
  }
)
```

6. **Parse the result**:
   - `RESULT: PASS` — continue to Step 1.5 (re-run validation first to confirm the fix is clean).
   - `RESULT: FAIL` — increment attempt counter and retry with escalated model. If attempt >= 3, escalate to user.
   - `RESULT: PARTIAL` — log concerns via `tk add-note`, continue to Step 1.5 with caveats.

7. **Fallback**: If the sub-agent times out (>5 min) or returns malformed output (missing RESULT line), fall back to an inline fix attempt by the orchestrator and restart from Step 1.

## Step 1.5: Changed Integration/E2E Tests

If any integration or e2e test files changed, run only those files now. This prevents broken tests from being committed when the full suite is excluded from the standard commit gate.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
TEST_CHANGED_CMD="$("$REPO_ROOT/lockpick-workflow/scripts/read-config.sh" commands.test_changed)"
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

### Test Failure Delegation (Step 1.5)

If integration or E2E tests fail after environment checks (DB/app running), apply the same delegation decision gate as Step 1:

**Fix inline**: Single obvious failure (typo, missing import, one-line fix) — fix it and re-run.

**Delegate to sub-agent** (via [TEST-FAILURE-DISPATCH.md](TEST-FAILURE-DISPATCH.md)):
- More than 1 test fails, OR
- 1 test fails and an inline fix attempt did not resolve it.

Follow the same dispatch procedure as Step 1, with these differences:

1. **Build the input payload** using the integration/E2E test command that failed:

```bash
TEST_CHANGED_CMD="$("$REPO_ROOT/lockpick-workflow/scripts/read-config.sh" commands.test_changed)"
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

3. **Model selection, sub-agent type, prompt template, Task dispatch, and result parsing**: Same as Step 1 delegation procedure (steps 2-7).

4. **Parse the result**:
   - `RESULT: PASS` — re-run the config-driven test command (`$REPO_ROOT/$TEST_CHANGED_CMD`) to confirm the fix, then continue to Step 2.
   - `RESULT: FAIL` — increment attempt counter and retry with escalated model. If attempt >= 3, escalate to user.
   - `RESULT: PARTIAL` — log concerns via `tk add-note`, continue to Step 2 with caveats.

5. **Fallback**: Sub-agent timeout (>5 min) or malformed output — fall back to inline fix attempt and restart from Step 1.

## Step 1.75: Plugin Tests (Conditional)

Run plugin tests when workflow files or project scripts have changed. This catches broken hooks and scripts before review, avoiding wasted review cycles on a broken commit.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
CHANGED=$(git diff HEAD --name-only)
PLUGIN_CHANGED=false
while IFS= read -r f; do
    case "$f" in
        lockpick-workflow/hooks/*|lockpick-workflow/scripts/*|lockpick-workflow/skills/*|scripts/*|.pre-commit-config.yaml|Makefile|app/Makefile)
            PLUGIN_CHANGED=true; break ;;
    esac
done <<< "$CHANGED"

if [ "$PLUGIN_CHANGED" = "true" ]; then
    cd "$REPO_ROOT" && make test-plugin
fi
```

- **No pattern matches**: Exit silently. Continue to Step 2.
- **Pattern matches, tests pass**: Continue to Step 2.
- **Pattern matches, tests fail**: See Test Failure Delegation (Step 1.75) below.

### Test Failure Delegation (Step 1.75)

When plugin tests fail, apply the same delegation decision gate as Step 1:

**Fix inline**: Single obvious failure (typo, missing import, one-line fix) — fix it and re-run `make test-plugin`.

**Delegate to sub-agent** (via [TEST-FAILURE-DISPATCH.md](TEST-FAILURE-DISPATCH.md)):
- More than 1 test fails, OR
- 1 test fails and an inline fix attempt did not resolve it.

Follow the same dispatch procedure as Step 1, with these differences:

1. **Build the input payload** using the plugin test command that failed:

```bash
TEST_COMMAND="cd $REPO_ROOT && make test-plugin"
# EXIT_CODE and STDERR_TAIL come from the ALREADY-FAILED test run above.
# Do NOT re-run the tests — capture from the original failure.
# EXIT_CODE=<exit code from the failed test run>
# STDERR_TAIL=<last 50 lines of output from the failed test run>
CHANGED_FILES=$(git diff HEAD --name-only)
```

2. **Set context**: `context="commit-time"`

3. **Model selection, sub-agent type, prompt template, Task dispatch, and result parsing**: Same as Step 1 delegation procedure (steps 2-7).

4. **Parse the result**:
   - `RESULT: PASS` — re-run `make test-plugin` to confirm the fix, then continue to Step 2.
   - `RESULT: FAIL` — increment attempt counter and retry with escalated model. If attempt >= 3, escalate to user.
   - `RESULT: PARTIAL` — log concerns via `tk add-note`, continue to Step 2 with caveats.

5. **Fallback**: Sub-agent timeout (>5 min) or malformed output — fall back to inline fix attempt and restart from Step 1.75.

## Step 2: Format

Run formatting on modified files so file edits are complete before staging.

```bash
cd app && make format-modified
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

If either check fails, fix the issue and **restart from Step 1**.

## Step 3a: Write Validation State File

After Steps 1-3 all pass, write a validation state file so the review workflow can skip redundant re-validation:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh
ARTIFACTS_DIR=$(get_artifacts_dir)
mkdir -p "$ARTIFACTS_DIR"
echo "passed" > "$ARTIFACTS_DIR/validation-status"
```

## Step 4: Stage

If you intend to include new (untracked) files in this commit, add them explicitly by name first.

Then stage all tracked modifications (including any files touched by the format or lint steps) without accidentally staging untracked files:

```bash
git add -u
```

## Step 5: Review Gate

> **Pre-compaction checkpoint recovery**: If the working tree is unexpectedly clean when you expected uncommitted changes, check `git log --oneline -3` for a checkpoint commit (message contains "pre-compaction auto-save" or "checkpoint:"). If found, the checkpoint contains unreviewed code that was auto-saved during compaction. Recover with these exact steps:
>
> ```bash
> git reset --soft HEAD~1                    # undo the checkpoint commit, re-stage the changes
> git rm --cached .checkpoint-needs-review   # un-stage the sentinel (leave the file in the working tree)
> ```
>
> Then restart from **Step 1** of this workflow. Leave `.checkpoint-needs-review` in the working tree — `record-review.sh` reads the nonce from it during review and removes it automatically. Do NOT skip to Step 4 or Step 5; the code was committed without review and must go through the complete workflow.

Decide whether a review is needed:

- **Review ran earlier this session and no files changed since**: Skip to Step 6.
- **No recent review, or files changed since the last review**: Execute the review workflow (REVIEW-WORKFLOW.md). If you have already read this file earlier in this conversation and have not compacted since, use the version in context.
- **The commit in Step 6 is blocked** with "Review is stale" or "No code review recorded": Run REVIEW-WORKFLOW.md, then retry Step 6. Do NOT inspect, copy, or modify review state files — the commit gate enforces correctness and any workaround will be caught at the merge step.

If review fails, the review workflow's Autonomous Resolution Loop handles fix/defend attempts automatically (up to 2 attempts). If it escalates to you (the orchestrator), fix the issues and **restart from Step 1** (not Step 5).

## Step 6: Commit

Files are already staged from Step 4. The diff stat summary is already in context from Step 0 or the review workflow. Use that for the commit message — do not re-run `git diff --staged`. If you need a file list, use `git diff --staged --name-only` (minimal output).

Create a single git commit following the repository's commit message conventions visible in the recent commits from Step 0.

After committing, report the SHA and **immediately return control to the caller** — do NOT wait for user input. Resume the calling workflow at the step after this commit invocation. If you were executing `/debug-everything`, continue at the step after this commit invocation (Phase 4 Step 5 for auto-fix commits, or Phase 6 Step 6 for post-batch commits). If you were executing `/sprint`, continue at Phase 6 Step 10.5 (Commit & Push) or the step that invoked this workflow. Do NOT output any text that implies the session is complete.

## After Commit: Merging to Main

If you need to merge the worktree branch to main and push, use `merge-to-main.sh` instead of manual `git merge` + `git push`. It handles ticket sync, merge, and push in a single step, avoiding the review-gate and pre-push hook issues that arise from ticket file changes on main.

```bash
"$REPO_ROOT/scripts/merge-to-main.sh"
```

Do NOT manually `cd` to the main repo and run `git merge` / `git commit` / `git push` — the review gate hook runs in the worktree context and will block commits on main that aren't ticket-tracking-only.
