---
id: w21-r8rd
status: open
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

