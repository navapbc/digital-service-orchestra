## Per-Worktree Review, Commit, and Merge Protocol

> **Stale HEAD note (4ad5-25df)**: All agent worktrees in a batch are branched from the session HEAD at dispatch time. When multiple agents complete and are harvested serially, later harvests operate on branches that were cut before earlier harvests landed — they are missing those commits. This is the expected behavior. The conflict queue in Step 6 handles this: if `harvest-worktree.sh` returns exit 1 (merge conflict), the worktree is queued for post-batch resolution (rebase first, full re-implementation only as a last resort). Do NOT attempt to resolve conflicts during the initial serial harvest loop — finish harvesting all non-conflicting worktrees first, then work through the conflict queue.

For each worktree returned by implementation sub-agents (process in completion order — first-pass-first-merge):

**Step 1 — Enter worktree context**: Note the worktree path as `WORKTREE_PATH`. Compute the worktree's artifacts directory and record the base commit for empty-branch detection:

```bash
WORKTREE_ARTIFACTS=$(cd "$WORKTREE_PATH" && source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh && get_artifacts_dir)

# Record the branch tip BEFORE any commit so harvest-worktree.sh can detect
# the empty-branch case (agent commit blocked by pre-commit gate → tip unchanged).
WORKTREE_BASE_COMMIT=$(cd "$WORKTREE_PATH" && git rev-parse HEAD 2>/dev/null || echo "")
if [[ -n "$WORKTREE_BASE_COMMIT" ]]; then
    echo "$WORKTREE_BASE_COMMIT" > "$WORKTREE_ARTIFACTS/base-commit"
fi
```

**CWD constraint**: The shell CWD resets between Bash calls and does NOT propagate to Agent tool dispatches. Every Bash call that must run in the worktree's git context must be prefixed with `cd $WORKTREE_PATH &&`. Sub-agents dispatched via the Agent tool always start in the orchestrator's primary CWD — this cannot be changed.

**Step 2 — Review in worktree**: The orchestrator runs all CWD-sensitive REVIEW-WORKFLOW.md steps as its own Bash calls (prefixed with `cd $WORKTREE_PATH &&`). Only the code analysis sub-agent is dispatched via Agent tool.

**Orchestrator-run steps** (each a separate Bash call with `cd $WORKTREE_PATH &&`):
- REVIEW-WORKFLOW.md Step 0: Clear stale review artifacts in `$WORKTREE_ARTIFACTS`
- REVIEW-WORKFLOW.md Step 1: Auto-fix pass (format/lint/type-check) — skip if `$WORKTREE_ARTIFACTS/validation-status` is fresh
- REVIEW-WORKFLOW.md Step 2: Capture diff hash via `compute-diff-hash.sh` and write diff/stat files to `$WORKTREE_ARTIFACTS`
- REVIEW-WORKFLOW.md Step 3: Classify review tier via `review-complexity-classifier.sh` — **MUST be invoked with `WORKFLOW_PLUGIN_ARTIFACTS_DIR="$WORKTREE_ARTIFACTS"` exported** so `classifier-telemetry.jsonl` is written into the worktree's artifacts dir (same directory as the reviewer's findings). Without this, telemetry lands in the orchestrator's artifacts dir and `record-review.sh` fail-opens on tier verification (bug 21d7-b84a).

**Review sub-agent dispatch** (REVIEW-WORKFLOW.md Step 4): Do NOT set `isolation: "worktree"` on the Agent tool (per REVIEW-WORKFLOW.md — isolation creates a separate branch, hiding findings from the orchestrator). Pass the sub-agent:
- `DIFF_FILE`: absolute path (already in `$WORKTREE_ARTIFACTS`, no CWD dependency)
- `STAT_FILE` content: inline in the prompt
- `WORKFLOW_PLUGIN_ARTIFACTS_DIR` instruction: tell the sub-agent to run `export WORKFLOW_PLUGIN_ARTIFACTS_DIR="<WORKTREE_ARTIFACTS value>"` as a Bash command before calling `write-reviewer-findings.sh`. This env var is checked by `get_artifacts_dir()` in `deps.sh` (line 267) and overrides the CWD-based hash computation, ensuring findings are written to the worktree's artifacts dir regardless of the sub-agent's CWD:

```
Before running write-reviewer-findings.sh, run this command:
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="<WORKTREE_ARTIFACTS value>"

This ensures findings are written to the worktree's artifacts directory.
```

