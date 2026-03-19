---
id: w21-qsty
status: open
deps: [w21-0wkv, w21-737k]
links: []
created: 2026-03-19T20:49:24Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ycsr
---
# GREEN: add title dedup to sync pull

In plugins/dso/scripts/tk _sync_pull_ticket(), AFTER jira_key frontmatter check (Task 4), before "NEW issue" branch: when existing_tk_id is still empty, read .index.json and check for matching title. If found, print to stderr: "warning: Jira $jira_key has matching title with local ticket $existing_tk_id — skipping creation". Return 0.

Includes idempotency verify: run sync twice against same stub, assert no new files on second run.

TDD: Task 5's test turns GREEN.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash tests/run-all.sh
- [ ] Sync title dedup test passes
  Verify: bash tests/scripts/test-tk-sync-pull-title-dedup.sh
- [ ] Idempotency (SC4): run sync twice, no new files on second run
  Verify: (verified inline in test-tk-sync-pull-title-dedup.sh)

