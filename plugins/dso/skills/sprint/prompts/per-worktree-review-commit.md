## Per-Worktree Review, Commit, and Merge Protocol

For each worktree returned by implementation sub-agents (process in completion order — first-pass-first-merge):

**Step 1 — Enter worktree context**: cd into the worktree directory. Note that ARTIFACTS_DIR is naturally isolated (get_artifacts_dir() hashes REPO_ROOT, which differs per worktree). All bash commands in Steps 2–4 must be run from within this worktree directory.

**Step 2 — Review in worktree**: Execute REVIEW-WORKFLOW.md from the worktree directory. The orchestrator runs Steps 0–2 (clear artifacts, auto-fix, capture diff hash) and Step 3 (classify tier) directly — these are bash commands that must execute in the worktree's git context so `compute-diff-hash.sh` and `get_artifacts_dir()` resolve against the worktree's staged changes and REPO_ROOT.

When dispatching the review sub-agent in Step 4, do NOT set `isolation: "worktree"` on the Agent tool (per REVIEW-WORKFLOW.md — isolation creates a separate branch, which would hide the findings from the orchestrator). Instead, include explicit CWD instructions in the sub-agent prompt:

```
IMPORTANT: Before running any commands, change to the worktree directory:
cd <worktree-path>
All commands in this review must run from that directory.
```

This ensures the review sub-agent's `write-reviewer-findings.sh` writes to the worktree's ARTIFACTS_DIR (via `get_artifacts_dir()` resolving against the worktree's REPO_ROOT), while the sub-agent remains on the same branch as the orchestrator (no branch isolation).

After the review sub-agent returns, the orchestrator runs Step 5 (`record-review.sh`) from the worktree directory so it reads findings from the correct ARTIFACTS_DIR.

**Step 3 — Record test status**: Use record-test-status.sh to record test results in the worktree's ARTIFACTS_DIR before commit.

**Step 4 — Commit in worktree branch**: Execute COMMIT-WORKFLOW.md in worktree context. The commit happens in the worktree's branch (not the session branch). Review gate passes because review-status and diff_hash are in the same worktree ARTIFACTS_DIR.

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
