# ADR: Event-Sourced Ticket Storage on Orphan Branch

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-03-20

Technical Story: w21-ablv (ticket-system-v3 epic — initialize ticket system and create/view tickets via event-sourced storage)

## Context and Problem Statement

The current ticket system (the tk wrapper) stores ticket state as mutable Markdown files under `.tickets/`. This design has three compounding problems:

1. **Merge conflicts**: `.tickets/` files change in-place on each update. Concurrent writers (multiple Claude worktrees or agents) create unresolvable merge conflicts on the same file.
2. **Data loss on concurrent writes**: Without serialization, two simultaneous writes to the same ticket file produce a race condition where one write silently overwrites the other.
3. **Performance degradation with ticket count**: The `.tickets/` directory grows linearly with ticket count. Listing, searching, and syncing all require scanning the full directory.

The system needs an append-only storage model that: eliminates merge conflicts, serializes concurrent writes without blocking the writer indefinitely, and keeps the data structure in git (version-controlled, diff-able, auditable).

## Decision Drivers

- Concurrent writes from multiple worktrees or agents must never produce data loss or merge conflicts.
- The storage format must be version-controllable and inspectable with standard git tools.
- Write serialization must complete within the ~73-second Claude tool-call timeout ceiling.
- The reducer (read path) must be testable in isolation, independent of the shell layer.
- No new runtime dependencies beyond `python3` (already required) and standard `git`.
- The implementation must not affect the host repository's `.git` config or global git config.

## Decision

**Event-sourced append-only storage committed to a git orphan branch, mounted as `.tickets-tracker/` worktree.**

Each ticket write operation appends a new JSON event file to `.tickets-tracker/<ticket-id>/` and commits it to the `tickets` orphan branch. Concurrent writes are serialized by a Python `fcntl.flock` lock on `.tickets-tracker/.ticket-write.lock`. The current ticket state is derived by the `ticket-reducer.py` reducer, which reads and sorts all event files for a ticket and folds them into a state dict.

### Key implementation decisions

#### Orphan branch as storage medium

The `tickets` branch is an orphan branch — it shares no commit history with `main` or any feature branch. This means:
- Ticket data never appears in `git log` on the main branch.
- `git merge` on any non-tickets branch never touches ticket data.
- The orphan branch can be pushed to a remote independently for backup or sharing.

The branch is mounted as a worktree at `.tickets-tracker/` using `git worktree add`. This gives the tickets branch its own working directory without switching the main repository's HEAD. See `plugins/dso/scripts/ticket-init.sh`.

#### Event file naming: timestamp-uuid-TYPE

Event files follow the naming convention defined in `plugins/dso/docs/contracts/ticket-event-format.md`:

```
<timestamp>-<uuid>-<TYPE>.json
```

Lexicographic sort of filenames is equivalent to chronological sort because the timestamp prefix is currently 10 digits (UTC epoch seconds since 2001-09-09). This ordering guarantee lets any reducer sort by filename and reconstruct the exact event sequence without a database or index.

#### Python3 reducer for testable state compilation

The read path (`plugins/dso/scripts/ticket-reducer.py`) is a standalone Python module with a public `reduce_ticket(ticket_dir_path)` function. It reads all `*.json` event files in a ticket directory, sorts by filename, and folds them into a state dict.

Separating the reducer into a Python module (rather than inline shell logic) means:
- Unit tests can import and call `reduce_ticket()` directly without spawning a subprocess.
- The reducer has no dependency on shell state, git, or the flock layer.
- The module interface is stable across callers: `ticket-show.sh`, the caching layer (w21-f8tg), and `ticket fsck`.

#### flock serialization for atomic writes

All write operations acquire a global exclusive lock on `.tickets-tracker/.ticket-write.lock` before performing the rename + git operations. The lock is implemented via Python `fcntl.flock` (portable across macOS and Linux). A single global lock (not per-ticket) prevents index corruption from concurrent writers on different tickets.

The timeout budget (30s per attempt, 2 retries, 60s worst case) is intentionally within the ~73s Claude tool-call ceiling, leaving ~13s headroom for the rename and git operations performed while holding the lock. Full protocol in `plugins/dso/docs/contracts/ticket-flock-contract.md`.

#### Atomic rename before git commit

The staging temp file is created inside `.tickets-tracker/` (same filesystem as the final path) so that `os.rename()` is guaranteed atomic by POSIX. The rename occurs inside the flock critical section. If the rename succeeds but the subsequent `git commit` fails, the file is on-disk in the tracker directory but not committed — this is recoverable by `ticket fsck`. If the rename fails, the staging temp is removed and no partial state is left.

#### gc.auto=0 on the tickets worktree

Git's automatic garbage collection (`gc.auto`) can hold repository locks for seconds to minutes. A GC run triggered mid-write could exhaust the 60-second flock budget. `ticket-init.sh` sets `gc.auto=0` in the tickets worktree's local git config (`.tickets-tracker/.git/config`) only — never in the host repository or global git config. An idempotent guard in `write_commit_event` re-applies this setting before each write to handle worktrees mounted on machines that did not run `ticket init` directly.

