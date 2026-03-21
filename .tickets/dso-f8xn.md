---
id: dso-f8xn
status: open
deps: [dso-3npm, dso-2xo3]
links: []
created: 2026-03-21T16:19:43Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-8011
---
# Extend ticket-transition.sh to call detect_newly_unblocked and emit UNBLOCKED output on close

Extend plugins/dso/scripts/ticket-transition.sh to invoke ticket-unblock.py after a successful STATUS write to 'closed', and emit structured output listing newly unblocked tickets.

Implementation requirements:
1. After the flock block exits with code 0 AND target_status == 'closed': call ticket-unblock.py
2. Invocation: python3 $REDUCER_DIR/ticket-unblock.py "$TRACKER_DIR" "$ticket_id" --event-source local-close
3. Output format:
   - If unblocked tickets found: emit 'UNBLOCKED: <id1>,<id2>' to stdout (comma-separated, no spaces)
   - If no newly unblocked: emit 'UNBLOCKED: none' to stdout
4. Non-blocking: if ticket-unblock.py fails (exit non-zero), emit a warning to stderr but do NOT fail the transition (the close itself already succeeded)
5. UNBLOCKED output must appear AFTER the transition succeeds -- never before
6. Only emit UNBLOCKED output when target_status == 'closed' (not for other transitions)

File: plugins/dso/scripts/ticket-transition.sh

TDD Requirement: Integration tests in tests/scripts/test-ticket-transition.sh (added in dso-2xo3) must be RED before starting. Run the new test cases and confirm they fail. Then extend ticket-transition.sh to GREEN.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] All 3 integration tests in test-ticket-transition.sh pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-transition.sh 2>&1 | grep -qE 'test_close_ticket_reports_newly_unblocked.*PASS'
- [ ] ticket transition to 'closed' emits 'UNBLOCKED:' line to stdout
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-transition.sh 2>&1 | grep -q 'UNBLOCKED'
- [ ] ticket transition to 'in_progress' does NOT emit 'UNBLOCKED:' to stdout
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-ticket-transition.sh 2>&1 | grep -q 'test_close_ticket_unblocked_output_only_on_close.*PASS'
- [ ] Non-blocking: ticket-transition.sh exits 0 even if ticket-unblock.py fails
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/scripts/test_ticket_unblock.py::test_event_source_parameter_accepted -q

