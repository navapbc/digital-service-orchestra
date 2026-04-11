## Per-Worktree Review, Commit, and Merge Protocol

For each worktree returned by implementation sub-agents (process in completion order — first-pass-first-merge):

**Step 1 — Enter worktree context**: Note the worktree path as `WORKTREE_PATH`. Compute the worktree's artifacts directory:

```bash
WORKTREE_ARTIFACTS=$(cd "$WORKTREE_PATH" && source plugins/dso/hooks/lib/deps.sh && get_artifacts_dir)
```

**CWD constraint**: The shell CWD resets between Bash calls and does NOT propagate to Agent tool dispatches. Every Bash call that must run in the worktree's git context must be prefixed with `cd $WORKTREE_PATH &&`. Sub-agents dispatched via the Agent tool always start in the orchestrator's primary CWD — this cannot be changed.

**Step 2 — Review in worktree**: The orchestrator runs all CWD-sensitive REVIEW-WORKFLOW.md steps as its own Bash calls (prefixed with `cd $WORKTREE_PATH &&`). Only the code analysis sub-agent is dispatched via Agent tool.

**Orchestrator-run steps** (each a separate Bash call with `cd $WORKTREE_PATH &&`):
- REVIEW-WORKFLOW.md Step 0: Clear stale review artifacts in `$WORKTREE_ARTIFACTS`
- REVIEW-WORKFLOW.md Step 1: Auto-fix pass (format/lint/type-check) — skip if `$WORKTREE_ARTIFACTS/validation-status` is fresh
- REVIEW-WORKFLOW.md Step 2: Capture diff hash via `compute-diff-hash.sh` and write diff/stat files to `$WORKTREE_ARTIFACTS`
- REVIEW-WORKFLOW.md Step 3: Classify review tier via `review-complexity-classifier.sh`

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

**Step 3 — Record test status**: Run `record-test-status.sh` from the worktree context (`cd $WORKTREE_PATH && ...`) to record test results in `$WORKTREE_ARTIFACTS` before commit.

**Step 4 — Commit in worktree branch**: Execute COMMIT-WORKFLOW.md from the worktree context (all Bash calls prefixed with `cd $WORKTREE_PATH &&`). The commit happens in the worktree's branch (not the session branch). Review gate passes because review-status and diff_hash are in `$WORKTREE_ARTIFACTS`.

**Step 5 — Merge worktree branch into session branch**: From the session branch directory, run `git merge <worktree-branch> --no-edit`. merge-state.sh detects MERGE_HEAD, review gate skips the merge commit.

**Step 6 — Handle merge result**:
- **Success** (exit 0): Proceed to Step 7 (cleanup).
- **Conflict** (exit != 0):
  a. Run `git merge --abort` to clean up the failed merge state.
  b. Create a ticket comment: `.claude/scripts/dso ticket comment <story-id> "CONFLICT: worktree <worktree-name> blocked"`
  c. Add the worktree to the **conflict queue** — do NOT remove the worktree (retained for re-implementation).
  d. Continue processing the next worktree — non-conflicting worktrees proceed normally through Steps 2–7.

**Conflict queue — re-implementation protocol** (after all non-conflicting worktrees are merged):

For each worktree in the conflict queue, serialized one at a time against the latest session state:
1. Re-dispatch the original task in the conflicting worktree context (the worktree is still present and available).
2. Each re-implementation targets the post-merge session branch (so it incorporates all previously merged worktrees).
3. After successful re-implementation: follow the full Steps 2–7 flow (review → commit → merge → cleanup).
4. If re-implementation also conflicts: escalate to the user — do not re-queue indefinitely.

**Step 7 — Worktree cleanup**: Only after successful merge: `git worktree remove --force <worktree-path>`.

**Worktree Retention Protocol**: Do NOT remove a worktree until its merge is complete. Worktrees with conflicts are retained for re-implementation. Race condition guard: the worktree must be held open until merge — Claude Code auto-cleanup is suppressed by the presence of uncommitted changes (or a sentinel file).

**Important**: merge-to-main.sh runs ONCE at session end (Phase 8), not per worktree merge. Each per-worktree merge is worktree-branch → session-branch only.
