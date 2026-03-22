---
id: dso-rqj9
status: open
deps: [dso-5gtd, dso-wz2l]
links: []
created: 2026-03-22T03:53:18Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Implement ticket-bridge-fsck.py and register 'bridge-fsck' in ticket dispatcher

Create ticket-bridge-fsck.py and add 'bridge-fsck' routing to the ticket dispatcher.

Files to create/edit:
- Create: plugins/dso/scripts/ticket-bridge-fsck.py
- Edit: plugins/dso/scripts/ticket (dispatcher) — add 'bridge-fsck' subcommand

ticket-bridge-fsck.py implementation:
This is a BRIDGE-SPECIFIC audit tool (distinct from ticket-fsck.sh which checks JSON validity + CREATE presence):

Usage: python3 ticket-bridge-fsck.py [--tickets-root=<path>]
Or invoked via: ticket bridge-fsck

Audit checks:
1. Orphan detection: scan all SYNC event files across .tickets-tracker/; for each SYNC event with a jira_key, verify a reverse mapping exists (i.e., jira_key appears in exactly one ticket). Report orphaned jira_keys (mapped in SYNC but no longer resolvable to a single ticket).
2. Duplicate Jira mapping: detect multiple tickets mapping to the same jira_key via SYNC events. Report duplicates.
3. Stale SYNC events: a SYNC event is 'stale' if it is the most recent outbound event for a ticket AND the ticket has had no bridge activity (no new SYNC, BRIDGE_ALERT, or inbound events) for > 30 days. Report stale tickets.
4. Unresolved BRIDGE_ALERTs: count tickets with unresolved BRIDGE_ALERT events (supplement bridge-status).

Output format (human-readable text by default):
  === Bridge FSck Report ===
  Orphans: <N> (or 'none found')
  Duplicates: <N>
  Stale SYNCs: <N>
  Unresolved BRIDGE_ALERTs: <N>
  (details per category follow)

Exit: 0 if no issues found; 1 if any issues found.

Dispatcher addition (plugins/dso/scripts/ticket):
  bridge-fsck)
      _ensure_initialized
      exec python3 "$SCRIPT_DIR/ticket-bridge-fsck.py" "$@"
      ;;
Also update _usage() help text and the existing 'fsck' case comment to distinguish bridge-fsck from ticket-fsck.

TDD Requirement: Task dso-5gtd (RED tests) must be RED before this task runs. After this task, all bridge-fsck tests must pass.

Run tests: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_fsck.py -v

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ticket-bridge-fsck.py exists and is importable
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-bridge-fsck.py && python3 $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket-bridge-fsck.py --help 2>&1 | head -1
- [ ] ticket bridge-fsck is routed in the dispatcher (plugins/dso/scripts/ticket)
  Verify: grep -q 'bridge-fsck)' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket
- [ ] All 5 bridge-fsck tests pass after implementation
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_fsck.py -v
- [ ] bridge-fsck detects orphans, duplicates, and stale SYNCs correctly
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_fsck.py::test_bridge_fsck_detects_orphaned_ticket tests/scripts/test_bridge_fsck.py::test_bridge_fsck_detects_duplicate_jira_mapping tests/scripts/test_bridge_fsck.py::test_bridge_fsck_detects_stale_sync_events -v
- [ ] bridge-fsck exits 0 on clean state, exits 1 on issues found
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_bridge_fsck.py::test_bridge_fsck_exit_code -v

