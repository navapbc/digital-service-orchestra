---
id: dso-qt4u
status: in_progress
deps: []
links: []
created: 2026-03-20T00:04:06Z
type: bug
priority: 1
assignee: Joe Oakhart
parent: dso-9xnr
---
# Bug: merge-to-main.sh fails on archive rename/delete conflicts and doesn't support agent-driven conflict resolution


## Notes

<!-- note-id: 4wr4acjo -->
<!-- timestamp: 2026-03-20T00:04:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Bug Description

merge-to-main.sh has two related problems observed during a worktree merge session:

### Problem 1: Archive rename/delete conflicts crash the script
When a previous merge archived tickets (moving .tickets/dso-xxx.md to .tickets/archive/dso-xxx.md), and the remote main has a different archive commit, git pull --rebase produces CONFLICT (rename/delete) errors. The script aborts with ERROR and doesn't offer recovery — the user must manually resolve conflicts and figure out how to resume.

### Problem 2: No agent-driven conflict resolution path
When the script encounters a conflict during rebase, it prints an error and exits. There's no way for a Claude agent to:
1. Inspect the conflict
2. Resolve it (e.g., git rm conflicting files, git rebase --continue)
3. Resume the merge-to-main flow from where it left off

The --resume flag re-runs from the first incomplete phase, which re-triggers the same conflict.

### Reproduction
1. Merge worktree to main (creates archive commit)
2. Another worktree pushes a different archive commit to main
3. Next worktree merge hits rename/delete conflict on archived ticket files
4. Script aborts, agent cannot recover

### Expected Behavior
- merge-to-main.sh should handle archive-related conflicts automatically (archive rename/delete conflicts are always safe to resolve by accepting the deletion)
- For non-trivial conflicts, the script should pause with clear instructions, allow the agent to resolve, and support resuming from the conflict point
- The --resume flag should detect mid-rebase state and offer to continue the rebase rather than restarting the phase

### Workaround Used
Manually ran git reset --hard origin/main on main repo, then re-ran merge-to-main.sh (lost the divergent archive commit).


<!-- note-id: gd74e4b1 -->
<!-- timestamp: 2026-03-20T22:46:01Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Fixed in merge-to-main.sh: (1) Added _auto_resolve_archive_conflicts() function that detects rename/delete conflicts in .tickets/archive/ during git pull --rebase and auto-resolves them safely; (2) Updated pull failure handler in _phase_sync to call auto-resolve before giving up; (3) Added REBASE_HEAD detection to --resume dispatch so mid-rebase state is detected and recovery is offered; (4) Added --resume instruction to the manual conflict error message. Tests: 10 new tests in test-merge-to-main-qt4u.sh all pass GREEN.
