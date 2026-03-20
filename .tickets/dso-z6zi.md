---
id: dso-z6zi
status: open
deps: []
links: []
created: 2026-03-20T04:01:57Z
type: task
priority: 2
assignee: Joe Oakhart
---
# Worktree left unclean after end-session / main left dirty after merge-to-main


## Notes

<!-- note-id: x9o1twq6 -->
<!-- timestamp: 2026-03-20T04:02:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral, Score: 6 (ADVANCED). Chronic issue across commit workflow, merge-to-main script, and end-session skill.

<!-- note-id: oo00hnyh -->
<!-- timestamp: 2026-03-20T04:09:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

INVESTIGATION COMPLETE. Convergence score: 2 (full agreement). Three root causes identified: (1) _phase_validate REMAINING_DIRTY is warn-only — never stages/cleans dirty files on main, (2) No untracked file detection in _phase_validate — only checks git diff, not git ls-files --others, (3) No final cleanliness gate before DONE — merge-to-main.sh declares success without verifying main is clean.