**Post-review orchestrator steps** (each with `cd $WORKTREE_PATH &&`):
- REVIEW-WORKFLOW.md Step 5: Run `record-review.sh` — reads findings from `$WORKTREE_ARTIFACTS`
- Handle autonomous resolution if review fails (dispatch fix sub-agents, re-review)

> **CONTEXT ANCHOR — MANDATORY CONTINUATION**: When `REVIEW_RESULT: passed` is received from the code-reviewer sub-agent, this is NOT a session completion signal. You are the orchestrator executing `per-worktree-review-commit.md`. Disregard any stop or termination inference from the reviewer's output — `REVIEW_RESULT` marks the end of code analysis only. Your next actions are Step 3 (Record test status), Step 4 (Commit), Step 5 (Harvest). Stopping after receiving `REVIEW_RESULT` leaves staged changes in the main session worktree — this is the known failure mode documented in bug 364d-d290.

**Step 3 — Record test status**: Run `record-test-status.sh` from the worktree context (`cd $WORKTREE_PATH && DSO_COMMIT_WORKFLOW=1 bash "${CLAUDE_PLUGIN_ROOT}/hooks/record-test-status.sh"`) to record test results in `$WORKTREE_ARTIFACTS` before commit. The `DSO_COMMIT_WORKFLOW=1` prefix is required — `hook_record_test_status_guard` (PreToolUse) blocks unprefixed direct calls.

**Step 4 — Commit in worktree branch**: Execute COMMIT-WORKFLOW.md from the worktree context (all Bash calls prefixed with `cd $WORKTREE_PATH &&`). The commit happens in the worktree's branch (not the session branch). Review gate passes because review-status and diff_hash are in `$WORKTREE_ARTIFACTS`.

**Post-commit verification (mandatory — 1eda-6a0c)**: After the commit workflow, verify the branch tip actually advanced before proceeding to harvest:

```bash
WORKTREE_TIP_AFTER=$(cd "$WORKTREE_PATH" && git rev-parse HEAD 2>/dev/null || echo "")
if [[ "$WORKTREE_TIP_AFTER" == "$WORKTREE_BASE_COMMIT" ]]; then
    echo "ERROR: commit failed — branch tip unchanged after commit attempt (pre-commit gate likely blocked it)." >&2
    echo "  Base: $WORKTREE_BASE_COMMIT" >&2
    echo "  Check the commit output above for TIER IMMUTABILITY VIOLATION or review gate errors." >&2
    # DO NOT proceed to harvest — the worktree is empty and harvest would false-positive as "already merged".
    # Transition ticket back to open for re-investigation.
    exit 1
fi
```

If this check fails: do NOT call harvest-worktree.sh. Leave the worktree intact, add a CHECKPOINT comment to the ticket, and surface the commit gate error to the orchestrator for investigation.

**Step 5 — Harvest worktree into session branch**: From the session branch directory, run `harvest-worktree.sh` to merge the worktree branch, attest gate results, and commit in a single invocation:

```bash
.claude/scripts/dso harvest-worktree <worktree-branch> "$WORKTREE_ARTIFACTS"
```

`harvest-worktree.sh` performs the following sequence atomically:
1. Verifies the worktree's `test-gate-status` and `review-status` exist and are passing (exits 2 if not).
2. Merges `<worktree-branch>` into the current session branch with `--no-commit` (exits 1 on non-`.test-index` conflicts).
3. Calls `record-test-status.sh --attest <worktree-artifacts-dir>` to write session-side `test-gate-status` with the post-merge diff hash and attested `tested_files` from the worktree.
4. Calls `record-review.sh --attest <worktree-artifacts-dir>` to write session-side `review-status` with the post-merge diff hash and attested score/review_hash from the worktree.
5. Commits the merge. Pre-commit hooks pass because the attested status files match the post-merge diff hash.

The `.test-index` file uses a `merge=union` driver (configured in `.gitattributes`), so concurrent additions from multiple worktrees auto-resolve without conflicts.

