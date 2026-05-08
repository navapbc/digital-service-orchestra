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
- `commands.test_changed` (optional — when absent, validation Step 1 is skipped)
- `commands.validate` (default: `validate.sh --ci`)

The artifacts directory is computed by `get_artifacts_dir()` in `hooks/lib/deps.sh` and resolves to `/tmp/workflow-plugin-<hash-of-REPO_ROOT>/`.

---

<!-- Schema reference: docs/designs/stage-boundary-preconditions/ -->

## Step 1: Gather Context

### Pre-flight: Ensure `pre-commit` Is Available

Before running any git commands, run the pre-flight check script. It activates the venv if needed and detects/repairs stale git hook shims (left behind when worktrees are cleaned up):

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
source ".claude/scripts/dso ensure-pre-commit.sh" || true
```

If the script warns that `pre-commit` is not found, the commit hooks may fail later. See `.claude/scripts/dso ensure-pre-commit.sh` for the full fallback chain.

### Breadcrumb Init

Truncate the breadcrumb log to prevent unbounded growth, then initialize it for this run.

**MANDATORY (7b41-3061)**: Every numbered Step in this workflow ends with an `echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-N-<name>" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"` line. These are NOT advisory — they are required forensic markers. The orchestrator MUST emit each step's breadcrumb before progressing to the next step. Batching multiple steps into a single bash invocation that drops the breadcrumb writes is a workflow violation: an empty breadcrumb log with a successful commit is a P2 bug because it falsely implies "nothing happened" during forensic reconstruction. If a step's bash block does not include the breadcrumb echo, you have skipped a required action — do not proceed.

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
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-1-gather-context" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 2: Check for Non-Reviewable-Only Changes

Check if all changed files are non-reviewable. If every file matches a non-reviewable pattern, the validation steps that produce a review can be skipped. Otherwise a full review is required.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
git diff HEAD --name-only | bash ".claude/scripts/dso skip-review-check.sh" && SKIP_REVIEW=true || SKIP_REVIEW=false
```

**If `SKIP_REVIEW` is true**: Skip all of `commit-workflow-validation.md` entirely. Go directly to Step 5 (Stage).

**Otherwise**: Continue to Step 3.

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-2-skip-review-check" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

## Step 3: Load Enforcement Profile

Read `enforcement.strategy` from `dso-config.conf` to decide whether local validation steps run before commit, or are deferred to CI.

> **Failure routing**: When a validation or CI failure is found, dispatch using the `discover-agents.sh` routing system (`agent-routing.conf`) by failure category — unit test failures → routing category `test_fix_unit`, lint/type errors → `mechanical_fix`, multi-file/complex (CI-only) → `error-debugging:error-detective`. See [commit-workflow-validation.md](commit-workflow-validation.md) Step 1 for the full routing table.

- `enforcement.strategy=ci` — local validation is **skipped**. All steps in [commit-workflow-validation.md](commit-workflow-validation.md) are deferred to CI; jump directly to Step 5 (Stage) after this gate. The always-on structural hooks (`check-portability`, `check-shim-refs`, `check-contract-schemas`, `check-referential-integrity`, `check-plugin-self-ref` — which blocks literal `${CLAUDE_PLUGIN_ROOT}/`-style paths inside plugin scripts — and `pre-commit-enforcement-boundary-check`) still run; only the gated test/review/quality hooks are deferred.
- `enforcement.strategy=local`, `both`, or **absent** — read and execute [commit-workflow-validation.md](commit-workflow-validation.md) inline before continuing to Step 5. That file holds Steps 1–4 verbatim; Steps 5–6 from it run after Step 5 of this workflow and before Step 6.

> **[Security] Network-partition warning**: When `enforcement.strategy=ci`, this commit will land locally (and may be pushed) before any test/lint/review gate has executed. If CI is unreachable (network partition, GitHub outage, expired credentials, broken workflow), the broken state can reach `main` undetected. Prefer `enforcement.strategy=local` or `both` on long-lived branches, on release-bearing commits, and whenever CI health is unverified. Operators choosing `ci` accept responsibility for verifying CI ran green before merge.

```bash
ENFORCEMENT_STRATEGY=$(grep -m1 '^enforcement\.strategy=' "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-3-load-enforcement-profile strategy=${ENFORCEMENT_STRATEGY:-absent}" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
if [ "$ENFORCEMENT_STRATEGY" = "ci" ]; then echo "enforcement.strategy=ci — skipping local validation"; else echo "enforcement.strategy=${ENFORCEMENT_STRATEGY:-absent} — loading commit-workflow-validation.md"; fi
```

**If `ENFORCEMENT_STRATEGY=ci`**: skip all of `commit-workflow-validation.md`. Proceed to Step 4, then Step 5 (Stage), then Step 6 (Commit).

**Otherwise** (`local`, `both`, or absent): read [commit-workflow-validation.md](commit-workflow-validation.md) and execute its Steps 1, 2, 3, and 4 before Step 5 of this workflow; then execute its Steps 5 and 6 before Step 6 of this workflow.

## Step 4: Emit Commit Workflow Start Event

Emit a durable start event **before** any timeout-prone steps (test, lint, review). This must be committed to the orphan branch so that SIGURG (exit 144) cannot lose it. Incomplete commits are detectable as unpaired start events (start without a matching end in the same session).

