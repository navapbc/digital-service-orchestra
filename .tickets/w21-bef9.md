---
id: w21-bef9
status: in_progress
deps: []
links: []
created: 2026-03-22T03:07:48Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2r0x
---
# RED: Write failing tests for inbound STATUS event writing and relationship rejection persistence

## Description

Write failing unit tests for:
1. `write_status_event()` — bridge-authored STATUS event for Jira status changes (enables bidirectional flap detection)
2. Relationship rejection persistence — when Jira rejects a relationship, `jira_sync_status: rejected` is persisted locally and the local relationship is never removed

These tests are RED — they will fail until bridge-inbound.py implements these functions.

**Tests to write in tests/scripts/test_bridge_inbound.py:**

1. `test_write_status_event_creates_event_file` — call `write_status_event(ticket_id, status, ticket_dir, bridge_env_id)`; assert a `*-STATUS.json` file is created with correct fields including `env_id == bridge_env_id`
2. `test_write_status_event_has_correct_fields` — assert the STATUS event file contains: event_type="STATUS", data.status=<new_status>, env_id=bridge_env_id, timestamp (int), uuid (str)
3. `test_process_inbound_writes_status_event_for_mapped_status_change` — when a Jira issue has a mapped status different from local compiled state, assert a bridge-authored STATUS event file is written
4. `test_relationship_rejection_persistence_writes_rejected_status` — when Jira returns an error rejecting a relationship (e.g., epic-blocks-epic disallowed), assert the local ticket's `.jira-sync-status` file is written with `{"jira_sync_status": "rejected", "reason": "..."}` and the local relationship is preserved (not removed)
5. `test_relationship_rejection_persistence_local_relationship_never_removed` — verify that after a Jira relationship rejection, the local `links` field still contains the original relationship
6. `test_process_inbound_persists_rejection_on_acli_relationship_error` — simulate acli_client.set_relationship() raising an error; assert `jira_sync_status: rejected` is written locally

**TDD requirement:** All tests must FAIL (RED) before the implementation exists. Confirm red: `python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'write_status_event or rejection' --tb=line -q`

**File:** tests/scripts/test_bridge_inbound.py (add to existing file)

## Acceptance Criteria

- [ ] All 6 new tests exist in tests/scripts/test_bridge_inbound.py
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'write_status_event or rejection' --collect-only -q 2>&1 | grep -c 'test_' | awk '{exit ($1 < 6)}'
- [ ] All new tests FAIL (RED) before implementation
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'write_status_event or rejection' --tb=line -q 2>&1 | grep -qE 'FAILED|AttributeError|failed'
- [ ] All pre-existing bridge-inbound tests still pass
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py -k 'not (write_status_event or rejection)' --tb=short -q 2>&1 | grep -q 'passed'
- [ ] ruff format --check passes on the test file
  Verify: ruff format --check tests/scripts/test_bridge_inbound.py
- [ ] ruff check passes on the test file
  Verify: ruff check tests/scripts/test_bridge_inbound.py
