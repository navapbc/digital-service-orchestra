---
id: dso-za4o
status: open
deps: [dso-qwrw]
links: []
created: 2026-03-22T03:52:08Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Implement BRIDGE_ALERT detection in ticket-reducer.py: add bridge_alerts to compiled state

Extend ticket-reducer.py to detect BRIDGE_ALERT events and surface them in the compiled ticket state.

File to edit: plugins/dso/scripts/ticket-reducer.py

Implementation:
1. In reduce_ticket(), add handling for event_type == 'BRIDGE_ALERT':
   - Initialize 'bridge_alerts': [] in the initial state dict
   - When processing a BRIDGE_ALERT event: append to state['bridge_alerts'] with:
     { 'uuid': event_uuid, 'reason': event.get('data', {}).get('reason', ''), 'timestamp': event.get('timestamp'), 'resolved': False }
   - When processing a BRIDGE_ALERT with data.resolved == True: find the referenced alert by data.alert_uuid and mark resolved=True, or remove it from unresolved list (per contract)
   - BRIDGE_ALERT events do NOT affect ticket status or other state fields
2. The 'bridge_alerts' key must appear in the compiled state even when empty ([] not absent)

Canonical BRIDGE_ALERT event format (per dso-qwrw contract):
  { event_type: 'BRIDGE_ALERT', timestamp: int, uuid: str, env_id: str, ticket_id: str, data: { reason: str, resolved?: bool, alert_uuid?: str } }

Note: The two existing write_bridge_alert() implementations have slightly different field structures. Normalize parsing to read data.reason (outbound format) as primary and fallback to top-level reason (inbound format) for backward compat.

TDD Requirement: Task dso-7n6c must be RED before this task runs. After this task, test_reducer_detects_unresolved_bridge_alert and test_reducer_no_alerts_when_none_present must be GREEN.

Run tests: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py::test_reducer_detects_unresolved_bridge_alert tests/scripts/test_bridge_alert_display.py::test_reducer_no_alerts_when_none_present -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] reduce_ticket() returns state with 'bridge_alerts' key (list) even when no alerts present
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py::test_reducer_no_alerts_when_none_present -v
- [ ] reduce_ticket() returns unresolved BRIDGE_ALERT entries with correct fields (reason, timestamp, uuid, resolved=False)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py::test_reducer_detects_unresolved_bridge_alert -v
- [ ] reduce_ticket() marks alerts as resolved when resolution event references alert UUID
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_alert_display.py::test_reducer_alert_resolved_by_resolution_event -v
- [ ] BRIDGE_ALERT handling does not affect ticket status or other state fields
  Verify: python3 -c "import sys; sys.path.insert(0, '$(git rev-parse --show-toplevel)/plugins/dso/scripts'); import importlib.util; spec = importlib.util.spec_from_file_location('r', '$(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-reducer.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); print('ok')"

