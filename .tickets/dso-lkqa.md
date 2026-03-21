---
id: dso-lkqa
status: open
deps: [dso-lcmz]
links: []
created: 2026-03-21T04:58:29Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-o72z
---
# Update ticket-event-format.md contract and dispatcher docs to reflect full CRUD surface

Documentation update task: update the contract and dispatcher usage docs to reflect the completed CRUD surface.

Changes:

1. plugins/dso/docs/contracts/ticket-event-format.md:
   - Fill in the STATUS and COMMENT data schema sections (forward-referenced in the w21-ablv contract):
     STATUS data: { status: string, current_status: string }
     COMMENT data: { body: string }
   - Update the Forward Reference table to mark STATUS and COMMENT as 'defined' rather than forward-reference
   - Document ghost prevention behavior: ticket dirs with zero valid events return error state; corrupt CREATE returns fsck_needed

2. plugins/dso/scripts/ticket (dispatcher):
   - Ensure the top-of-file comment block documents all 6 subcommands (init, create, show, list, transition, comment)
   - Document the optimistic concurrency requirement for transition in the comment block

test-exempt: Documentation only. No executable code added. Verification is file existence and content grep.
Justification: (1) no conditional logic; (2) change-detector test would only assert text exists; (3) infrastructure-boundary-only (docs).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ticket-event-format.md Forward Reference table marks STATUS and COMMENT as 'defined'
  Verify: grep -q 'defined\|w21-o72z.*defined' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md
- [ ] ticket-event-format.md documents ghost prevention behavior (error state for zero valid events)
  Verify: grep -q 'error.*state\|ghost\|no_valid_create\|fsck_needed' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md
- [ ] Dispatcher comment block documents all 6 subcommands
  Verify: head -10 $(git rev-parse --show-toplevel)/plugins/dso/scripts/ticket | grep -q 'list\|transition\|comment'

