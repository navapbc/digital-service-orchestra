---
id: w21-prlu
status: open
deps: []
links: []
created: 2026-03-19T16:41:11Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# fix: sprint-next-batch.sh resolves tk path from main repo instead of worktree — tickets invisible

## Problem

sprint-next-batch.sh hardcodes TK path as $REPO_ROOT/scripts/tk where REPO_ROOT is the worktree, but then falls back to the main repo path when the script isn't found there. When tickets are created in a worktree session (via tk create which uses the PATH-resolved tk), the ticket .md files exist in the worktree's .tickets/ directory. But sprint-next-batch.sh's tk resolves to the main repo's tk, which reads .tickets/ from the main repo — where the new tickets don't exist yet (not merged).

This caused sprint-next-batch.sh to return 'Error: Could not load epic dso-tmmj' during the dso-tmmj sprint, requiring manual batch composition for the entire session.

## Root Cause

Line ~35 of sprint-next-batch.sh:
```bash
TK=/Users/joeoakhart/digital-service-orchestra/scripts/tk
```

This resolves to the main repo's scripts directory, not the worktree's. The tk script then reads .tickets/ relative to its own location (main repo), missing worktree-only tickets.

## Expected Behavior

sprint-next-batch.sh should resolve tk from the worktree (REPO_ROOT), not the main repo. If scripts/tk doesn't exist in the worktree, fall back to the PATH-resolved tk (which is what all other commands use successfully).

## Acceptance Criteria

- sprint-next-batch.sh resolves tk from the worktree root first, then falls back to PATH
- When run from a worktree, sprint-next-batch.sh can see tickets that exist only in the worktree
- Existing behavior when run from the main repo is unchanged

