---
id: w21-nveh
status: in_progress
deps: []
links: []
created: 2026-03-19T20:48:56Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ycsr
---
# RED: test sync pull frontmatter jira_key dedup

Write tests/scripts/test-tk-sync-pull-jira-key-dedup.sh. In temp TICKETS_DIR:
1. Write ticket file with jira_key: DIG-TEST-99 in frontmatter, id test-abc1
2. Create empty .sync-state.json ledger (NO entry — tests "regardless of ledger")
3. Stub acli returns: {"key":"DIG-TEST-99","fields":{"summary":"Test Issue","status":{"name":"To Do"},"issuetype":{"name":"Story"},"priority":{"name":"Medium"},"description":""}}
4. Run tk sync. Assert: no new ticket AND stderr contains "DIG-TEST-99" and "test-abc1"

TDD: Fails because _sync_pull_ticket only checks ledger, not frontmatter.

## Acceptance Criteria

- [ ] Test file exists
  Verify: test -f tests/scripts/test-tk-sync-pull-jira-key-dedup.sh
- [ ] Test body references jira_key fixture
  Verify: grep -q 'DIG-TEST-99' tests/scripts/test-tk-sync-pull-jira-key-dedup.sh
- [ ] Running the test FAILS (RED)
  Verify: ! bash tests/scripts/test-tk-sync-pull-jira-key-dedup.sh


## Notes

**2026-03-19T21:04:45Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T21:06:09Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T21:07:01Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T21:09:01Z**

CHECKPOINT 4/6: Implementation complete ✓ — test is RED as expected (new ticket created = duplicate, local id not in output)

**2026-03-19T21:09:28Z**

CHECKPOINT 5/6: Validation passed ✓ — AC1 pass, AC2 pass, AC3 pass (test fails as RED)

**2026-03-19T21:09:38Z**

CHECKPOINT 6/6: Done ✓ — test written, verified RED (2/3 assertions fail: no-new-file and output-mentions-local-id), all 3 ACs verified
