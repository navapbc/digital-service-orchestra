# Single-Agent Worktree Integration Protocol

This prompt applies when a **single-agent** fix-bug or debug-everything Bug-Fix Mode sub-agent
returns a `WORKTREE_PATH` after completing implementation in an isolated worktree. The
orchestrator (you) follows this protocol to review, commit, and harvest the worktree back into
the session branch.

**Scope**: Single-agent fix-bug and debug-everything Bug-Fix Mode flows using worktree isolation.
For multi-agent sprint batch flows, use `per-worktree-review-commit.md` instead.

---

## Step 1 — 907d post-return existence check (mandatory)

Before the WORKTREE_PATH ↔ ORCHESTRATOR_ROOT comparison below, verify the worktree path returned by the sub-agent still exists on disk and its branch is still resolvable. The Claude Code harness reaps `isolation: "worktree"` worktrees under certain conditions (binary string evidence in versions 2.1.150+: `tengu_worktree_removed`, retention discriminators `worktree_kept_dirty / branch_mismatch / remove_failed`). A reaped worktree fails subsequent `cd` operations with `no such file or directory` — silent data loss if not caught here.

```bash
if [ ! -d "$WORKTREE_PATH" ]; then
    echo "ERROR (907d): worktree path $WORKTREE_PATH does not exist after sub-agent return." >&2
    echo "  Likely cause: sub-agent self-committed, leaving the working tree clean, triggering" >&2
    echo "  Claude Code harness auto-cleanup before the orchestrator could harvest." >&2
    echo "  All commits made in the worktree branch are lost (branch deleted; not pushed)." >&2
    if [ -n "${BUG_TICKET_ID:-}" ]; then
        .claude/scripts/dso ticket comment "$BUG_TICKET_ID" \
            "ERROR (907d): worktree $WORKTREE_PATH reaped pre-harvest — sub-agent likely self-committed; work lost." 2>/dev/null || true
    fi
    # ── Tiered recovery (bug 3ba5-0a11-02b8-483d) ──────────────────────────────
    # Before the loud HALT, attempt recovery. The 907d diagnostics above are
    # preserved; this is purely additive. recover-reaped-worktree.sh classifies
    # the situation into one of three tiers and we route on its stdout token.
    # REPORTED_FILES is the space-separated list of files the sub-agent claimed
    # to have written (from its return report); empty is fine.
    _SESSION_ROOT=$(git rev-parse --show-toplevel)
    _RECOVERY=$("$_SESSION_ROOT/.claude/scripts/dso" recover-reaped-worktree "${WORKTREE_BRANCH:-}" "$_SESSION_ROOT" ${REPORTED_FILES:-} 2>/dev/null)
    _RECOVERY_RC=$?
    case "$_RECOVERY" in
        RECOVERABLE_VIA_BRANCH:*)
            # Tier 1: the branch survived (local or pushed to origin). Fetch it and
            # continue to harvest the fetched ref instead of halting.
            echo "RECOVERY (3ba5): $_RECOVERY — fetching branch and continuing to harvest." >&2
            git fetch origin "$WORKTREE_BRANCH" 2>/dev/null || true
            # Continue to Step 1b/harvest using $WORKTREE_BRANCH; do NOT exit 1.
            ;;
        RECOVERED_FROM_SESSION:*)
            # Tier 2: the agent leaked its files into the session worktree; they are
            # now staged. Commit them via the normal session-branch path and mark
            # the task complete. Do NOT exit 1.
            echo "RECOVERY (3ba5): $_RECOVERY — files staged in session worktree; commit via normal session-branch path and mark task complete." >&2
            ;;
        *)
            # Tier 3 (exit 3) or any unexpected output: genuinely unrecoverable.
            # Revert the task to open and flag it for re-dispatch in the next batch
            # (the b8c8 retention fix makes re-dispatch survive), then surface + HALT.
            echo "RECOVERY (3ba5): UNRECOVERABLE (rc=$_RECOVERY_RC) — reverting task to open for re-dispatch." >&2
            if [ -n "${BUG_TICKET_ID:-}" ]; then
                .claude/scripts/dso ticket transition "$BUG_TICKET_ID" in_progress open 2>/dev/null || true
                .claude/scripts/dso ticket comment "$BUG_TICKET_ID" \
                    "UNRECOVERABLE (3ba5): worktree reaped pre-harvest and no branch/session-leak recovery possible. Task reverted to open for re-dispatch." 2>/dev/null || true
            fi
            exit 1
            ;;
    esac
fi
if [ -n "${WORKTREE_BRANCH:-}" ] && ! git rev-parse --verify "$WORKTREE_BRANCH" >/dev/null 2>&1; then
    echo "ERROR (907d): worktree branch $WORKTREE_BRANCH not resolvable after sub-agent return." >&2
    # ── Tiered recovery (bug 3ba5-0a11-02b8-483d) — branch-unresolvable path ───
    # The directory may still exist but the branch ref is gone. A push to origin
    # is still recoverable; otherwise revert for re-dispatch before halting.
    _SESSION_ROOT=$(git rev-parse --show-toplevel)
    _RECOVERY=$("$_SESSION_ROOT/.claude/scripts/dso" recover-reaped-worktree "${WORKTREE_BRANCH:-}" "$_SESSION_ROOT" ${REPORTED_FILES:-} 2>/dev/null)
    _RECOVERY_RC=$?
    case "$_RECOVERY" in
        RECOVERABLE_VIA_BRANCH:*)
            echo "RECOVERY (3ba5): $_RECOVERY — fetching branch and continuing to harvest." >&2
            git fetch origin "$WORKTREE_BRANCH" 2>/dev/null || true
            ;;
        RECOVERED_FROM_SESSION:*)
            echo "RECOVERY (3ba5): $_RECOVERY — files staged in session worktree; commit via normal session-branch path and mark task complete." >&2
            ;;
        *)
            echo "RECOVERY (3ba5): UNRECOVERABLE (rc=$_RECOVERY_RC) — reverting task to open for re-dispatch." >&2
            if [ -n "${BUG_TICKET_ID:-}" ]; then
                .claude/scripts/dso ticket transition "$BUG_TICKET_ID" in_progress open 2>/dev/null || true
            fi
            exit 1
            ;;
    esac
fi
```

