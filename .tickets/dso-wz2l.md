---
id: dso-wz2l
status: open
deps: [dso-nvzp, dso-els2]
links: []
created: 2026-03-22T03:52:48Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Implement ticket-bridge-status.sh and register 'bridge-status' in ticket dispatcher

Create ticket-bridge-status.sh and add 'bridge-status' routing to the ticket dispatcher.

Files to create/edit:
- Create: plugins/dso/scripts/ticket-bridge-status.sh
- Edit: plugins/dso/scripts/ticket (dispatcher) — add 'bridge-status' subcommand

ticket-bridge-status.sh implementation:
- Usage: ticket bridge-status [--format=json]
- Status file: $(git rev-parse --show-toplevel)/.tickets-tracker/.bridge-status.json
- If status file missing: print 'No bridge status file found. Has the bridge run yet?' to stderr; exit 1
- If status file exists, read JSON and display:
  - Last run time: last_run_timestamp (UTC ISO string)
  - Status: success/failure
  - Error (if any): error field
  - Unresolved conflicts: unresolved_conflicts count
  - Unresolved BRIDGE_ALERTs: count of tickets with unresolved alerts (computed by scanning .tickets-tracker/*/BRIDGE_ALERT events — reuse logic from reducer or glob directly)
- --format=json: output raw JSON from status file (plus computed unresolved_alerts_count)
- Default format: human-readable text output

Status file format (.bridge-status.json):
  { last_run_timestamp: int (UTC epoch), success: bool, error: str|null, unresolved_conflicts: int }
  This file is written by bridge-inbound.py and bridge-outbound.py at end of each run.

Dispatcher addition (plugins/dso/scripts/ticket):
  bridge-status)
      _ensure_initialized
      exec bash "$SCRIPT_DIR/ticket-bridge-status.sh" "$@"
      ;;
Also update _usage() help text.

TDD Requirement: Task dso-nvzp (RED tests) must be RED before this task runs. After this task, all bridge-status tests must pass.

Run tests: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test_ticket_bridge_status.sh (or python3 -m pytest tests/scripts/test_bridge_status.py -v)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ticket-bridge-status.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-bridge-status.sh
- [ ] ticket bridge-status is routed in the dispatcher (plugins/dso/scripts/ticket)
  Verify: grep -q 'bridge-status)' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket
- [ ] ticket bridge-status shows last_run_timestamp, success/failure, error, unresolved_conflicts when status file exists
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_status.py::test_bridge_status_shows_last_run_time tests/scripts/test_bridge_status.py::test_bridge_status_shows_failure_when_last_run_failed tests/scripts/test_bridge_status.py::test_bridge_status_shows_unresolved_conflicts -v
- [ ] ticket bridge-status exits non-zero when no status file found
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_status.py::test_bridge_status_exits_nonzero_when_no_status_file -v
- [ ] ticket bridge-status --format=json outputs valid JSON
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_status.py::test_bridge_status_json_output_format -v
- [ ] [Gap Analysis AC amendment] .bridge-status.json write path is implemented in bridge-inbound.py and/or bridge-outbound.py. The implementer must add write_bridge_status() calls at the end of bridge runs (success and failure paths). Alternatively, if writing .bridge-status.json is intentionally deferred to a future story, document this explicitly in ticket-bridge-status.sh with a comment noting the file is optional until that story lands.
  Verify: grep -qE 'bridge.status\.json|write_bridge_status' $(git rev-parse --show-toplevel)/plugins/dso/scripts/bridge-inbound.py || grep -qE 'bridge.status|status_file' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-bridge-status.sh

