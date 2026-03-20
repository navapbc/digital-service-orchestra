---
id: dso-rjlt
status: closed
deps: []
links: []
created: 2026-03-20T04:19:25Z
type: task
priority: 2
assignee: Joe Oakhart
---
# Dirty .tickets files on main/worktree after merge — root cause of unclean state


## Notes

<!-- note-id: gpo5ree8 -->
<!-- timestamp: 2026-03-20T04:19:32Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Classification: behavioral, Score: 5 (INTERMEDIATE). Prior fix attempt: dso-z6zi (f94c36e) upgraded REMAINING_DIRTY from WARNING to ERROR but did not address source of dirty files. User reports .tickets files are a key source.

<!-- note-id: 70lv3p7h -->
<!-- timestamp: 2026-03-20T04:21:46Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

ROOT CAUSE: merge-to-main.sh worktree pre-flight excludes .tickets/ from dirty checks (lines 661-663), allowing merge to proceed with uncommitted .tickets files. These files survive the merge untouched because the script operates on main, not the worktree. Post-merge checks (end-session Step 4.75, claude-safe cleanup) do NOT exclude .tickets, so the worktree appears dirty. FIX: auto-commit dirty .tickets files on the worktree before starting the merge phases.
