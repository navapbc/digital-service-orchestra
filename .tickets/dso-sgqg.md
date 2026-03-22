---
id: dso-sgqg
status: closed
deps: []
links: []
created: 2026-03-22T00:59:53Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dww7
---
# RED: Write failing round-trip comment dedup test

Write a failing integration test that verifies a comment pushed outbound and pulled inbound is NOT re-imported as a duplicate local event.

## Test file

`tests/scripts/test_bridge_comment_roundtrip.py`

## Test to write (must fail RED before implementation)

### `test_comment_round_trip_no_duplication`

**Scenario**: 
1. A local COMMENT event exists for ticket 'w21-rt1' (ticket has a SYNC mapping to 'DSO-42')
2. Outbound bridge runs: calls `add_comment('DSO-42', body_with_marker)`, dedup map updated with `uuid_to_jira_id[event_uuid] = 'j-100'` and `jira_id_to_uuid['j-100'] = event_uuid`
3. Inbound bridge runs: `get_comments('DSO-42')` returns `[{id: 'j-100', body: body_with_marker}]`
4. `pull_comments` must NOT write a new local COMMENT event (dedup by jira_id 'j-100')

**Assert**: After both outbound and inbound runs, the ticket directory still contains exactly 1 COMMENT event file (the original one, not a new bridge-imported one).

### `test_comment_round_trip_stripped_marker_no_duplication`

**Scenario**: Same as above, but `get_comments` returns `[{id: 'j-100', body: body_WITHOUT_marker}]` (editor stripped the marker)
**Assert**: Inbound still skips the comment (dedup by jira_id 'j-100', primary key survives stripping).

## TDD requirement

Write both tests FIRST. Tests will fail because bridge-inbound.py does not yet exist. Do NOT implement until RED is verified.

## Helper design

Each test sets up a tmp_path with: ticket directory, SYNC event (mapping to DSO-42), COMMENT event, dedup map (pre-populated as if outbound ran successfully). Then calls `pull_comments` directly with a mock acli_client returning the Jira comment. Asserts no new COMMENT files created.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file `tests/scripts/test_bridge_comment_roundtrip.py` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_comment_roundtrip.py
- [ ] Test file contains both round-trip test functions
  Verify: cd $(git rev-parse --show-toplevel) && grep -c 'def test_comment_round_trip' tests/scripts/test_bridge_comment_roundtrip.py | awk '{exit ($1 < 2)}'
- [ ] Both round-trip tests FAIL (RED) before implementation — non-zero exit
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_comment_roundtrip.py 2>&1; test $? -ne 0

## Notes

**2026-03-22T01:21:20Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T01:21:43Z**

CHECKPOINT 2/6: Read dedup contract, bridge-outbound.py, and test conventions ✓

**2026-03-22T01:22:40Z**

CHECKPOINT 3/6: RED tests written at tests/scripts/test_bridge_comment_roundtrip.py ✓

**2026-03-22T01:24:41Z**

CHECKPOINT 6/6: Done ✓ — RED tests written, both fail for right reason (bridge-inbound.py not found), ruff check/format pass, run-all.sh exit 0
