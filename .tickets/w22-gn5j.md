---
id: w22-gn5j
status: closed
deps: []
links: []
created: 2026-03-22T07:05:42Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-9ltc
---
# Capture schema compliance baseline (Done Definition 10)

Capture a directional schema compliance baseline by running the existing review pipeline against 3 representative diffs and recording first-attempt schema validation pass/fail from write-reviewer-findings.sh. Store the baseline in the epic notes for comparison after w21-jtkr integrates the generated agents.

Steps:
1. Select 3 recent diffs from git log (choose varied sizes/types: small, medium, large)
2. For each diff, run the existing review pipeline (REVIEW-WORKFLOW.md, using the current code-review-dispatch.md prompt via general-purpose agent) 
3. Record: diff identifier, diff size, whether write-reviewer-findings.sh succeeded on first attempt, any schema validation errors seen
4. Add to epic w21-ykic notes via: tk add-note w21-ykic '...' with the baseline results table

Expected output format for epic notes:
  Schema Compliance Baseline (pre-tiered-agents):
  | Diff | Size | First-attempt pass | Notes |
  |------|------|-------------------|-------|
  | <sha1> | <N lines> | yes/no | <any schema errors> |
  | <sha2> | <N lines> | yes/no | <any schema errors> |
  | <sha3> | <N lines> | yes/no | <any schema errors> |

test-exempt: This task captures empirical data by running the review pipeline; there is no implementation artifact with conditional logic to test. The done definition is the presence of the baseline record in the epic notes, which is a documentation outcome not a code behavior.

This task can run concurrently with other tasks (no code dependencies). It should run after the existing test suite is confirmed passing.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Epic w21-ykic notes contain Schema Compliance Baseline table with 3 entries
  Verify: tk show w21-ykic | grep -q 'Schema Compliance Baseline'

## Notes

<!-- note-id: 11hlu37i -->
<!-- timestamp: 2026-03-22T13:09:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: knht0dmy -->
<!-- timestamp: 2026-03-22T13:10:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: g5an4y4u -->
<!-- timestamp: 2026-03-22T13:11:49Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: n4iyy54q -->
<!-- timestamp: 2026-03-22T13:12:03Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: webslfot -->
<!-- timestamp: 2026-03-22T13:12:13Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: 9xmpmn0n -->
<!-- timestamp: 2026-03-22T13:12:33Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
