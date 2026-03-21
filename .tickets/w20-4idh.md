---
id: w20-4idh
status: open
deps: []
links: []
created: 2026-03-21T16:04:19Z
type: bug
priority: 1
assignee: Joe Oakhart
tags: [infrastructure, tmp-isolation]
---
# test-batched.sh state file not isolated by repo/worktree — causes cross-session interference

## Bug
test-batched.sh writes its state file to a fixed path (/tmp/test-batched-state.json) with no repo or worktree discrimination. When multiple sessions on the same computer work on different projects or worktrees, they collide on this shared state file, causing false 'already completed' skips and inability to resume.

## Observed Behavior
Running test-batched.sh in worktree-20260321-085404 after a prior interrupted run produces: 'Already completed: 1 tests / Skipping (already completed): bash_testsrun-allsh' — the state from the prior session blocks the new run from making progress.

## Expected Behavior
State file path should include repo name and worktree name, e.g. /tmp/test-batched-state-<repo>-<worktree>.json, so sessions are fully isolated.

## Scope
Search for similar patterns of non-isolated /tmp file usage across the codebase. Scripts that write to /tmp/<fixed-name> without repo/worktree qualification are all vulnerable to the same cross-session interference. Known patterns to check:
- /tmp/test-batched-state.json (this bug)
- /tmp/merge-to-main-state-*.json (may already be isolated by branch)
- /tmp/merge-to-main-lock-* (may already be isolated)
- /tmp/sprint-compact-intent-* (may already be isolated by epic ID)
- Any other /tmp writes in plugins/dso/scripts/

## File Impact
- plugins/dso/scripts/test-batched.sh (primary fix)
- tests/scripts/test-batched-state-integrity.sh (update tests)
- Potentially other scripts found during audit

