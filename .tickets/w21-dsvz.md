---
id: w21-dsvz
status: open
deps: [w21-3bqw, w21-hbjx]
links: []
created: 2026-03-21T22:11:04Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8cw2
---
# Implement bridge-outbound.py event processor

## Description

Create `plugins/dso/scripts/bridge-outbound.py`.

Main entry point: `process_events(tickets_dir, acli_client=None, git_diff_output=None, bridge_env_id=None)`.

Injectable `acli_client` defaults to importlib-loaded acli-integration module. Injectable `git_diff_output` (for testing) defaults to subprocess call to `git diff HEAD~1 HEAD -- .tickets/`.

Logic:
1. Parse git diff to find new/modified ticket event files
2. For each ticket: check if SYNC event exists in ticket dir (echo prevention / idempotency)
3. For CREATE events: call acli_client.create_issue, write SYNC event after verified creation
4. For STATUS events: call ticket-reducer.py to get compiled state, call acli_client.update_issue with compiled status
5. Filter out events where env_id matches bridge_env_id
6. Write SYNC events following existing timestamp-based filename convention

No new dependencies — uses importlib, json, os, pathlib, subprocess.

TDD Requirement: Task w21-3bqw's tests (`test_git_diff_parses_new_create_events`, `test_echo_prevention_skips_ticket_with_existing_sync`, `test_status_event_uses_compiled_state_not_raw`, `test_bridge_env_filter_skips_bridge_originated_events`, `test_idempotent_no_duplicate_sync_write`) must pass GREEN after this task.

## ACCEPTANCE CRITERIA

- [ ] `plugins/dso/scripts/bridge-outbound.py` exists and `process_events` function is importable
  Verify: python3 -c 'import importlib.util, pathlib; spec = importlib.util.spec_from_file_location("bridge_outbound", pathlib.Path("$(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py")); mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod); assert hasattr(mod, "process_events")'
- [ ] All 5 RED tests from w21-3bqw pass (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound.py -q --tb=short
- [ ] Echo prevention: bridge skips tickets with existing SYNC events
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound.py::test_echo_prevention_skips_ticket_with_existing_sync -q
- [ ] STATUS events use compiled state: post-conflict-resolution state sent to Jira
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_outbound.py::test_status_event_uses_compiled_state_not_raw -q
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py
- [ ] ticket-reducer.py loaded via importlib (not standard import) for compiled-state extraction
  Verify: grep -q 'importlib\|spec_from_file_location' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py && grep -q 'ticket.reducer\|ticket_reducer' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-outbound.py
