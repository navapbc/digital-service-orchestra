---
id: dso-9aq2
status: open
deps: []
links: []
created: 2026-03-23T00:26:16Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-o5ap
---
# Write deferred Epics 1-3 supplemental architecture documentation

Consolidate and write all documentation deferred from Epics 1-3 into plugins/dso/docs/ticket-system-v3-architecture.md — a high-level operational guide for the event-sourced ticket system.

BEFORE WRITING: Audit plugins/dso/docs/designs/adr-ticket-v3-event-sourced-storage.md and the seven design docs in plugins/dso/docs/ticket-migraiton-v3/ to identify gaps not covered by existing docs. Document only gaps — do not duplicate ADR content.

DELIVERABLE: Create plugins/dso/docs/ticket-system-v3-architecture.md covering:
- Storage layout: tracker directory structure, ticket directory layout, event file naming convention (timestamp-uuid-TYPE.json format), and how the reducer assembles state from event files
- Reducer usage: how to call ticket-reducer.py, its public interface reduce_ticket(), and what it returns
- Flock contract summary: what the write lock protects, timeout budget, and recovery path
- Worktree integration: how multi-agent sessions share the tracker directory via symlink, and the gc.auto=0 safety setting
- Cross-references to the ADR (adr-ticket-v3-event-sourced-storage.md) for design rationale
- Any gaps found in the audit: e.g., --format=llm design rationale, multi-environment sync behavior if not already covered in existing docs

IMPORTANT: Write files to working tree only. Do NOT commit. Will be included in w21-wbqz atomic commit.

TDD Requirement: TDD exemption — Criterion #3 (static assets only): documentation-only Markdown file; no conditional logic or testable behavior.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] File plugins/dso/docs/ticket-system-v3-architecture.md exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-system-v3-architecture.md
- [ ] File covers storage layout (tracker directory and event file naming)
  Verify: grep -q 'timestamp.*uuid\|uuid.*timestamp\|event.*naming\|naming.*convention' $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-system-v3-architecture.md
- [ ] File covers reducer usage
  Verify: grep -qE 'ticket-reducer|reduce_ticket' $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-system-v3-architecture.md
- [ ] File covers worktree integration
  Verify: grep -q 'worktree' $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-system-v3-architecture.md
- [ ] File cross-references the ADR
  Verify: grep -q 'adr-ticket-v3\|ADR' $(git rev-parse --show-toplevel)/plugins/dso/docs/ticket-system-v3-architecture.md
- [ ] File is NOT committed (working tree only; for inclusion in w21-wbqz atomic commit)
  Verify: git -C $(git rev-parse --show-toplevel) status --short | grep -q 'ticket-system-v3-architecture.md'

