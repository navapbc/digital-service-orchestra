---
id: dso-1kcx
status: closed
deps: []
links: []
created: 2026-03-21T04:56:14Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o72z
---
# Contract: define STATUS and COMMENT event data schemas in ticket-event-format.md

Update plugins/dso/docs/contracts/ticket-event-format.md to define the data payload schemas for STATUS and COMMENT event types (forward-referenced in the existing contract from w21-ablv).

STATUS data schema:
  status: string (one of: open, in_progress, closed, blocked)
  current_status: string — the status the writer read before transitioning (optimistic concurrency proof)

COMMENT data schema:
  body: string — the comment text (non-empty)

These schemas are required before implementing ticket-transition.sh and ticket-comment.sh so the reducer and writers agree on field names.

test-exempt: This is a documentation-only task. No conditional logic, no testable behavior. The verification is that the fields appear in the contract file and the file is valid markdown.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] plugins/dso/docs/contracts/ticket-event-format.md contains STATUS data schema with `status` and `current_status` fields
  Verify: grep -q 'current_status' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md
- [ ] plugins/dso/docs/contracts/ticket-event-format.md contains COMMENT data schema with `body` field
  Verify: grep -q 'COMMENT' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md && grep -q 'body' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md
- [ ] Contract file is valid markdown (parseable, no broken headers)
  Verify: python3 -c "import pathlib; content=pathlib.Path('$(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md').read_text(); assert len(content) > 0"

## Notes

**2026-03-21T05:04:46Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T05:04:51Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T05:04:51Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-21T05:05:13Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T05:05:13Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T05:05:15Z**

CHECKPOINT 6/6: Done ✓

**2026-03-21T05:07:15Z**

CHECKPOINT 6/6: Done ✓ — Updated ticket-event-format.md with STATUS and COMMENT schemas.
