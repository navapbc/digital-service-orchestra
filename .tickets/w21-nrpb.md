---
id: w21-nrpb
status: open
deps: []
links: []
created: 2026-03-22T06:51:36Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# Bug: merge-to-main.sh test gate blocks after auto-resolve of .tickets/.index.json conflict


## Notes

**2026-03-22T06:51:47Z**

## Description
When merge-to-main.sh auto-resolves a .tickets/.index.json conflict (via the merge driver or fallback), the resulting commit is blocked by the pre-commit test gate. The test gate sees a diff hash mismatch because record-test-status.sh was run before the merge introduced new files from main.

## Steps to Reproduce
1. Have uncommitted ticket changes on the worktree branch
2. Main has divergent ticket changes (especially .tickets/.index.json)
3. Run merge-to-main.sh
4. The script auto-resolves .index.json conflict but then git commit fails with: BLOCKED: test gate — code changed since tests were recorded

## Root Cause
merge-to-main.sh does not re-run record-test-status.sh after auto-resolving conflicts. The diff hash changes when merge introduces new files from main, but the test-gate-status still has the pre-merge hash.

## Expected Behavior
After auto-resolve, merge-to-main.sh should re-run record-test-status.sh before attempting the merge commit.

## Workaround
Manually resolve the merge: git merge origin/main --no-commit, resolve conflicts, run record-test-status.sh, then commit.

**2026-03-22T19:03:47Z**

Additional data from w22-anm2 sprint session (2026-03-22): merge-to-main.sh sync phase re-runs even after conflicts were manually resolved and committed, because it re-fetches and re-merges main. The state file does not record that sync completed after manual conflict resolution. Workaround: manually write the state file with sync marked as completed, then --resume. Related: created w20-xqxq for MAIN_REPO unbound variable in validate/ci_trigger phases during --resume.
