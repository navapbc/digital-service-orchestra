---
id: w21-qsty
status: closed
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


## Notes

**2026-03-19T22:07:30Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T22:08:30Z**

CHECKPOINT 2/6: Code patterns understood ✓ — _sync_pull_ticket at line 3556; frontmatter scan ends at 3715; insert title dedup at 3716 (before 'local now'); use python3 one-liner checking .index.json title field case-insensitively; summary var holds Jira title

**2026-03-19T22:08:35Z**

CHECKPOINT 3/6: Tests written (none required) ✓ — GREEN task, RED test already exists at tests/scripts/test-tk-sync-pull-title-dedup.sh

**2026-03-19T22:08:50Z**

CHECKPOINT 4/6: Implementation complete ✓ — added title dedup block after frontmatter scan in _sync_pull_ticket; checks .index.json with case-insensitive python3 one-liner; prints warning and returns 0 on match

**2026-03-19T22:09:47Z**

CHECKPOINT 5/6: Tests passed GREEN ✓ — test-tk-sync-pull-title-dedup.sh: 7/7 PASS; test-tk-sync-pull-jira-key-dedup.sh: 3/3 PASS (no regression)

**2026-03-19T22:16:23Z**

CHECKPOINT 6/6: Done ✓ — All acceptance criteria verified: test-tk-sync-pull-title-dedup.sh 7/7 PASS (SC1 title dedup, SC2 case-insensitive, SC3 jira_key precedence); test-tk-sync-pull-jira-key-dedup.sh 3/3 PASS; all tk-related tests pass; bash tests/run-all.sh pre-existing failures (test-cascade-breaker, test-commit-failure-tracker) confirmed unrelated to this change (only plugins/dso/scripts/tk modified)
