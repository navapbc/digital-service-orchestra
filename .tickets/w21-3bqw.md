---
id: w21-3bqw
status: in_progress
deps: []
links: []
created: 2026-03-21T22:11:04Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8cw2
---
# RED: Write failing tests for bridge-outbound event processor

## Description

Write failing tests in `tests/scripts/test_bridge_outbound.py` that specify bridge-outbound.py's behavior before it exists. Tests must fail (RED) because the module does not yet exist. Cover all five core behaviors: git diff event parsing, echo prevention, STATUS compiled-state extraction, bridge env filtering, idempotency.

TDD Requirement: This IS the RED test task. Named tests:
- `test_git_diff_parses_new_create_events` — given fixture git diff output with a CREATE event, asserts parsed event list contains the CREATE event with correct fields
- `test_echo_prevention_skips_ticket_with_existing_sync` — given a ticket directory with an existing SYNC event file, asserts the bridge does NOT call create_issue for that ticket
- `test_status_event_uses_compiled_state_not_raw` — given a ticket with two conflicting STATUS events from different envs, asserts the bridge calls update_issue with the post-conflict-resolution compiled state (not the raw last STATUS event)
- `test_bridge_env_filter_skips_bridge_originated_events` — given events with env_id matching the bridge env ID, asserts they are filtered out and create_issue/update_issue is not called
- `test_idempotent_no_duplicate_sync_write` — given a run where create_issue succeeds but a SYNC file already exists, asserts no second SYNC file is written

Note: Tests import bridge-outbound (which doesn't exist yet) causing ImportError — this is the correct RED failure mode. The mock acli_client interface is defined by the SYNC contract (w21-5mr1) and the function signatures from w21-hbjx.

## ACCEPTANCE CRITERIA

- [ ] `tests/scripts/test_bridge_outbound.py` exists with at least 5 test functions
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound.py && grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound.py | awk '{exit ($1 < 5)}'
- [ ] Running tests returns non-zero exit (RED — module does not yet exist)
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound.py 2>&1; test $? -ne 0
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound.py
- [ ] Mock acli_client uses correct interface: create_issue(ticket_data), update_issue(jira_key, ticket_data), get_issue(jira_key) — matching signatures from w21-hbjx
  Verify: grep -q 'create_issue' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound.py && grep -q 'update_issue' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_outbound.py

## Notes

**2026-03-21T22:19:26Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T22:20:26Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T22:21:41Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T22:21:53Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T22:22:28Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T22:22:51Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T22:56:03Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/scripts/test_bridge_outbound.py. Tests: RED state (5 errors, correct).
