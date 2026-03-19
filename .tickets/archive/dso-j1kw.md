---
id: dso-j1kw
status: closed
deps: []
links: []
created: 2026-03-18T17:29:31Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-5lb8
---
# Remove checkpoint marker cleanup from scripts/health-check.sh

Remove all checkpoint sentinel handling from scripts/health-check.sh.

## What to change

1. Remove the `# ── Scan: checkpoint markers ──────────────────────────────────────────────────` comment block and the `for marker in ".checkpoint-pending-rollback" ".checkpoint-needs-review"; do ... done` loop (approximately 15 lines).
2. Update the header comments at the top of the file:
   - Remove the line: `#   - Removes .checkpoint-pending-rollback and .checkpoint-needs-review if present` from the `--fix mode repairs:` list
   - Remove the two lines: `#   $REPO_ROOT/.checkpoint-pending-rollback` and `#   $REPO_ROOT/.checkpoint-needs-review` from the `# State files scanned:` list

## TDD Requirement

Write a failing test FIRST:
- Assert the checkpoint marker for loop is NOT present: `grep -c 'checkpoint-pending-rollback' scripts/health-check.sh` returns 0
- Assert the checkpoint marker for loop is NOT present: `grep -c 'checkpoint-needs-review' scripts/health-check.sh` returns 0

Confirm the test fails (RED). Then make the deletions. Confirm the test passes (GREEN).

## Known Test Impact

`tests/scripts/test-health-check.sh` currently has two test cases that reference checkpoint markers:
  - "--fix clears checkpoint markers" (creates .checkpoint-pending-rollback and .checkpoint-needs-review, runs --fix, asserts removal)
  - "checkpoint markers reported" (creates .checkpoint-pending-rollback, asserts it appears in JSON output)

After this task, those test cases will fail because health-check.sh no longer scans for or removes those files. This is expected — the test file update is scoped to sibling story dso-jneo. Do NOT update the test file in this task.

## Files

- `scripts/health-check.sh` — Edit (deletions only)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes for all test suites EXCEPT test-health-check.sh (which will fail until dso-jneo lands)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh 2>&1 | grep -v "test-health-check" | grep -c "FAIL" | awk '{exit ($1 > 0)}'
- [ ] `checkpoint-pending-rollback` does not appear in scripts/health-check.sh
  Verify: ! grep -q 'checkpoint-pending-rollback' $(git rev-parse --show-toplevel)/scripts/health-check.sh
- [ ] `checkpoint-needs-review` does not appear in scripts/health-check.sh
  Verify: ! grep -q 'checkpoint-needs-review' $(git rev-parse --show-toplevel)/scripts/health-check.sh
- [ ] The checkpoint marker scan loop (`for marker in`) is absent from scripts/health-check.sh
  Verify: ! grep -q 'for marker in.*checkpoint' $(git rev-parse --show-toplevel)/scripts/health-check.sh
- [ ] health-check.sh header comments no longer reference checkpoint sentinel files
  Verify: ! grep -q 'checkpoint' $(git rev-parse --show-toplevel)/scripts/health-check.sh
