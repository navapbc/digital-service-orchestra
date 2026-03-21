---
id: w21-ablv
status: closed
deps: []
links: []
created: 2026-03-20T04:07:02Z
type: story
priority: 1
assignee: Joe Oakhart
parent: dso-0k2k
---
# As a developer, I can initialize the ticket system and create/view tickets via event-sourced storage

## Description

**What**: Build the foundational storage engine: `ticket init` (orphan branch, .tickets-tracker/ worktree, .gitignore), `ticket create` (UUID generation, CREATE event, atomic write, auto-commit), and `ticket show` (python3 reducer compiles events to current state).

**Why**: This is the walking skeleton — proves the entire event-sourced architecture end-to-end. If init/create/show works with flock serialization and atomic writes, the core design is validated.

**Scope**:
- IN: ticket init, ticket create, ticket show, event file format, reducer, flock-serialized git commits, atomic writes (temp+rename), gc.auto=0, all JSON via Python (json.dumps/json.load), explicit UTF-8, UTC epoch timestamps
- OUT: ticket list, ticket transition, ticket comment (Story w21-o72z), caching (Story w21-f8tg), compaction (Story w21-q0nn)

## Done Definitions

- When this story is complete, `ticket init` creates an orphan `tickets` branch, mounts `.tickets-tracker/` via `git worktree add`, and adds `.tickets-tracker` to both `.git/info/exclude` and the committed `.gitignore`
  ← Satisfies: "ticket init creates an orphan tickets branch"
- When this story is complete, `ticket create` generates a collision-resistant UUID, writes a CREATE event file via atomic temp-file-then-rename, and auto-commits via flock + `git add <specific-file>`
  ← Satisfies: "ticket create generates a unique short ID, writes a CREATE event file, and auto-commits"
- When this story is complete, `ticket show` reads all events for a ticket via the python3 reducer and returns the compiled current state
  ← Satisfies: "ticket show works correctly using append-only event files and a python3 reducer"
- When this story is complete, the event file naming convention and directory layout are documented as a contract (e.g., `.tickets-tracker/events/<ticket-id>/<timestamp>-<uuid>-<TYPE>.json`) that downstream stories can depend on
  ← Satisfies: cross-story contract (adversarial review)
- When this story is complete, the reducer's event ordering contract is defined and documented (filename sort with timestamp prefix, deterministic tie-breaking for same-second events)
  ← Satisfies: cross-story contract (adversarial review)
- When this story is complete, every `ticket` command auto-initializes if `.tickets-tracker/` does not exist — `ticket init` runs silently on first use, making initialization transparent to the user
  ← Satisfies: "transparent first-use initialization"
- When this story is complete, `ticket init` generates a unique environment ID (UUID) at `.tickets-tracker/.env-id` (gitignored on the tickets branch) that is embedded in every event for cross-environment conflict resolution
  ← Satisfies: cross-environment identity for Epic 2 conflict resolution
- When this story is complete, unit tests are written and passing for all new logic

## Considerations

- [Reliability] flock timeout under contention — concurrent sessions may block if commit takes too long. gc.auto=0 must persist in worktree-level git config, not global
- [Maintainability] All commands share the write-commit pattern (atomic write, flock, git add specific-file, commit). Define as a shared function to prevent drift between commands added in Story w21-o72z
- [Reliability] flock scope and lock file location must be specified as a cross-cutting contract: what file is locked, global vs per-ticket, timeout duration. This decision affects Stories w21-q0nn and w21-ay8w

## Design References

See plugins/dso/docs/ticket-migraiton-v3/ for the 7 design documents. Architecture reviewed via red-team/blue-team (see epic notes on dso-0k2k).

## Notes

**2026-03-21T00:47:46Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
