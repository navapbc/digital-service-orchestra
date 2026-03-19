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
# fix: plugin scripts resolve helper paths from main repo instead of worktree — tickets and tools invisible

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


## Notes

**2026-03-19T16:41:36Z**

## Scope Expansion

This is not limited to sprint-next-batch.sh. ALL plugin scripts that resolve helper paths (tk, issue-batch.sh, analyze-file-impact.py, read-config.sh, classify-task.py, etc.) should resolve from the worktree root first, then fall back to PATH. The pattern of hardcoding paths relative to the main repo breaks any script run from a worktree session.

Audit all scripts in plugins/dso/scripts/ for hardcoded path resolution that bypasses the worktree. Fix the resolution pattern once (e.g., a shared resolve_tool() helper) and apply consistently.

**2026-03-19T20:50:02Z**

Classification: behavioral, Score: 3 (INTERMEDIATE). Severity=1(medium), Complexity=2(complex—multiple scripts, worktree/plugin boundary), Environment=0(local).

**2026-03-19T21:07:21Z**

FIX APPLIED: Added validation guard to CLAUDE_PLUGIN_ROOT resolution in 17 hook files and 14 script files. Guard now checks directory structure exists (hooks/lib for hooks, plugin.json for scripts) — not just if variable is empty. Also fixed relative path violation in session-misc-functions.sh:645. All 10 failing tests now pass (0 regressions). Files: plugins/dso/hooks/dispatchers/*.sh, plugins/dso/hooks/run-hook.sh, plugins/dso/hooks/write-reviewer-findings.sh, plugins/dso/hooks/compute-diff-hash.sh, plugins/dso/hooks/lib/session-misc-functions.sh, plugins/dso/scripts/{13 scripts}.
