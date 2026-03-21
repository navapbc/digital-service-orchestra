---
id: dso-2xo3
status: open
deps: []
links: []
created: 2026-03-21T16:19:31Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8011
---
# RED: Write failing integration test in test-ticket-transition.sh for unblock output on close

Add failing integration tests to tests/scripts/test-ticket-transition.sh for the auto-unblock output produced when closing a ticket.

TDD Requirement (RED): Write these test cases FIRST -- they must FAIL before ticket-transition.sh is extended:
- test_close_ticket_reports_newly_unblocked: transition ticket A to closed; verify stdout contains 'UNBLOCKED: <B>' when B was blocked only by A
- test_close_ticket_reports_no_unblocked: transition ticket A to closed; verify stdout contains 'UNBLOCKED: none' when no tickets were waiting only on A
- test_close_ticket_unblocked_output_only_on_close: transition ticket A to in_progress; verify stdout does NOT contain 'UNBLOCKED:' (output only on close)
- test_close_ticket_succeeds_even_if_unblock_fails: temporarily rename ticket-unblock.py or pass invalid tracker_dir; verify 'ticket transition <id> open closed' exits 0 and emits a warning to stderr (transition non-blocking even when unblock detection fails)

Test pattern:
- Use the existing fixture setup in test-ticket-transition.sh (ticket init, create events)
- Assert on stdout of 'ticket transition <id> <current> closed' command
- Must fail before Step 4 (ticket-transition.sh extension) is implemented

File: tests/scripts/test-ticket-transition.sh (extend existing file)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] test-ticket-transition.sh contains all 4 new test functions
  Verify: for t in test_close_ticket_reports_newly_unblocked test_close_ticket_reports_no_unblocked test_close_ticket_unblocked_output_only_on_close test_close_ticket_succeeds_even_if_unblock_fails; do grep -q "$t" $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-transition.sh || { echo "MISSING: $t"; exit 1; }; done
- [ ] test-ticket-transition.sh contains all 4 new test functions (including test_close_ticket_succeeds_even_if_unblock_fails)
  Verify: for t in test_close_ticket_reports_newly_unblocked test_close_ticket_reports_no_unblocked test_close_ticket_unblocked_output_only_on_close test_close_ticket_succeeds_even_if_unblock_fails; do grep -q "$t" $(git rev-parse --show-toplevel)/tests/scripts/test-ticket-transition.sh || { echo "MISSING: $t"; exit 1; }; done
- [ ] All 4 new test cases FAIL before ticket-transition.sh is extended (RED state confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-transition.sh 2>&1 | grep -qE 'FAIL|test_close_ticket_reports_newly_unblocked.*FAIL'