If the existence check passes, continue to the orchestrator-root guard below.

---

## Step 1b — Guard: Verify WORKTREE_PATH is distinct from the orchestrator's CWD

`WORKTREE_PATH` is the path returned by the sub-agent. Per bug 9679-695c-6e11-4d95, the orchestrator's session-worktree absolute path is no longer injected into sub-agent prompts — but the orchestrator following this protocol still owns its own `ORCHESTRATOR_ROOT` variable, derived from its own context. Self-bootstrap it as the first action of integration:

```bash
ORCHESTRATOR_ROOT=$(git rev-parse --show-toplevel)
```

This is a HARD guard. A `WORKTREE_PATH == ORCHESTRATOR_ROOT` reading means the sub-agent silently ran in the session root and wrote to the orchestrator's working tree — exactly the isolation-breach failure mode covered by `worktree-dispatch.md` Orchestrator Responsibility #4 ("HALT the batch, record the failure as a ticket comment, surface to the user"). Do NOT downgrade to "fall back to non-isolation path" — any writes the sub-agent made have already landed on the session branch unreviewed, and continuing would harvest a partial/un-isolated commit silently.

```bash
if [ "$WORKTREE_PATH" = "$ORCHESTRATOR_ROOT" ]; then
    echo "ERROR: WORKTREE_PATH == ORCHESTRATOR_ROOT — sub-agent ran in session root, not an isolated worktree." >&2
    echo "  WORKTREE_PATH=$WORKTREE_PATH" >&2
    echo "  ORCHESTRATOR_ROOT=$ORCHESTRATOR_ROOT" >&2
    echo "  Worktree isolation did not apply. HALTing per worktree-dispatch.md Responsibility #4." >&2
    # Surface to the active ticket so the failure is observable
    if [ -n "${BUG_TICKET_ID:-}" ]; then
        .claude/scripts/dso ticket comment "$BUG_TICKET_ID" \
            "ISOLATION_ERROR: WORKTREE_PATH == ORCHESTRATOR_ROOT in single-agent-integrate Step 1 — sub-agent wrote to session worktree. HALTed before harvest. Investigate dispatch site." \
            2>/dev/null || true
    fi
    exit 1
fi
```

