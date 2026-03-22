---
id: dso-yyll
status: open
deps: [dso-n0fo, dso-60uy, dso-zso6]
links: []
created: 2026-03-22T03:54:44Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Implement REVERT check-before-overwrite in bridge-outbound.py

Extend bridge-outbound.py's process_outbound() to handle REVERT events: fetch Jira state before pushing, emit BRIDGE_ALERT if Jira has diverged.

File to edit: plugins/dso/scripts/bridge-outbound.py

Implementation in process_outbound():
1. When a REVERT event is encountered in the events list:
   a. Determine the target event (by data.target_event_uuid) from the ticket's event history
   b. If target is a STATUS event:
      - Determine what status to revert TO (the status value before the bad STATUS event was applied)
      - Fetch current Jira state: acli_client.get_issue(jira_key) BEFORE pushing any update
      - If current Jira status != the expected pre-revert state (Jira has independently changed):
        * Call write_bridge_alert(ticket_dir, ticket_id, reason='REVERT check-before-overwrite: Jira state has diverged since bad action. Manual review required.', bridge_env_id=bridge_env_id)
        * Do NOT push the revert — emit the alert and skip this REVERT
      - If Jira state matches expected: push the revert (call update_issue to restore previous status)
   c. If target is a SYNC event: similar pattern — fetch Jira issue to verify state matches before any corrective push
   d. Write SYNC event after successful revert push (for audit trail)
2. REVERT events for COMMENT targets: document as 'orphaned Jira comment accepted as known post-REVERT state requiring manual cleanup' — emit BRIDGE_ALERT with reason='REVERT of COMMENT: Jira comment not removed (manual cleanup required)'

Per epic constraint: REVERT of REVERT is rejected at CLI — outbound processor need not handle that case (treat unknown REVERT-of-REVERT as no-op with warning).

TDD Requirement: Task dso-n0fo (RED tests) must be RED and dso-60uy (ticket-revert.sh) + dso-zso6 (reducer) must complete first. After this task, all test_bridge_outbound_revert tests must pass.

Run tests: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_revert.py -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] process_outbound() fetches Jira state before pushing REVERT effect
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_revert.py::test_process_outbound_revert_fetches_jira_state_before_push -v
- [ ] process_outbound() emits BRIDGE_ALERT when Jira has diverged since bad action
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_revert.py::test_process_outbound_revert_emits_bridge_alert_when_jira_diverged -v
- [ ] process_outbound() proceeds with REVERT push when Jira state matches expected
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_revert.py::test_process_outbound_revert_proceeds_when_jira_state_matches -v
- [ ] process_outbound() pushes previous status when reverting a bad STATUS event
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound_revert.py::test_process_outbound_revert_of_status_event_pushes_previous_status -v
- [ ] [Gap Analysis AC amendment] REVERT events are surfaced to process_outbound() — either parse_git_diff_events() is extended to detect REVERT event files (via glob '*-REVERT.json') in ticket dirs, OR process_outbound() scans ticket dirs directly for REVERT events. Either approach is acceptable, but the implementer must explicitly choose and document which approach is used. Test dso-n0fo test_process_outbound_revert_fetches_jira_state_before_push must use the same event delivery mechanism.
  Verify: grep -qE 'REVERT|revert' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py