> **Failure exits**: If the commit workflow fails at any step (test failure after exhausting retries, lint failure, review escalation to user, commit rejection), emit an end-failure event before aborting:
>
> ```bash
> REPO_ROOT=$(git rev-parse --show-toplevel)
> ".claude/scripts/dso" emit-commit-workflow-event.sh --phase=end --success=false --failure-reason="<step and reason>"
> ```
>
> Replace `<step and reason>` with a concise description (e.g., `"validation Step 1: integration tests failed after 5 attempts"`, `"validation Step 6: review escalated to user"`). This pairs with the start event to close the observability window.

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
".claude/scripts/dso" emit-commit-workflow-event.sh --phase=start
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-4-emit-start-event" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

<!-- The validation steps in commit-workflow-validation.md (Changed Integration/E2E Tests, Format, Lint and Type Check, Write Validation State File) are gated by Step 3 (enforcement-strategy gate). When `enforcement.strategy=local`, execute Steps 1, 2, 3, and 4 of that file before continuing to Step 5. When `enforcement.strategy=ci`, skip directly to Step 5. -->

## Step 5: Stage

If you intend to include new (untracked) files in this commit, add them explicitly by name first.

Then stage all tracked modifications (including any files touched by the format or lint steps) without accidentally staging untracked files:

```bash
git add -u
```

```bash
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) step-5-stage" >> "$ARTIFACTS_DIR/commit-breadcrumbs.log"
```

<!-- Steps 5 and 6 of commit-workflow-validation.md (Record Test Status, Review Gate) are gated by Step 3 (enforcement-strategy gate). When `enforcement.strategy=local`, execute the corresponding sections in [commit-workflow-validation.md](commit-workflow-validation.md) before continuing to Step 6. When `enforcement.strategy=ci`, skip directly to Step 6. -->

## Step 6: Commit

Files are already staged from Step 5. The diff stat summary is already in context from Step 1 or the review workflow. Use that for the commit message — do not re-run `git diff --staged`. If you need a file list, use `git diff --staged --name-only` (minimal output).

Create a single git commit following the repository's commit message conventions visible in the recent commits from Step 1.

### Attribution Pre-Commit (skip if attribution.enabled ≠ true)

**SKIP ENTIRELY when `attribution.enabled` is absent or not `true` in `dso-config.conf`.**

If `attribution.enabled=true`:
- Run `bash apply-attribution-trailers.sh "$COMMIT_MSG_FILE" "${DSO_TASK_ID:-}"` with `ARTIFACTS_DIR` set to the session artifacts dir
- If the script exits non-zero: emit a warning to stderr and continue — this step is **non-blocking**

```bash
ATTRIBUTION_ENABLED=$(grep -m1 '^attribution\.enabled=' "$REPO_ROOT/.claude/dso-config.conf" 2>/dev/null | cut -d= -f2-)
if [[ "${ATTRIBUTION_ENABLED:-}" == "true" ]]; then
    bash apply-attribution-trailers.sh "$COMMIT_MSG_FILE" "${DSO_TASK_ID:-}" || \
        echo "WARNING: apply-attribution-trailers.sh failed (non-blocking)" >&2
fi
```

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

### Attribution Post-Commit Truncate (skip if attribution.enabled ≠ true)

**SKIP ENTIRELY when `attribution.enabled` is absent or not `true` in `dso-config.conf`.**

If `attribution.enabled=true` and the commit exited 0:
- Run `bash apply-attribution-trailers.sh --truncate "$COMMIT_MSG_FILE"` with `ARTIFACTS_DIR` set to the session artifacts dir
- If truncation exits non-zero: emit a warning to stderr but do **not** fail

```bash
if [[ "${ATTRIBUTION_ENABLED:-}" == "true" ]]; then
    bash apply-attribution-trailers.sh --truncate "$COMMIT_MSG_FILE" || \
        echo "WARNING: apply-attribution-trailers.sh --truncate failed (non-blocking)" >&2
fi
```

After committing, report the SHA and **immediately return control to the caller** — do NOT wait for user input. Resume the calling workflow at the step after this commit invocation. If you were executing `/dso:debug-everything`, continue at the step after this commit invocation (Phase F Step 5 for auto-fix commits, or Phase H Step 11 for post-batch commits). If you were executing `/dso:sprint`, continue at Phase F Step 17 (Commit & Push) or the step that invoked this workflow. Do NOT output any text that implies the session is complete.

<!-- Future work: Jira-Ticket and DSO-Task git trailers (story cab1-600f) are planned
     but implementation was deferred. When implemented, this section will document:
     - Jira-Ticket: populated from ticket sync jira_key field
     - DSO-Task: populated from active session task ID
     - Trailers omitted (not errored) when source is unavailable
     See: epic 1083-fb3d consideration SC7 -->

## After Commit: Merging to Main

If you need to merge the worktree branch to main and push, use `merge-to-main.sh` instead of manual `git merge` + `git push`. It handles .claude/scripts/dso ticket sync, merge, and push in a single step, avoiding the review-gate and pre-push hook issues that arise from ticket file changes on main.

```bash
".claude/scripts/dso merge-to-main.sh"
```

Do NOT manually `cd` to the main repo and run `git merge` / `git commit` / `git push` — the review gate hook runs in the worktree context and will block commits on main that aren't ticket-tracking-only.
