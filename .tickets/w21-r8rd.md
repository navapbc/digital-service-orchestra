---
id: w21-r8rd
status: in_progress
deps: [w21-1mgj]
links: []
created: 2026-03-19T20:48:44Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-ycsr
---
# GREEN: add title dedup guard to cmd_create

In plugins/dso/scripts/tk cmd_create(), after title length validation (~line 467), BEFORE generate_id: read .index.json via python3, check if any entry's title matches exactly. If found, print to stderr: "Error: ticket <conflicting-id> already has title: <title>" and return 1.

TDD: Task 1's test (test-tk-create-title-dedup.sh) turns GREEN.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash tests/run-all.sh
- [ ] ruff check passes
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] tk create dedup test passes
  Verify: bash tests/scripts/test-tk-create-title-dedup.sh


## Notes

**2026-03-19T21:35:09Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T21:35:24Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T21:35:25Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-19T21:35:42Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T21:43:42Z**

CHECKPOINT 5/6: Tests pass — dedup test GREEN (3/3), tk-index (11/11), tk-index-rebuild (2/2), tk-dep-rm (3/3), tk-close (4/4), tk-no-sync (5/5) ✓

**2026-03-19T21:43:48Z**

CHECKPOINT 6/6: Done ✓