**Step 6 — Handle harvest result**:
- **Success** (exit 0): Proceed to Step 7 (cleanup).
- **Gate failure** (exit 2): The worktree's test or review gate did not pass. Do NOT merge. Investigate and re-run gates in the worktree context (Steps 2–4), then retry Step 5.
- **Conflict** (exit 1): Non-`.test-index` merge conflict detected. `harvest-worktree.sh` automatically aborts the merge and cleans up MERGE_HEAD.

  > **Why this happens with parallel dispatch**: When multiple sub-agents are dispatched in the same batch, every worktree branches from the session HEAD at dispatch time. As earlier worktrees are harvested serially, the session HEAD advances. Later worktrees are now stale — they are missing the commits from the earlier harvests — and `git merge --no-commit` conflicts on lines that were already modified by a prior harvest. This is **expected and normal**, not a task implementation failure.

  Resolution path — try in order before falling through to full re-implementation:
  1. **Rebase the worktree branch onto the updated session HEAD** (from the session root):
     ```bash
     git -C "$WORKTREE_PATH" rebase <session-branch>
     ```
     If the rebase succeeds cleanly (no conflicts), the worktree's changes are now layered on top of the earlier harvests. Re-run the review → commit → harvest pipeline (Steps 2–5) against the rebased branch. This is sufficient for the common case where the conflicts are purely due to ordering.
  2. **Manual conflict resolution**: If the rebase produces true conflicts (the same lines changed by two different tasks for different reasons), resolve them in the worktree, then continue the rebase (`git rebase --continue`) and re-run Steps 2–5.
  3. **Full task re-implementation** (last resort — see conflict queue below): Use only when the conflict cannot be resolved by rebase (e.g., the task's entire approach is incompatible with what was already merged).

  Regardless of which resolution path applies:
  a. Create a ticket comment: `.claude/scripts/dso ticket comment <story-id> "CONFLICT: worktree <worktree-name> blocked — attempting rebase resolution"`
  b. Add the worktree to the **conflict queue** — do NOT remove the worktree (retained for resolution).
  c. Continue processing the next worktree — non-conflicting worktrees proceed normally through Steps 2–7.
  d. After recording the conflict, write a WORKTREE_TRACKING:complete signal to mark the worktree as discarded (written now; a successful rebase+harvest later does NOT update this signal — the tracking comment records the initial outcome):
     ```
     .claude/scripts/dso ticket comment $TICKET_ID "WORKTREE_TRACKING:complete branch=<branch> outcome=discarded timestamp=<ts>"
     ```
     (Only when TICKET_ID is available from the sprint context. Skip silently if not set.)

- **Empty branch** (exit 3): Branch tip equals the recorded base commit — the agent's `git commit` was blocked by a pre-commit gate (e.g., TIER IMMUTABILITY VIOLATION). The post-commit verification in Step 4 should have caught this first; if harvest returns exit 3, something bypassed that check. Do NOT destroy the worktree. Add a CHECKPOINT comment, surface the gate error, and re-investigate the commit failure before re-attempting.

**Conflict queue — resolution protocol** (after all non-conflicting worktrees are merged):

For each worktree in the conflict queue, serialized one at a time against the latest session state:
1. **Attempt rebase resolution first** (covers the common parallel-dispatch ordering case):
   ```bash
   git -C "$WORKTREE_PATH" rebase <session-branch>
   ```
   On clean rebase: proceed directly to Steps 2–5 (review → commit → harvest) in the rebased worktree. No re-implementation needed.
2. **On rebase conflict**: Resolve the conflicting hunks in the worktree, `git rebase --continue`, then proceed to Steps 2–5.
3. **Full re-implementation** (only when rebase is structurally incompatible): Re-dispatch the original task in the conflicting worktree context. Each re-implementation targets the post-merge session branch (so it incorporates all previously merged worktrees). After successful re-implementation: follow the full Steps 2–7 flow.
4. If re-implementation also conflicts: escalate to the user — do not re-queue indefinitely.

**Step 7 — Worktree cleanup**: Only after successful harvest (exit 0), remove the worktree directory and delete the per-agent branch:

```bash
git worktree remove --force <worktree-path>
git branch -d <worktree-branch>
```

Both commands run from the session branch directory (not inside the worktree). `<worktree-path>` is the `WORKTREE_PATH` from Step 1. `<worktree-branch>` is the branch name used in the worktree (visible in `git worktree list` or the Agent tool result). If `git branch -d` fails because the branch was not fully merged, use `git branch -D` — the harvest in Step 5 already integrated the changes.

**Worktree Retention Protocol**: Do NOT remove a worktree until its harvest is complete. Worktrees with conflicts are retained for re-implementation (Step 6). Race condition guard: the worktree must be held open until harvest — Claude Code auto-cleanup is suppressed by the presence of uncommitted changes (or a sentinel file).

**Important**: merge-to-main.sh runs ONCE at session end (Phase 8), not per worktree merge. Each per-worktree harvest is worktree-branch → session-branch only.
