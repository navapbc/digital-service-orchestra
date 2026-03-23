---
id: dso-9p30
status: in_progress
deps: [dso-bdk5, dso-sroj]
links: []
created: 2026-03-23T17:34:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-k4sw
---
# Add closed-parent guard to ticket-link.sh for depends_on


## Notes

**2026-03-23T17:35:42Z**

## Description
Add closed-parent guard to ticket-link.sh. In _write_link_event(), after validating both tickets exist, add: if relation='depends_on' AND target ticket status is 'closed' (via ticket_read_status on target_id, NOT source_id), exit 1 with error. Other relation types (relates_to, blocks) pass through unchanged.

Note: _write_link_event is called for reciprocal relates_to links — guard must only fire when relation=depends_on.

## ACCEPTANCE CRITERIA

- [ ] Link depends_on to closed target exits non-zero
  Verify: bash -c 'cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-link.sh 2>&1 | grep -q test_link_depends_on_closed_target_blocked.*PASS'
- [ ] Link relates_to to closed target exits 0
  Verify: bash -c 'cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-link.sh 2>&1 | grep -q test_link_relates_to_closed_target_allowed.*PASS'
- [ ] Bash syntax validation passes
  Verify: bash -n plugins/dso/scripts/ticket-link.sh

**2026-03-23T19:41:09Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T19:41:10Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T19:41:14Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-23T19:41:26Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T19:48:33Z**

CHECKPOINT 5/6: Validation passed ✓ — all 33 tests pass (0 failures). Implementation required guards in both ticket-link.sh (bash _write_link_event) and ticket-graph.py (add_dependency), since ticket link command routes to ticket-graph.py.

**2026-03-23T19:48:39Z**

CHECKPOINT 6/6: Done ✓ — All 3 acceptance criteria satisfied.
