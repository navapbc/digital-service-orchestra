---
id: dso-cc6a
status: open
deps: []
links: []
created: 2026-03-20T17:13:11Z
type: bug
priority: 3
assignee: Joe Oakhart
parent: dso-9xnr
---
# Worktree auto-cleanup fails when session ends with unmerged commits

## Bug Description

After a claude-safe session ends, the worktree auto-cleanup (`_offer_worktree_cleanup`) correctly detects unmerged commits and refuses to remove the worktree, but the root cause is that the session ended without completing the merge-to-main step.

## Observed Behavior

claude-safe log after session exit:

```
Worktree 'worktree-20260319-205936' cannot be auto-removed:

  Branch 'worktree-20260319-205936' has unmerged commits:
    bdffe9e chore: auto-commit ticket changes before merge
    9978ea3 feat: brainstorm and plan three epics — test gate, reviewer calibration, setup onboarding
    6e2dc40 feat(dso-ppwp): brainstorm and preplan test gate enforcement epic

Run 'worktree-cleanup.sh' from the main repo to manage worktrees.
```

## Expected Behavior

`/dso:end` should ensure merge-to-main completes before session close, or if merge fails/is skipped, clearly surface the unmerged state to the user during the session (not after exit).

## Analysis

The `_offer_worktree_cleanup` guard is working correctly — it checks `is_merged` and `is_clean` before removing. The issue is upstream: the session ended with commits that were never merged to main. Possible causes:

1. `/dso:end` was not invoked before session exit
2. `/dso:end` was invoked but merge-to-main failed silently
3. The user exited the session before `/dso:end` could complete

## Reproduction

1. Start a worktree session
2. Make commits
3. Exit without running `/dso:end` or without completing merge-to-main
4. Observe worktree left behind

## Impact

Orphaned worktrees accumulate on disk and require manual cleanup via `worktree-cleanup.sh`.
