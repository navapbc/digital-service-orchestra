---
id: w20-qxu2
status: closed
deps: [w20-0aaw]
links: []
created: 2026-03-21T16:31:50Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6llo
---
# RED test: tombstone file written on archive

TDD RED phase for tombstone write. Write failing tests in tests/scripts/test-archive-tombstone.sh asserting that archive-closed-tickets.sh creates a tombstone JSON for each archived ticket at .tickets/archive/tombstones/<id>.json with fields: id, type, final_status. Tests: (1) test_tombstone_created_on_archive, (2) test_tombstone_not_created_for_protected_ticket, (3) test_tombstone_format_valid_json (exactly 3 fields), (4) test_tombstone_final_status_correct. Include suite-runner guard matching test-ticket-compact.sh pattern. Tests MUST FAIL (RED) against current archive-closed-tickets.sh.

## ACCEPTANCE CRITERIA

- [ ] Test file exists at tests/scripts/test-archive-tombstone.sh
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone.sh
- [ ] Test file contains at least 4 test functions matching test_tombstone_
  Verify: grep -c 'test_tombstone_' $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone.sh | awk '{exit ($1 < 4)}'
- [ ] Tests fail RED without implementation (script exits non-zero when guard disabled)
  Verify: _RUN_ALL_ACTIVE=0 bash $(git rev-parse --show-toplevel)/tests/scripts/test-archive-tombstone.sh 2>/dev/null; test $? -ne 0
- [ ] bash tests/run-all.sh passes exit 0 (suite-runner guard suppresses RED tests)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh

