---
id: dso-qki2
status: open
deps: []
links: []
created: 2026-03-23T20:26:38Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-78iq
---
# RED: Write failing tests for pre-commit-ticket-gate.sh

Write tests/hooks/test-pre-commit-ticket-gate.sh covering all gate scenarios BEFORE the hook exists (RED phase).

Following the pattern of tests/hooks/test-pre-commit-test-gate.sh: use isolated temp git repos, handle missing-hook gracefully (print NOTE message), source plugins/dso/hooks/lib/deps.sh.

TDD REQUIREMENT: All tests that exercise the hook's behavior must fail (RED) before Task 2 creates the hook file. Tests should check for hook absence and print 'NOTE: pre-commit-ticket-gate.sh not found — running in RED phase'.

Test cases (10 minimum):
1. test_blocks_missing_ticket_id — commit msg with no ticket ID exits non-zero when non-allowlisted files staged
2. test_blocks_invalid_ticket_format — commit msg 'fix: ABC-123 bug' (wrong format) exits non-zero
3. test_allows_valid_v3_ticket_id — commit msg with valid XXXX-XXXX hex ID and matching dir+CREATE event exits 0
4. test_blocks_nonexistent_ticket — valid XXXX-XXXX format but no dir/CREATE event in tracker exits non-zero
5. test_skips_when_all_allowlisted — all staged files match allowlist → exits 0 without ticket check
6. test_merge_commit_exempt — MERGE_HEAD file present in .git → exits 0 unconditionally
7. test_graceful_degradation_no_tracker — TICKET_TRACKER_OVERRIDE points to nonexistent path → exits 0 with warning on stderr
8. test_error_message_format_hint — blocked output contains 'XXXX-XXXX' format and 'ticket create' pointer
9. test_allows_multiple_ids_in_message — commit msg with multiple IDs passes if at least one valid and exists
10. test_non_allowlisted_staged_files_trigger_check — non-allowlisted staged file with no ticket ID is blocked

Env var injection for tests:
- TICKET_TRACKER_OVERRIDE — path to fake/real tracker dir (instead of $REPO_ROOT/.tickets-tracker)
- CONF_OVERRIDE — path to fake allowlist conf (same as review gate tests)
- COMMIT_MSG_FILE_OVERRIDE — path to temp commit message file (instead of $1 from git hook)

## Acceptance Criteria

- [ ] tests/hooks/test-pre-commit-ticket-gate.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh
- [ ] Test file contains at least 10 test_ functions
  Verify: grep -c 'test_' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh | awk '{exit ($1 < 10)}'
- [ ] Test file is executable or runnable via bash
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1; true
- [ ] Test file fuzzy-matches source: normalized 'precommitticketgatesh' is substring of 'testprecommitticketgatesh'
  Verify: echo 'testprecommitticketgatesh' | grep -q 'precommitticketgatesh'
- [ ] bash tests/run-all.sh does not crash with unexpected errors
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -v 'FAIL\|not found' | grep -v 'ERROR'; true


## Notes

**2026-03-23T20:29:04Z**

Gap Analysis AC Amendment: Ensure the test script is runnable (bash-executable). Add to acceptance criteria: 'Test file runs without bash syntax errors: Verify: bash -n $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh'
