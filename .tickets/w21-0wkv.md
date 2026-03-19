---
id: w21-0wkv
status: in_progress
deps: [w21-r8rd, w21-nveh]
links: []
created: 2026-03-19T20:49:05Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ycsr
---
# GREEN: add frontmatter jira_key scan to sync pull

In plugins/dso/scripts/tk _sync_pull_ticket(), after ledger reverse lookup (~line 3674), when existing_tk_id is empty, BEFORE tombstone/closed checks at line 3679: scan $tickets_dir/*.md frontmatter for jira_key: $jira_key. If found, set existing_tk_id to that ticket's basename. Print to stderr: "warning: Jira $jira_key already exists as local ticket $existing_tk_id (frontmatter match) — skipping creation". Fall through to existing update path.

Note: update-path correctness is existing behavior and out of scope for this task.

TDD: Task 3's test turns GREEN.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash tests/run-all.sh
- [ ] Sync pull jira_key dedup test passes
  Verify: bash tests/scripts/test-tk-sync-pull-jira-key-dedup.sh
- [ ] Stderr contains frontmatter match message
  Verify: bash tests/scripts/test-tk-sync-pull-jira-key-dedup.sh 2>&1 | grep -q 'frontmatter match'


## Notes

<!-- note-id: hl1wk6ve -->
<!-- timestamp: 2026-03-19T21:47:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 8j2xeyzj -->
<!-- timestamp: 2026-03-19T21:48:04Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: tr0uwlp0 -->
<!-- timestamp: 2026-03-19T21:48:09Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: xa60kvvg -->
<!-- timestamp: 2026-03-19T21:48:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: qfj27g7c -->
<!-- timestamp: 2026-03-19T21:48:42Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: RED test now GREEN ✓ (3/3 assertions pass)

<!-- note-id: yue399gs -->
<!-- timestamp: 2026-03-19T21:55:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — dedup test GREEN (3/3), run-all failures are pre-existing (merge-to-main, dispatcher, eval — unrelated to _sync_pull_ticket)
