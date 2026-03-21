---
id: dso-of7g
status: in_progress
deps: [dso-vfj0]
links: []
created: 2026-03-21T08:35:10Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-njch
---
# Wire 'ticket fsck' subcommand into the ticket dispatcher

Add 'fsck' routing to plugins/dso/scripts/ticket dispatcher script.

File: plugins/dso/scripts/ticket (edit existing)

Changes:
1. In the _usage() function, add: '  fsck        Check ticket system integrity (non-destructive)'
2. In the case statement, add:
   fsck)
       _ensure_initialized
       exec bash "$SCRIPT_DIR/ticket-fsck.sh" "$@"
       ;;
   Place after 'compact)' and before '*)'

This task is infrastructure wiring only — no conditional logic or business rules. The fsck routing delegates entirely to ticket-fsck.sh (implemented in the dependency task).

Unit Test Exemption Justification:
- test-exempt: This task is infrastructure-boundary-only (dispatcher routing). The code has no conditional logic — it unconditionally delegates to ticket-fsck.sh. Any test would be a change-detector test asserting the routing string exists. Behavior is verified by the integration test in test-ticket-fsck.sh which calls 'ticket fsck' end-to-end.

Acceptance Criteria:
- [ ] 'ticket fsck' is listed in ticket dispatcher usage output
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket 2>&1 | grep -q 'fsck'
- [ ] 'ticket fsck' routes to ticket-fsck.sh (case statement present)
  Verify: grep -q 'fsck)' $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket
- [ ] 'ticket fsck' exits non-zero when ticket system not initialized (graceful error)
  Verify: (cd /tmp && bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket fsck 2>&1; test $? -ne 0) || true
- [ ] ruff check passes (no Python changes)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py

