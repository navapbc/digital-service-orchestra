---
id: dso-jyob
status: in_progress
deps: [dso-bdk5, dso-sroj]
links: []
created: 2026-03-23T17:34:49Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-k4sw
---
# Add bug-close-reason and open-children guards to ticket-transition.sh


## Notes

**2026-03-23T17:35:42Z**

## Description
Add guard logic to ticket-transition.sh. CRITICAL: guard logic must run INSIDE the Python flock block (lines 118-197), after reading state via the reducer but before building the STATUS event JSON. This matches the existing optimistic concurrency pattern.

When target_status='closed':
1. Read ticket type from reducer state. If type='bug', require --reason flag with 'Fixed:' or 'Escalated to user:' prefix. Exit 1 with instructive error if missing.
2. Call ticket_find_open_children. If any open children, exit 1 listing them with instruction to close children first.

Shell must parse --reason from remaining args before passing to Python block as additional sys.argv.

Also update plugins/dso/docs/ticket-cli-reference.md with --reason flag documentation.

## ACCEPTANCE CRITERIA

- [ ] Bug close without --reason exits non-zero
  Verify: bash -c 'cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-transition.sh 2>&1 | grep -q test_transition_bug_close_requires_reason.*PASS'
- [ ] Bug close with --reason exits 0
  Verify: bash -c 'cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-transition.sh 2>&1 | grep -q test_transition_bug_close_with_reason.*PASS'
- [ ] Close with open children exits non-zero
  Verify: bash -c 'cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-transition.sh 2>&1 | grep -q test_transition_close_blocked_with_open_children.*PASS'
- [ ] Bash syntax validation passes
  Verify: bash -n plugins/dso/scripts/ticket-transition.sh

**2026-03-23T19:40:33Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T19:41:29Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-23T19:41:33Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-23T19:42:52Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-23T19:46:14Z**

CHECKPOINT 5/6: Validation passed ✓ — bash -n OK, all 3 RED tests GREEN (36/36 passing)

**2026-03-23T19:46:20Z**

CHECKPOINT 6/6: Done ✓ — All 4 acceptance criteria met. Guards implemented in ticket-transition.sh; docs updated in ticket-cli-reference.md.
