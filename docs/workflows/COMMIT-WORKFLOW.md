# Commit Workflow

Create a git commit with mandatory test, format, lint, and review gates.

## Config Reference (from workflow-config.yaml)

Replace commands below with values from your `workflow-config.yaml`:

- `commands.test_unit` (default: `make test-unit-only`)
- `commands.lint` (default: `make lint-ruff`)
- `commands.type_check` (default: `make lint-mypy`)
- `commands.format` (default: `make format-modified`)
- `commands.validate` (default: `validate.sh --ci`)

The artifacts directory is computed by `get_artifacts_dir()` in `hooks/lib/deps.sh` and resolves to `/tmp/workflow-plugin-<hash-of-REPO_ROOT>/`.

---

## Step 0: Gather Context

Run these commands and save their output:

```bash
git status
git diff HEAD --stat
git branch --show-current
git log --oneline -5
```

## Step 0.5: Check for Non-Reviewable-Only Changes

Check if all changed files are non-reviewable (documentation, beads tracking, snapshots, images, binary docs):

```bash
CHANGED_FILES=$(git diff HEAD --name-only)
SKIP_REVIEW=true
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    case "$file" in
        .claude/hookify.*.local.md) SKIP_REVIEW=false; break ;;  # hookify rules require review (must precede *.md)
        *.md|.beads/*) ;;  # docs/beads
        app/tests/e2e/snapshots/*|app/tests/unit/templates/snapshots/*.html) ;;  # snapshots
        *.png|*.jpg|*.jpeg|*.gif|*.svg|*.ico|*.webp) ;;  # images
        *.pdf|*.docx) ;;  # binary documents
        *) SKIP_REVIEW=false; break ;;
    esac
done <<< "$CHANGED_FILES"
```

**If `SKIP_REVIEW` is true**: Skip Steps 1-3a entirely. Go directly to Step 4 (Stage). The review gate (`review-gate.sh`) will also exempt these file types, so Step 5 (Review Gate) will pass automatically.

**Otherwise**: Continue to Step 1.

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

## Step 1.5: Changed Integration/E2E Tests

If any integration or e2e test files changed, run only those files now. This prevents broken tests from being committed when the full suite is excluded from the standard commit gate.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
"$REPO_ROOT/scripts/run-changed-tests.sh"
```

- **Integration tests fail**: DB is not running. Start it with `make db-start` and re-run. Fix the test if it is broken.
- **E2E tests fail**: App is not running. Start it with `make start` and re-run. Fix the test if it is broken.
- **No changed integration/e2e files**: Script exits silently. Continue to Step 2.

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

Check whether a current, passing review already exists for this exact diff state.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"  # or: ${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}/hooks/lib/deps.sh
ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE="$ARTIFACTS_DIR/review-status"
CURRENT_HASH=$("$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh")
```

Read the review state file:

```bash
REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE" 2>/dev/null || echo "missing")
RECORDED_HASH=$(grep '^diff_hash=' "$REVIEW_STATE" 2>/dev/null | head -1 | cut -d= -f2-)
```

**If** `REVIEW_STATUS` is `passed` AND `RECORDED_HASH` equals `CURRENT_HASH`:
- Review is current. Skip to Step 6.

**Otherwise** (missing, failed, or stale hash):
- Execute the review workflow (REVIEW-WORKFLOW.md). If you have already read this file earlier in this conversation and have not compacted since, use the version in context.
- If review fails, the review workflow's Autonomous Resolution Loop handles fix/defend attempts automatically (up to 2 attempts). If it escalates to you (the orchestrator), fix the issues and **restart from Step 1** (not Step 5). Re-running only the review after fixing code risks a stale diff hash.

## Step 6: Commit

Files are already staged from Step 4. The diff stat summary is already in context from Step 0 or the review workflow. Use that for the commit message — do not re-run `git diff --staged`. If you need a file list, use `git diff --staged --name-only` (minimal output).

Create a single git commit following the repository's commit message conventions visible in the recent commits from Step 0.

After committing, report the SHA and **immediately return control to the caller** — do NOT wait for user input. Resume the calling workflow at the step after this commit invocation.

## After Commit: Merging to Main

If you need to merge the worktree branch to main and push, use `sprintend-merge.sh` instead of manual `git merge` + `git push`. It handles beads sync, merge, and push in a single step, avoiding the review-gate and pre-push hook issues that arise from beads file changes on main.

```bash
"$REPO_ROOT/scripts/sprintend-merge.sh"
```

Do NOT manually `cd` to the main repo and run `git merge` / `git commit` / `git push` — the review gate hook runs in the worktree context and will block commits on main that aren't beads-only.
