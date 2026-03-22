---
id: w20-xqxq
status: open
deps: []
links: []
created: 2026-03-22T19:03:24Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Bug: merge-to-main.sh MAIN_REPO unbound variable in validate and ci_trigger phases when using --resume


## Description

When `merge-to-main.sh` is run with `--resume` (or `--phase=validate`), the validate phase at line 1124 and ci_trigger phase at line 1254 reference `MAIN_REPO` and `PRE_MERGE_SHA` variables that were never set because they are computed in the sync phase and not persisted to the state file.

**Steps to Reproduce:**
1. Run `merge-to-main.sh` — sync phase encounters a merge conflict
2. Resolve conflicts manually, commit
3. Write state file marking sync as completed
4. Run `merge-to-main.sh --resume` — merge phase succeeds
5. Validate phase crashes: `line 1124: MAIN_REPO: unbound variable`
6. Skip validate (via state file edit), push succeeds
7. CI trigger phase warns: `line 1254: PRE_MERGE_SHA: unbound variable`

**Root Cause**: `MAIN_REPO` is computed in `_phase_sync()` or the preamble before phase dispatch, but `--resume` skips completed phases without re-running their preamble. Variables computed in skipped phases are not persisted to the JSON state file.

**Expected**: Either persist `MAIN_REPO` and `PRE_MERGE_SHA` in the state file JSON, or re-compute them in each phase that uses them (e.g., `MAIN_REPO=$(git worktree list | grep -v 'worktree-' | head -1 | awk '{print $1}')`).

## File Impact

- `plugins/dso/scripts/merge-to-main.sh` (lines ~1124, ~1254)
