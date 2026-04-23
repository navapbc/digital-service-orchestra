# Auto Resume Detection and Recovery Protocol 

(a) Print: `"Ticket <primary_ticket_id> is in_progress — resuming from checkpoint scan."`

(b) Run `.claude/scripts/dso ticket deps <primary_ticket_id>` to check for children.

(c) **If zero children**: Log `"No children found — falling through to Preplanning Gate."` and continue to Drift Detection → Preplanning Gate normally (scenario: abandoned mid-preplanning, skip checkpoint resume).

(d) **If children exist**:
   - Run drift detection with `--status=open` filter:
     ```
     DRIFT_RESULT=$(.claude/scripts/dso sprint-drift-check.sh <primary_ticket_id> --status=open)
     ```
   - Handle `DRIFT_DETECTED` / `NO_DRIFT` the same as the existing Drift Detection Check section below.
   - Then apply checkpoint resume rules:
     1. Run `.claude/scripts/dso ticket list` and filter for in-progress tickets that are descendants of `<primary_ticket_id>` for interrupted tasks
     2. For each in-progress descendant, run `.claude/scripts/dso ticket show <id>` and parse its notes for CHECKPOINT lines
     3. Apply checkpoint resume rules:
        - **CHECKPOINT 6/6 ✓** — ticket is fully done; fast-close: verify files exist for task tickets or run completion verifier for story tickets, then `.claude/scripts/dso ticket transition <id> in-progress closed`
        - **CHECKPOINT 5/6 ✓** — near-complete; fast-close: spot-check files and close without re-execution
        - **CHECKPOINT 3/6 ✓ or 4/6 ✓** — partial progress; re-dispatch with resume context: include the highest checkpoint note in the sub-agent prompt so it can continue from that substep
        - **CHECKPOINT 1/6 ✓ or 2/6 ✓** — early progress only; revert to open with `.claude/scripts/dso ticket transition <id> in-progress open` for full re-execution
        - **No CHECKPOINT lines or malformed CHECKPOINT lines** — revert to open: `.claude/scripts/dso ticket transition <id> in-progress open`
     4. Fallback rule: if CHECKPOINT lines are present but ambiguous (missing ✓, duplicate numbers, non-sequential), treat as malformed → revert to open
     5. **Backward compatibility**: Sprint reads old positional-counter checkpoints (CHECKPOINT N/6) without error and resumes from the last completed phase — no migration of existing checkpoint notes is required. Semantic-named checkpoints (CHECKPOINT:batch-complete, CHECKPOINT:review-passed, CHECKPOINT:validation-passed) are equivalent in resume logic.
   - After checkpoint processing, run the **WORKTREE_TRACKING Auto-Resume Detection** scan before proceeding to Phase 3:

     **WORKTREE_TRACKING Auto-Resume Detection Scan** (runs after checkpoint processing):
     1. Enumerate tickets to scan: the top-level epic ticket + all child story/task tickets
        - Get children via: `.claude/scripts/dso ticket deps <primary_ticket_id>` (open + closed, use `--include-archived`)
        - Also scan the top-level ticket itself
     2. For each ticket, read comments (`.claude/scripts/dso ticket show <id>`) and find `WORKTREE_TRACKING:start` comments with no corresponding `:complete` (for task tickets) or `:landed` (for story/bug tickets)
     3. If multiple unmatched starts exist, de-duplicate by branch name (keep most recent timestamp per branch), then apply tiebreak cascade:
        - Stage 1: Count verbatim task-list criterion matches (`- [ ]`/`- [x]` items in ticket description that appear in the branch's git diff). Higher wins.
        - Stage 2: Compare test-gate-status artifact in each branch (`passed` > `failed` > absent). Winner proceeds.
        - Stage 3: Count merge conflicts via dry-run (`git merge --no-commit --no-ff <branch>`; count conflict markers; then `git merge --abort`). Lower wins.
        - Stage 4: Most recent `WORKTREE_TRACKING:start` timestamp wins.
        - Merge the winner; discard (log, skip) the rest.
     4. For each unmatched start, extract the branch name:
        - If branch no longer exists locally: skip without error, log `'Branch <b> not found — skipping'`
        - If branch is ancestor of HEAD (already merged): write retroactive `:complete` with `outcome=already_merged`, skip re-merge
        - If git is in mid-merge state (MERGE_HEAD exists): run `git merge --abort` first
        - If branch has unique commits (not in HEAD): attempt `git merge --no-edit <branch>`
          - On success: log `'Merged abandoned branch <b>'`
          - On conflict: run `git merge --abort`, log `'Conflict in <b> — discarded'`
     5. After scan: if repo is clean, proceed to Phase 3

   - Proceed to Phase 3.

(e) **Non-epic tickets** (story, task, bug) with `in_progress` status are NOT affected by auto-resume detection — they proceed through Non-Epic Routing as before. Auto-resume only applies to epic-type tickets.

(f) Run `.claude/scripts/dso ticket deps <primary_ticket_id>` — if 100% complete, skip to Phase 6 (validation)