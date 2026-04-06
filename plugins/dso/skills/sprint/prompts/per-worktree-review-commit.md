## Per-Worktree Review, Commit, and Merge Protocol

For each worktree returned by implementation sub-agents (process in completion order — first-pass-first-merge):

**Step 1 — Enter worktree context**: cd into the worktree directory. Note that ARTIFACTS_DIR is naturally isolated (get_artifacts_dir() hashes REPO_ROOT, which differs per worktree).

**Step 2 — Review in worktree**: Dispatch review sub-agent in worktree cwd. Review writes reviewer-findings.json to the worktree's ARTIFACTS_DIR. Execute REVIEW-WORKFLOW.md.

**Step 3 — Record test status**: Use record-test-status.sh to record test results in the worktree's ARTIFACTS_DIR before commit.

**Step 4 — Commit in worktree branch**: Execute COMMIT-WORKFLOW.md in worktree context. The commit happens in the worktree's branch (not the session branch). Review gate passes because review-status and diff_hash are in the same worktree ARTIFACTS_DIR.

**Step 5 — Merge worktree branch into session branch**: From the session branch directory, run `git merge <worktree-branch> --no-edit`. merge-state.sh detects MERGE_HEAD, review gate skips the merge commit.

**Step 6 — Handle merge result**:
- Success: Proceed to cleanup (Step 7)
- Conflict: Run `git merge --abort`. Flag for re-implementation (see conflict story 064a-4684). DO NOT remove the worktree. Continue to next worktree.

**Step 7 — Worktree cleanup**: Only after successful merge: `git worktree remove --force <worktree-path>`.

**Worktree Retention Protocol**: Do NOT remove a worktree until its merge is complete. Worktrees with conflicts are retained for re-implementation. Race condition guard: the worktree must be held open until merge — Claude Code auto-cleanup is suppressed by the presence of uncommitted changes (or a sentinel file).

**Important**: merge-to-main.sh runs ONCE at session end (Phase 8), not per worktree merge. Each per-worktree merge is worktree-branch → session-branch only.
