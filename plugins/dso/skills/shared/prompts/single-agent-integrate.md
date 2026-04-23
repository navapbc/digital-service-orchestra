# Single-Agent Worktree Integration Protocol

This prompt applies when a **single-agent** fix-bug or debug-everything Bug-Fix Mode sub-agent
returns a `WORKTREE_PATH` after completing implementation in an isolated worktree. The
orchestrator (you) follows this protocol to review, commit, and harvest the worktree back into
the session branch.

**Scope**: Single-agent fix-bug and debug-everything Bug-Fix Mode flows where
`worktree.isolation_enabled=true`. For multi-agent sprint batch flows, use
`per-worktree-review-commit.md` instead.

---

## Step 1 — Guard: Verify WORKTREE_PATH is distinct from ORCHESTRATOR_ROOT

`ORCHESTRATOR_ROOT` is the session root — it must have been passed explicitly in the
sub-agent dispatch prompt. `WORKTREE_PATH` is the path returned by the sub-agent.

```bash
if [ "$WORKTREE_PATH" = "$ORCHESTRATOR_ROOT" ]; then
    echo "ERROR: WORKTREE_PATH == ORCHESTRATOR_ROOT — sub-agent ran in session root, not an isolated worktree."
    echo "  WORKTREE_PATH=$WORKTREE_PATH"
    echo "  ORCHESTRATOR_ROOT=$ORCHESTRATOR_ROOT"
    echo "  This means worktree isolation did not apply. Treat this as a non-isolated flow:"
    echo "  follow the existing post-dispatch gates in the calling skill (fix-bug Step 7 or"
    echo "  debug-everything Bug-Fix Mode) without harvesting."
    exit 0  # Not an error — fall back to existing non-isolation path
fi
```

If the guard passes (WORKTREE_PATH differs from ORCHESTRATOR_ROOT), continue to Step 2.

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
cd "$WORKTREE_PATH" && DSO_COMMIT_WORKFLOW=1 bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-test-status.sh"
```

The `DSO_COMMIT_WORKFLOW=1` prefix is required — `hook_record_test_status_guard` (PreToolUse) blocks unprefixed direct calls.

---

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
