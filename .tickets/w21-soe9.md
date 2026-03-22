---
id: w21-soe9
status: in_progress
deps: []
links: []
created: 2026-03-22T03:06:59Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-2r0x
---
# RED: Write failing tests for flap detection in bridge-outbound.py

## Description

Write failing unit tests for the flap detection feature to be added to bridge-outbound.py.

These tests are RED — they will fail until bridge-outbound.py implements `detect_status_flap()`.

**Tests to write in tests/scripts/test_bridge_outbound.py:**

1. `test_detect_status_flap_returns_false_below_threshold` — create a ticket dir with 2 STATUS events alternating between 'open' and 'in_progress'; assert `detect_status_flap()` returns False (threshold default N=3 oscillations not reached)
2. `test_detect_status_flap_returns_true_at_threshold` — create a ticket dir with 3+ STATUS events alternating between two statuses; assert `detect_status_flap()` returns True
3. `test_detect_status_flap_ignores_monotonic_progression` — create STATUS events: open→in_progress→closed (no oscillation); assert `detect_status_flap()` returns False
4. `test_detect_status_flap_counts_only_within_window` — create STATUS events older than the window mixed with recent ones; assert only recent events count toward threshold
5. `test_process_outbound_emits_bridge_alert_on_flap` — when `detect_status_flap()` returns True for a ticket's STATUS event, assert BRIDGE_ALERT event file is written and STATUS push is skipped (acli_client.update_issue not called for that ticket)
6. `test_process_outbound_halts_status_push_for_flapping_ticket` — verify that after a flap is detected, the ticket's STATUS event is not pushed to Jira

**TDD requirement:** All tests must FAIL (RED) before `detect_status_flap()` exists in bridge-outbound.py. Confirm red: `python3 -m pytest tests/scripts/test_bridge_outbound.py -k 'flap' --tb=line -q`

**File:** tests/scripts/test_bridge_outbound.py (add to existing file)

## Acceptance Criteria

- [ ] All 6 new flap detection tests exist in tests/scripts/test_bridge_outbound.py
  Verify: python3 -m pytest tests/scripts/test_bridge_outbound.py -k 'flap' --collect-only -q 2>&1 | grep -c 'test_detect_status_flap\|flap' | awk '{exit ($1 < 6)}'
- [ ] All new tests FAIL (RED) before implementation — confirmed by running and seeing FAILED/AttributeError
  Verify: python3 -m pytest tests/scripts/test_bridge_outbound.py -k 'flap' --tb=line -q 2>&1 | grep -qE 'FAILED|AttributeError|failed'
- [ ] All pre-existing bridge-outbound tests still pass
  Verify: python3 -m pytest tests/scripts/test_bridge_outbound.py -k 'not flap' --tb=short -q 2>&1 | grep -q 'passed'
- [ ] ruff format --check passes on the test file
  Verify: ruff format --check tests/scripts/test_bridge_outbound.py
- [ ] ruff check passes on the test file
  Verify: ruff check tests/scripts/test_bridge_outbound.py
