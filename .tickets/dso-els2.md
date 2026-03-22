---
id: dso-els2
status: closed
deps: [dso-60uy]
links: []
created: 2026-03-22T03:54:11Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Register 'revert' subcommand in ticket dispatcher

Add 'revert' routing to the ticket dispatcher (plugins/dso/scripts/ticket).

File to edit: plugins/dso/scripts/ticket

Changes:
1. Add to _usage() help text:
   '  revert      Revert a specific bridge action (REVERT event)'
2. Add routing case before the '*) echo error' fallback:
   revert)
       _ensure_initialized
       exec bash "$SCRIPT_DIR/ticket-revert.sh" "$@"
       ;;

This task is inert until ticket-revert.sh (dso-60uy) exists — adding the routing alone does not break the system (it just routes to a missing file, which would fail with 'No such file', but since dso-60uy must complete first, no issue).

TDD Requirement: This is structural wiring only — no conditional logic. Verify by running: ticket revert --help and confirming the route is registered (exit behavior from ticket-revert.sh, not dispatcher).
Justification for unit test exemption: (1) no conditional logic — pure dispatcher wiring; (2) any test would be a change-detector asserting the case entry exists; (3) infrastructure-boundary-only — dispatcher routing, not business logic.

Verify: cd $(git rev-parse --show-toplevel) && grep -q 'revert)' plugins/dso/scripts/ticket

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] 'revert' subcommand is routed in plugins/dso/scripts/ticket dispatcher
  Verify: grep -q 'revert)' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket
- [ ] _usage() text mentions 'revert' in plugins/dso/scripts/ticket
  Verify: grep -A2 'revert' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket | grep -qi 'revert.*bridge\|undo\|REVERT'
- [ ] 'bridge-status' and 'bridge-fsck' subcommands also routed in dispatcher (cross-check)
  Verify: grep -q 'bridge-status)' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket && grep -q 'bridge-fsck)' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket

