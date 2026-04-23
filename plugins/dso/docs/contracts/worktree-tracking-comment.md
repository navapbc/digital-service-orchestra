# Contract: Worktree Tracking Ticket Comment Format

## Purpose

Define the structured ticket comment format emitted by agents running in worktree isolation.
These comments enable cross-session lifecycle visibility for worktree-based implementation tasks.
Comments follow a space-separated key=value format after the event type prefix.

## :start

Posted immediately after a ticket is transitioned to `in_progress` and a worktree is established.

Format: `WORKTREE_TRACKING:start branch=<branch> session_branch=<branch> timestamp=<ISO8601>`

Example:
```
WORKTREE_TRACKING:start branch=worktree-20260418-215740 session_branch=worktree-20260418-215740 timestamp=2026-04-18T21:57:40Z
```

Fields:
- `branch` — current git branch (`git rev-parse --abbrev-ref HEAD`)
- `session_branch` — same as `branch` for top-level sessions; sub-agent worktree branch for isolated sub-agents
- `timestamp` — UTC ISO-8601 timestamp

## :complete

Posted by `harvest-worktree.sh` in its cleanup trap after the merge attempt (success or failure). Also posted by orchestrators in per-worktree-review-commit.md for conflict-discarded worktrees.

Format: `WORKTREE_TRACKING:complete branch=<branch> outcome=<outcome> timestamp=<ISO8601>`

Fields:
- `branch` — worktree branch where implementation landed
- `outcome` — `merged` (worktree successfully merged into session branch) or `discarded` (worktree discarded due to conflict or gate failure)
- `timestamp` — UTC ISO-8601 completion timestamp

## :landed

Posted by the orchestrator after the worktree has been merged into the session branch (via `harvest-worktree.sh` or direct merge).

Format: `WORKTREE_TRACKING:landed branch=<session_branch> timestamp=<ISO8601>`

Fields:
- `branch` — session branch that received the merged work
- `timestamp` — UTC ISO-8601 landing timestamp

## Serialization

All fields are serialized as space-separated `key=value` pairs on a single line following the event
type prefix (`WORKTREE_TRACKING:<event>`). No quoting is used; values must not contain spaces.

## Fail-silent policy

All WORKTREE_TRACKING comment writes MUST be fail-silent. Wrap the ticket comment command with
`2>/dev/null || true` so that an unavailable `.tickets-tracker/` directory, a missing ticket ID,
or any other transient error never blocks the primary workflow.