## Consequences

### Positive consequences

- **No merge conflicts**: Event files are append-only. Two concurrent writers always produce two distinct filenames (different timestamps or UUIDs). `git merge` on the tickets branch is always a fast-forward.
- **Concurrent writes serialized safely**: The flock ensures only one writer performs rename + commit at a time. The 60-second worst-case wait is within the Claude tool-call timeout ceiling.
- **Testable reducer in isolation**: `ticket-reducer.py` has no shell or git dependencies. Unit tests call `reduce_ticket()` directly without a worktree or git repository.
- **Standard git tooling**: Ticket history is inspectable with `git log`, `git show`, and `git diff` on the `tickets` branch. No proprietary storage format.
- **gc.auto=0 prevents lock contention during Claude timeouts**: Automatic GC is disabled on the tickets worktree, eliminating the risk of GC holding repository locks during the flock window.
- **No new runtime dependencies**: The implementation uses `python3` (already required by the plugin), `fcntl` (stdlib), and standard git commands.

### Negative consequences

- **All reads require reducer compilation**: Every `ticket show` command must sort and fold all event files for a ticket. For tickets with many events this is O(n) over the event log. This is mitigated by the state cache (`.state-cache` per ticket directory) implemented in story w21-f8tg — the cache is invalidated by filename-based mtime comparison and bypassed when stale.
- **Orphan branch adds one git operation per write**: Each write incurs a `git commit` on the tickets worktree. This is faster than a full `git add -A` + `git commit` on the main branch, but slower than a pure filesystem write.
- **Lock file must exist before concurrent stress**: The lock file (`.tickets-tracker/.ticket-write.lock`) is created on first write. In race conditions at system initialization, two processes could attempt the first write simultaneously; `ticket-init.sh` uses a `mkdir`-based lock to serialize initialization itself.

## Alternatives Considered

### Direct `.tickets/` mutation (rejected)

The current system. Rejected because mutable files cause merge conflicts and race conditions that are inherent to the design, not fixable with tooling. Any two concurrent writers on the same ticket file will conflict.

### SQLite database (rejected)

A single SQLite database file would serialize writes via SQLite's WAL mode. Rejected because:
- Binary files are not git-friendly: diffs are unreadable, merge is impossible, and the file cannot be inspected with standard tools.
- SQLite WAL lock behavior on network filesystems (e.g., NFS-mounted worktrees) is unreliable.
- A corrupt database has no recovery path short of restoring from backup.

### Separate git repository (rejected)

A standalone `tickets.git` repository next to the project repository. Rejected because:
- Requires out-of-band repository management (cloning, authentication, remote setup) for each project.
- Adds operational overhead for every developer who clones the project.
- Makes CI access to ticket state non-trivial.
- An orphan branch in the same repository achieves the same isolation without a second repository.

## Implementation

This ADR is implemented across the following stories in epic w21-ablv:

| Story | Scope |
|-------|-------|
| w21-ablv | `ticket init`, `ticket create`, `ticket show` — core read/write pipeline |
| w21-o72z | Additional event types: STATUS, COMMENT, LINK |
| w21-f8tg | State cache for the reducer (`.state-cache` per ticket) |
| w21-q0nn | Compaction: SNAPSHOT events + deletion of original event files |

Prerequisite stories (data contracts, test gate, hook drift validation):

| Story | Scope |
|-------|-------|
| w21-1plz | `ticket-event-format.md` contract |
| w21-g3x6 | `ticket-flock-contract.md` contract |
| w21-6bmd | Test gate setup for host project |
| w21-ymip | Hook drift validation |

## Cross-Story Contracts

All stories that read or write event files must conform to:

- **`plugins/dso/docs/contracts/ticket-event-format.md`** — event file naming convention, directory layout, JSON base schema (`timestamp`, `uuid`, `event_type`, `env_id`, `author`, `data`), and reducer ordering guarantee (lexicographic sort = chronological sort).
- **`plugins/dso/docs/contracts/ticket-flock-contract.md`** — lock file location (`.tickets-tracker/.ticket-write.lock`), timeout budget (30s per attempt, 2 retries, 60s worst case), locking mechanism (Python `fcntl.flock` with `LOCK_EX | LOCK_NB` polled at 100 ms), exit code semantics, and downstream obligations for compaction (w21-q0nn) and concurrency stress test (w21-ay8w).

## Links

- Contracts: `plugins/dso/docs/contracts/ticket-event-format.md`, `plugins/dso/docs/contracts/ticket-flock-contract.md`
- Implementation: `plugins/dso/scripts/ticket-init.sh`, `plugins/dso/scripts/ticket-create.sh`, `plugins/dso/scripts/ticket-show.sh`, `plugins/dso/scripts/ticket-lib.sh`, `plugins/dso/scripts/ticket-reducer.py`
- Existing ADR example: `plugins/dso/docs/decisions/adr-config-system.md`
