---
id: w22-r5fx
status: open
deps: [w21-ykic]
links: []
created: 2026-03-22T06:54:59Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# validate.sh test-batched interaction causes stale interrupted state across sessions


## Notes

**2026-03-22T06:55:12Z**

## Context

When validate.sh runs tests via test-batched.sh and the test suite is killed (exit 144 / SIGURG) due to Claude Code's ~73s tool timeout ceiling, the test-session-state.json file records the run as 'interrupted'. On subsequent sessions in the same worktree, validate.sh finds this stale state file and reports 'Resuming from state file' — then skips all tests because the single entry is marked as already completed (interrupted). The --reset flag does not exist on validate.sh.

## Expected Behavior
validate.sh should either: (a) detect stale interrupted state and re-run, or (b) support a --reset flag to clear prior state.

## Reproduction
1. Start a worktree session
2. Run validate.sh --ci (it triggers test-batched.sh internally)
3. Kill the process mid-run (SIGURG/exit 144)
4. Start a new session in the same worktree
5. Run validate.sh --ci — observe it reports 'tests: FAIL' without actually running any tests

## File Impact
- plugins/dso/scripts/validate.sh — stale state detection logic
- plugins/dso/scripts/test-batched.sh — state file lifecycle management
