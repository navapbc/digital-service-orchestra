# Commit Workflow

Create a git commit with mandatory test, format, lint, and review gates.

---

## Step 0: Gather Context

Run these commands and save their output:

```bash
git status
git diff HEAD --stat
git branch --show-current
git log --oneline -5
```

## Step 0.5: Check for Docs-Only Changes

Check if all changed files are documentation or beads tracking (no code changes):

```bash
CHANGED_FILES=$(git diff HEAD --name-only)
DOCS_ONLY=true
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if [[ "$file" != *.md ]] && [[ "$file" != .beads/* ]]; then
        DOCS_ONLY=false
        break
    fi
done <<< "$CHANGED_FILES"
```

**If `DOCS_ONLY` is true**: Skip Steps 1-3a entirely. Go directly to Step 4 (Stage).

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
WORKTREE=$(basename "$REPO_ROOT")
ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-${WORKTREE}"
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
WORKTREE_NAME=$(basename "$REPO_ROOT")
REVIEW_STATE="/tmp/lockpick-test-artifacts-${WORKTREE_NAME}/review-status"
CURRENT_HASH=$("$REPO_ROOT/.claude/hooks/compute-diff-hash.sh")
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

After committing, report the SHA and return control to the caller.

## After Commit: Merging to Main

If you need to merge the worktree branch to main and push, use `sprintend-merge.sh` instead of manual `git merge` + `git push`. It handles beads sync, merge, and push in a single step, avoiding the review-gate and pre-push hook issues that arise from beads file changes on main.

```bash
"$REPO_ROOT/scripts/sprintend-merge.sh"
```

Do NOT manually `cd` to the main repo and run `git merge` / `git commit` / `git push` — the review gate hook runs in the worktree context and will block commits on main that aren't beads-only.
