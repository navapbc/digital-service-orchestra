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

<!-- Steps 1.5, 2, 3, and 3a (Changed Integration/E2E Tests, Format, Lint and Type Check, Write Validation State File) are gated by Step 0.6 (enforcement-strategy gate). When `enforcement.strategy=local`, execute the steps in [commit-workflow-validation.md](commit-workflow-validation.md) before continuing to Step 4. When `enforcement.strategy=ci`, skip directly to Step 4. -->

## Step 4: Stage

If you intend to include new (untracked) files in this commit, add them explicitly by name first.

Then stage all tracked modifications (including any files touched by the format or lint steps) without accidentally staging untracked files:

```bash
git add -u
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-4-stage" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

<!-- Steps 4.5 and 5 (Record Test Status, Review Gate) are gated by Step 0.6 (enforcement-strategy gate). When `enforcement.strategy=local`, execute the corresponding sections in [commit-workflow-validation.md](commit-workflow-validation.md) before continuing to Step 6. When `enforcement.strategy=ci`, skip directly to Step 6. -->

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
