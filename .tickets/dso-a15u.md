---
id: dso-a15u
status: open
deps: [dso-ech8]
links: []
created: 2026-03-23T00:25:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o5ap
---
# Update CLAUDE.md architecture section and quick reference table for ticket system v3

Update CLAUDE.md with two targeted changes:

1. ARCHITECTURE SECTION: Replace the current ticket system description (which describes tk and the old Markdown storage in .tickets/) with the event-sourced v3 architecture. Key points to cover: orphan branch named 'tickets', worktree mounted at the tracker directory, Python reducer ticket-reducer.py, flock-serialized writes, append-only JSON events, and 'ticket' as the CLI entry point. Reference plugins/dso/docs/ticket-cli-reference.md for the full CLI reference.

2. QUICK REFERENCE TABLE: Replace tk command references in the Quick Reference table with equivalent ticket subcommands. Minimum replacements: tk ready->ticket list, tk show <id>->ticket show <id>, tk create->ticket create, tk close <id>->ticket transition <id> <current> closed, tk dep->ticket link, tk sync->Jira bridge (see architecture). Update all other tk references in the table.

IMPORTANT: Modify CLAUDE.md in working tree only. Do NOT commit. This file will be included in w21-wbqz atomic commit alongside ticket-cli-reference.md.

TDD Requirement: TDD exemption — Criterion #3 (static assets only): CLAUDE.md is a Markdown configuration/documentation file with no conditional logic or executable behavior.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] CLAUDE.md architecture section mentions event-sourced storage
  Verify: grep -q 'event-sourc' $(git rev-parse --show-toplevel)/CLAUDE.md
- [ ] CLAUDE.md architecture section mentions ticket CLI entry point
  Verify: grep -q 'ticket.*CLI\|ticket.*entry\|^ticket ' $(git rev-parse --show-toplevel)/CLAUDE.md
- [ ] CLAUDE.md quick reference table contains ticket show and ticket list commands
  Verify: grep -q 'ticket show' $(git rev-parse --show-toplevel)/CLAUDE.md && grep -q 'ticket list' $(git rev-parse --show-toplevel)/CLAUDE.md
- [ ] CLAUDE.md is NOT committed (lives in working tree only)
  Verify: git -C $(git rev-parse --show-toplevel) status --short | grep -q 'CLAUDE.md'

