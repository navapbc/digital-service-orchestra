---
id: dso-lcmz
status: open
deps: [dso-97wx, dso-7svw, dso-d08c]
links: []
created: 2026-03-21T04:58:04Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Extend ticket dispatcher to route list, transition, comment subcommands

Update plugins/dso/scripts/ticket (the dispatcher) to route the three new subcommands to their implementation scripts.

Changes to plugins/dso/scripts/ticket:

1. Add list, transition, comment to the usage _usage() function output.

2. Add routing cases to the case statement:
   list)
     _ensure_initialized
     exec bash "$SCRIPT_DIR/ticket-list.sh" "$@"
     ;;
   transition)
     _ensure_initialized
     exec bash "$SCRIPT_DIR/ticket-transition.sh" "$@"
     ;;
   comment)
     _ensure_initialized
     exec bash "$SCRIPT_DIR/ticket-comment.sh" "$@"
     ;;

3. Update the usage documentation comment at the top of the file to list all 6 subcommands: init, create, show, list, transition, comment.

test-exempt: This task adds routing wires only — no conditional logic beyond the case dispatch already in the dispatcher. The actual behavior is tested by the integration test (dso-int-e2e). The case routing itself contains no branching beyond delegating to scripts that are each fully tested by their own test suites.

Justification for test-exempt: (1) no conditional logic — case dispatch is structural wiring; (2) a test for this would only assert the routing exists (change-detector test); (3) infrastructure-boundary-only — no business logic added here.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] plugins/dso/scripts/ticket dispatcher routes 'list' subcommand to ticket-list.sh
  Verify: grep -q 'ticket-list.sh' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket
- [ ] plugins/dso/scripts/ticket dispatcher routes 'transition' subcommand to ticket-transition.sh
  Verify: grep -q 'ticket-transition.sh' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket
- [ ] plugins/dso/scripts/ticket dispatcher routes 'comment' subcommand to ticket-comment.sh
  Verify: grep -q 'ticket-comment.sh' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket
- [ ] ticket dispatcher usage output includes all 6 subcommands
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket 2>&1 | grep -q 'list\|transition\|comment'