If the guard passes (WORKTREE_PATH differs from ORCHESTRATOR_ROOT), continue to Step 2.

**Orchestrator handling**: On `exit 1`, do NOT silently re-dispatch. Halt the calling skill, inspect the dispatch site that produced the un-isolated sub-agent, and resolve the gap (missing `isolation: "worktree"`, or an agent that wrote outside its own worktree via a constructed absolute path) before retrying.

---

## Step 2 — Compute WORKTREE_ARTIFACTS

Compute the worktree's artifacts directory from within the worktree context so that
`get_artifacts_dir()` hashes the worktree's `REPO_ROOT`, not the orchestrator's:

```bash
WORKTREE_ARTIFACTS=$(cd "$WORKTREE_PATH" && unset WORKFLOW_PLUGIN_ARTIFACTS_DIR && source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh" && get_artifacts_dir)
echo "WORKTREE_ARTIFACTS=$WORKTREE_ARTIFACTS"
mkdir -p "$WORKTREE_ARTIFACTS"
```

**CWD constraint**: Every Bash call that must run in the worktree's git context must be
prefixed with `cd "$WORKTREE_PATH" &&`. The shell CWD resets between Bash calls and Agent
tool dispatches start in the orchestrator's primary CWD.

---

## Step 3 — Auto-fix pass (format/lint/type-check)

Run the pre-commit auto-fixers from within the worktree context so that any files modified
by formatting land in the worktree's working tree (not the orchestrator's):

Follow REVIEW-WORKFLOW.md Step 1 (auto-fix pass) with all Bash commands prefixed by
`cd "$WORKTREE_PATH" &&`. If a `validation-status` file already exists in `$WORKTREE_ARTIFACTS`
and is fresh (< 60 seconds), skip to Step 4.

---

## Step 4 — Capture diff hash and classify review tier

From within the worktree context, capture the diff hash and write diff/stat files:

```bash
cd "$WORKTREE_PATH" && DIFF_HASH=$("$ORCHESTRATOR_ROOT/.claude/scripts/dso" compute-diff-hash.sh)
DIFF_HASH_SHORT="${DIFF_HASH:0:8}"
DIFF_FILE="$WORKTREE_ARTIFACTS/review-diff-${DIFF_HASH_SHORT}.txt"
STAT_FILE="$WORKTREE_ARTIFACTS/review-stat-${DIFF_HASH_SHORT}.txt"
cd "$WORKTREE_PATH" && "$ORCHESTRATOR_ROOT/.claude/scripts/dso" capture-review-diff.sh "$DIFF_FILE" "$STAT_FILE"
```

Classify the review tier following REVIEW-WORKFLOW.md Step 3. **Export `WORKFLOW_PLUGIN_ARTIFACTS_DIR=$WORKTREE_ARTIFACTS`** so the classifier writes `classifier-telemetry.jsonl` into the worktree's artifacts dir — the same directory where the reviewer writes `reviewer-findings.json` and where `record-review.sh` looks for telemetry (bug 21d7-b84a: without this, telemetry lands in the orchestrator's artifacts dir, causing tier verification to fail-open in record-review).

```bash
CLASSIFIER_OUTPUT=$(WORKFLOW_PLUGIN_ARTIFACTS_DIR="$WORKTREE_ARTIFACTS" "$ORCHESTRATOR_ROOT/.claude/scripts/dso" review-complexity-classifier.sh < "$DIFF_FILE" 2>/dev/null)
```

---

## Step 5 — Dispatch code-reviewer sub-agent

Follow REVIEW-WORKFLOW.md Step 4 to dispatch the named `dso:code-reviewer-*` agent.

