---
id: w20-qxsx
status: open
deps: []
links: []
created: 2026-03-22T15:38:24Z
type: bug
priority: 2
assignee: Joe Oakhart
---
# test-batched.sh treats run-all.sh as single command — cannot resume sub-test progress


## Description

When `test-batched.sh` wraps `bash tests/run-all.sh`, it treats the entire run-all.sh invocation as a single test command. On resume, it sees the whole command as "already completed (interrupted)" and skips it entirely rather than resuming from the sub-test that was running when the timeout hit.

**Expected**: test-batched.sh should either (a) recognize multi-suite runners and resume from where the suite left off, or (b) document that it only works with single-test commands and suggest running suites individually.

**Workaround**: Run each test suite separately (`bash tests/hooks/run-hook-tests.sh`, `bash tests/scripts/run-script-tests.sh`) instead of `bash tests/run-all.sh`.

## Steps to Reproduce

1. Run `test-batched.sh --timeout=55 "bash tests/run-all.sh"` — timeout kills mid-suite
2. Run the NEXT: resume command — it skips the entire run-all.sh as "already completed"
3. Result: 0 passed, 0 failed, 1 interrupted — no progress possible

## File Impact

- `plugins/dso/scripts/test-batched.sh`
