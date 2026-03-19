---
id: w21-0wkv
status: open
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

