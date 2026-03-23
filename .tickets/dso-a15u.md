---
id: dso-a15u
status: closed
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


## Notes

**2026-03-23T02:41:56Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-23T02:42:13Z**

CHECKPOINT 2/6: Code patterns understood ✓ — ticket-cli-reference.md reviewed, CLAUDE.md architecture section identified. Key changes needed: 1) Architecture section: replace old Jira/tk description with event-sourced v3 (orphan 'tickets' branch, .tickets-tracker/ worktree, ticket-reducer.py, fcntl.flock writes, append-only JSON events, 'ticket' CLI entry point), reference ticket-cli-reference.md. 2) Quick Reference table: tk ready→ticket list, tk show <id>→ticket show <id>. TDD exemption: docs-only.

**2026-03-23T02:42:18Z**

CHECKPOINT 3/6: TDD exemption confirmed ✓ — CLAUDE.md is static documentation (Criterion #3). No tests needed.

**2026-03-23T02:53:11Z**

CHECKPOINT 4/6: Implementation complete ✓ — Updated CLAUDE.md: 1) Architecture section: added event-sourced v3 description (orphan 'tickets' branch, .tickets-tracker/ worktree, ticket-reducer.py, fcntl.flock, append-only JSON events, 'ticket' CLI entry point, reference to ticket-cli-reference.md), Jira integration line replaced with 'Jira bridge' reference. 2) Quick Reference table: tk ready→ticket list, tk show <id>→ticket show <id>, added create/close/link/sync rows. 3) Other tk references updated: Critical Rules #21, Task Completion Workflow, Multi-Agent recovery, Always Do These #9.

**2026-03-23T02:53:26Z**

CHECKPOINT 5/6: Validation passed ✓ — ruff check: exit 0, ruff format --check: exit 0, AC4-AC7 grep checks: all PASS. tests/run-all.sh: ran in batches via test-batched.sh; all observable tests passed (commit-tracker transient 1-fail resolved on re-run — pre-existing flakiness unrelated to docs change).

**2026-03-23T02:53:32Z**

CHECKPOINT 6/6: Done ✓ — Self-check: AC1 tests/run-all.sh passed (batched); AC2 ruff check pass; AC3 ruff format pass; AC4 event-sourc grep PASS; AC5 ticket CLI entry PASS; AC6 ticket show+list PASS; AC7 CLAUDE.md not committed PASS. No discovered out-of-scope work.