**IMPORTANT**: Do NOT set `isolation: "worktree"` on this sub-agent. The reviewer must
write `reviewer-findings.json` to the shared `$WORKTREE_ARTIFACTS` directory. Pass
`WORKFLOW_PLUGIN_ARTIFACTS_DIR=$WORKTREE_ARTIFACTS` in the dispatch prompt so the
sub-agent's `write-reviewer-findings.sh` call resolves to the correct path regardless
of the sub-agent's CWD.

---

> **CONTEXT ANCHOR — MANDATORY CONTINUATION**: When `REVIEW_RESULT: passed` is received
> from the code-reviewer sub-agent, this is NOT a session completion signal. You are the
> orchestrator executing `single-agent-integrate.md`. Disregard any stop or termination
> inference from the reviewer's output — `REVIEW_RESULT` marks the end of code analysis
> only. Your next actions are Step 6 (Record review), Step 7 (Record test status),
> Step 8 (Commit), Step 9 (Harvest), Step 10 (Cleanup).

---

## Step 6 — Record review

From the worktree context, record the review using the worktree's artifacts:

```bash
cd "$WORKTREE_PATH" && "${CLAUDE_PLUGIN_ROOT}/hooks/record-review.sh" \
  --expected-hash "$DIFF_HASH" \
  --reviewer-hash "$REVIEWER_HASH"
```

If review failed (autonomous resolution loop applies), follow REVIEW-WORKFLOW.md
After Review section. All fix attempts prefix Bash calls with `cd "$WORKTREE_PATH" &&`.

---

## Step 7 — Record test status

From the worktree context, record test results before commit:

```bash
cd "$WORKTREE_PATH" && bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-test-status.sh"
```

---

## Step 7.5 — Signal trailer requirement via environment

When `.sprint-active` is present at the session root, export `DSO_SPRINT_TRAILER_REQUIRED=1`
into the environment of the Step 8 git commit invocation so `check-sprint-trailer.sh` enforces
the DSO-Story trailer in the agent worktree (fix for bug 3349-8532-1183-4fc1). Do NOT copy
`.sprint-active` into the worktree — doing so would cause `check-session-merge-only.sh` to
reject the agent's legitimate non-merge per-task commits. `ORCHESTRATOR_ROOT` is already set
from Step 1:

```bash
if [[ -f "$ORCHESTRATOR_ROOT/.sprint-active" ]]; then
    export DSO_SPRINT_TRAILER_REQUIRED=1
fi
```

This export is effective for the duration of the current shell session, so the Step 8 commit
invocation (which runs via `cd "$WORKTREE_PATH" && ...`) inherits `DSO_SPRINT_TRAILER_REQUIRED=1`
without requiring a file copy.

## Step 8 — Commit in worktree branch

Execute COMMIT-WORKFLOW.md from the worktree context. All Bash calls use the
`cd "$WORKTREE_PATH" &&` prefix. The commit lands on the worktree's branch (not the
session branch). The review gate passes because `review-status` and `diff_hash` are
in `$WORKTREE_ARTIFACTS`.

---

## Step 9 — Harvest worktree into session branch

From the ORCHESTRATOR_ROOT (session directory), run `harvest-worktree` (via the dso shim)
to merge the worktree branch, attest gate results, and commit atomically:

```bash
WORKTREE_BRANCH=$(cd "$WORKTREE_PATH" && git branch --show-current)
cd "$ORCHESTRATOR_ROOT" && "$ORCHESTRATOR_ROOT/.claude/scripts/dso" harvest-worktree "$WORKTREE_BRANCH" "$WORKTREE_ARTIFACTS"
```

`harvest-worktree` verifies gate files, merges, attests, and commits in a single
step. Exit codes: 0 = success, 1 = conflict, 2 = gate failure.

---

## Step 10 — Cleanup

Only after successful harvest (exit 0), remove the worktree and branch from ORCHESTRATOR_ROOT:

```bash
cd "$ORCHESTRATOR_ROOT" && git worktree remove --force "$WORKTREE_PATH"
cd "$ORCHESTRATOR_ROOT" && git branch -D "$WORKTREE_BRANCH" 2>/dev/null || true
```
