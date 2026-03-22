---
id: dso-d3gr
status: open
deps: []
links: []
created: 2026-03-22T02:39:23Z
type: epic
priority: 1
assignee: Joe Oakhart
---
# RED Test Gate Tolerance


## Notes

<!-- note-id: v9yoczzh -->
<!-- timestamp: 2026-03-22T02:39:34Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Context
DSO enforces TDD discipline where agents write failing (RED) tests before implementing the code they describe. The pre-commit test gate blocks commits when associated tests fail, which creates a conflict: when an agent modifies a source file, the gate discovers its associated test file via fuzzy match and runs ALL tests — including RED tests for functions not yet implemented. Those RED tests fail, blocking the commit even though the agent's changes are unrelated to those tests. This was observed blocking sprint batches 7-9 in the w21-bwfw epic. The current workaround (stashing RED test changes before committing) is fragile and error-prone.

## Success Criteria
- An agent can commit a source file change when the associated test file contains RED tests, without being blocked by the test gate or CI
- GREEN tests (defined before the RED marker in the test file) still block commits when they fail — regression protection is preserved
- The RED marker is specified in .test-index as the name of the first RED test function, paired with a convention that RED tests are appended at the end of the test file
- Epic closure is blocked until all RED markers are removed from .test-index, ensuring all tests pass before work is considered done
- The pre-commit test gate (pre-commit-test-gate.sh) requires zero changes — all RED logic is handled in record-test-status.sh before the gate runs
- The approach works for both Python (pytest) and bash test files without framework-specific markers in the test code itself

## Dependencies
None

## Approach
Extend .test-index with an optional [first_red_test_name] marker on test file entries. record-test-status.sh checks the index for RED markers; when a RED-flagged test file fails, it greps the file for the marker's line number and each failing test's line number. Failures at or after the marker are tolerated (warned but non-blocking); failures before the marker still block. The pre-commit hook sees "passed" in the status file and requires no changes. RED markers must be removed before epic closure.

<!-- note-id: cwviukvk -->
<!-- timestamp: 2026-03-22T02:41:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Context (revised)
DSO agents follow TDD discipline: they write failing (RED) tests before implementing the code those tests describe. The pre-commit test gate — which protects against committing broken code — blocks commits when associated tests fail. This creates a direct conflict with TDD: when an agent modifies a source file, the gate fuzzy-matches the associated test file and runs ALL tests in it, including RED tests for functions not yet implemented. Those RED tests fail, blocking the commit even though the agent's changes are unrelated. During the w21-bwfw epic, this blocked sprint batches 7-9, forcing agents to use a fragile stash-commit-pop workaround that risks lost work. Every TDD sprint with multi-function source files hits this friction.

## Success Criteria (revised)
- An agent can commit a source file change when the associated test file contains RED tests, without being blocked by the test gate or CI
- GREEN tests (defined before the RED marker in the test file) still block commits when they fail — regression protection is preserved
- The RED marker is specified in .test-index as the name of the first RED test function, paired with a convention that RED tests are appended at the end of the test file
- Epic closure is blocked until all RED markers are removed from .test-index, ensuring all tests pass before work is considered done
- The pre-commit test gate (pre-commit-test-gate.sh) requires zero changes — all RED logic is handled in record-test-status.sh before the gate runs
- The approach works for both Python (pytest) and bash test files without framework-specific markers in the test code itself
- Validation: after delivery, run a sprint batch that includes RED tests in a shared test file — the batch completes without test-gate blocks or stash workarounds, and GREEN test regressions in the same file are still caught

## Dependencies
None (builds on existing .test-index infrastructure and pre-commit test gate, both already stable)
