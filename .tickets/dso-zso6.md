---
id: dso-zso6
status: open
deps: [dso-60uy, dso-ed01, dso-za4o]
links: []
created: 2026-03-22T03:53:58Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Implement REVERT event handling in ticket-reducer.py: record reverts in compiled state

Extend ticket-reducer.py to handle REVERT events and surface them in the compiled state.

File to edit: plugins/dso/scripts/ticket-reducer.py

Implementation:
1. In reduce_ticket(), initialize 'reverts': [] in the initial state dict
2. Add handling for event_type == 'REVERT':
   - Append to state['reverts']:
     { 'uuid': event_uuid, 'target_event_uuid': data.get('target_event_uuid'), 'target_event_type': data.get('target_event_type'), 'reason': data.get('reason', ''), 'timestamp': event.get('timestamp'), 'author': event.get('author') }
   - REVERT does NOT automatically undo the target event's effect in compiled state (undo is bridge-outbound's responsibility for STATUS/SYNC effects; reducer only records the intent)
3. 'reverts' key must appear in compiled state even when empty ([])

Per contract (dso-4uys): REVERT events target non-REVERT events only (enforcement at CLI level, not reducer level — reducer silently records any REVERT event).

TDD Requirement: Task dso-ed01 (RED tests) must be RED and dso-60uy (ticket-revert.sh) must complete before this task. After this task, test_reducer_records_reverts_in_compiled_state and test_reducer_revert_does_not_undo_status_automatically must pass.

Run tests: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py::test_reducer_records_reverts_in_compiled_state tests/scripts/test_revert_event.py::test_reducer_revert_does_not_undo_status_automatically -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] reduce_ticket() returns state with 'reverts' key (list) even when no REVERTs present
  Verify: cd $(git rev-parse --show-toplevel) && python3 -c "import sys; import importlib.util; spec = importlib.util.spec_from_file_location('r', 'plugins/dso/scripts/ticket-reducer.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); print('reverts key expected in initial state')"
- [ ] reduce_ticket() records REVERT events in 'reverts' list with correct fields
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py::test_reducer_records_reverts_in_compiled_state -v
- [ ] reduce_ticket() does NOT auto-undo the target event's effect (status unchanged by REVERT)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_revert_event.py::test_reducer_revert_does_not_undo_status_automatically -v

