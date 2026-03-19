---
id: w21-plq5
status: open
deps: [w21-3fty]
links: []
created: 2026-03-19T20:49:48Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ycsr
---
# GREEN: add parent-child protection to archive script

In plugins/dso/scripts/archive-closed-tickets.sh:
1. In _scan_tickets(), add awk extraction for parent field. Store in new associative array ticket_parent.
2. Add Phase 2b AFTER existing Phase 2 BFS (after line 100): for each ticket with status open/in_progress, if ticket_parent[$tid] is set, add ticket_parent[$tid] to the protected set. This is a REVERSE parent scan — separate from the forward _walk_deps BFS.
3. In archive loop (lines 130-147), when skipping a protected ticket with active children, print to stderr: "Skipping archive of $tid — open children: $child_list"

TDD: Task 7's test turns GREEN.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash tests/run-all.sh
- [ ] Archive parent-child test passes
  Verify: bash tests/scripts/test-archive-parent-child-protection.sh
- [ ] Deps-path regression: closed ticket with deps still protected
  Verify: (verified inline in test-archive-parent-child-protection.sh)
- [ ] Stderr lists blocking children
  Verify: bash tests/scripts/test-archive-parent-child-protection.sh 2>&1 | grep -q 'child-001'

