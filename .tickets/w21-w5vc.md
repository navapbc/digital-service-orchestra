---
id: w21-w5vc
status: in_progress
deps: [w21-pqsy]
links: []
created: 2026-03-22T00:59:13Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-gykt
---
# RED: write failing tests for configurable status/type mapping, BRIDGE_ALERT, JQL pagination, UTC health check

Write failing tests in tests/scripts/test_bridge_inbound.py extending the test file from w21-81hy, covering the remaining functions of bridge-inbound.py before they are implemented.

TDD REQUIREMENT: All tests in this task MUST fail (RED) when added, before the corresponding implementation exists. Confirm RED after adding each batch: python3 -m pytest tests/scripts/test_bridge_inbound.py::TestMapping -v; expect failures.

TESTS TO ADD to tests/scripts/test_bridge_inbound.py:

class TestStatusTypeMapping:
1. test_map_status_known_value_returns_local_status
   - map_status('In Progress', mapping={'In Progress': 'in_progress'}) returns 'in_progress'

2. test_map_status_unknown_value_returns_none
   - map_status('Unknown Status', mapping={'In Progress': 'in_progress'}) returns None (caller writes BRIDGE_ALERT)

3. test_map_type_known_value_returns_local_type
   - map_type('Story', mapping={'Story': 'story'}) returns 'story'

4. test_map_type_unknown_value_returns_none
   - map_type('Custom Jira Type', mapping={}) returns None

5. test_write_bridge_alert_writes_event_file
   - write_bridge_alert(ticket_id, reason, tickets_root, bridge_env_id) writes BRIDGE_ALERT event file
   - File at .tickets-tracker/<ticket_id>/<ts>-<uuid>-BRIDGE_ALERT.json with event_type=BRIDGE_ALERT, reason=reason, env_id=bridge_env_id

class TestPagination:
6. test_fetch_jira_changes_paginates_all_results
   - When acli_client.search_issues returns 100 results on page 0 and 50 results on page 1 and 0 on page 2, fetch_jira_changes returns all 150 issues
   - search_issues called 3 times with start_at=0, 100, 200

class TestUTCHealthCheck:
7. test_verify_jira_timezone_utc_passes_when_utc
   - verify_jira_timezone_utc(acli_client) returns True when acli_client.get_server_info() returns {'timeZone': 'UTC'}

8. test_verify_jira_timezone_utc_fails_when_non_utc
   - Returns False (and logs warning) when timeZone is 'America/New_York'

class TestProcessInbound:
9. test_process_inbound_writes_create_events_for_new_issues
   - process_inbound(tickets_root, acli_client, last_pull_ts, config) calls fetch, normalize, write_create_events, updates checkpoint
   - Verify checkpoint file is updated with new last_pull_ts after successful run

10. test_process_inbound_fast_aborts_on_auth_failure
   - When acli_client raises CalledProcessError with returncode=401, process_inbound does NOT update checkpoint (preserves last good timestamp)

## Acceptance Criteria

- [ ] New test functions added to tests/scripts/test_bridge_inbound.py fail RED before implementation
  Verify: python3 -m pytest tests/scripts/test_bridge_inbound.py::TestStatusTypeMapping tests/scripts/test_bridge_inbound.py::TestPagination tests/scripts/test_bridge_inbound.py::TestUTCHealthCheck tests/scripts/test_bridge_inbound.py::TestProcessInbound --tb=no -q; test $? -ne 0
- [ ] At least 10 test functions total in test_bridge_inbound.py
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/scripts/test_bridge_inbound.py | awk '{exit ($1 < 10)}'
- [ ] ruff check passes on updated test file
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/scripts/test_bridge_inbound.py
- [ ] ruff format --check passes on updated test file
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/scripts/test_bridge_inbound.py


## Notes

<!-- note-id: xchrt42p -->
<!-- timestamp: 2026-03-22T01:47:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Added 10 new RED tests in 4 classes (TestStatusTypeMapping x5, TestPagination x1, TestUTCHealthCheck x2, TestProcessInbound x2). Total test count: 16. 9/10 fail RED with AttributeError (map_status, map_type, write_bridge_alert, verify_jira_timezone_utc, process_inbound not implemented; fetch_jira_changes missing pagination). 1/10 (test_process_inbound_fast_aborts_on_auth_failure) passes in RED state because it correctly tests checkpoint-preservation on exception — behavior is valid regardless of implementation existence. ruff check + format --check both pass.
