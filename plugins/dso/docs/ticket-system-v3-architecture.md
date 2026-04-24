# Ticket System v3: Operational Architecture Guide

- Status: current
- Scope: ticket-system-v3 (epic w21-ablv and follow-on epics)
- Date: 2026-03-22

This document is a high-level operational guide for the event-sourced ticket system. It consolidates topics deferred from Epics 1–3 and covers per-story contracts for the system. This guide focuses on **how to operate and call** the system.

---

## Storage Layout

### Tracker Directory Structure

The tracker lives at `.tickets-tracker/` in the repository root. It is a git worktree mounted on the `tickets` orphan branch — a branch with no shared history with `main` or any feature branch.

```
.tickets-tracker/
  <ticket-id>/
    <timestamp>-<uuid>-<TYPE>.json   # event files, committed to tickets branch
    .cache.json                       # compiled-state cache, gitignored on tickets branch
  .env-id                             # UUID4 environment identity, gitignored
  .ticket-write.lock                  # global write-serialization lock file
  .git                                # worktree git file (points to shared object store)
  .gitignore                          # excludes .env-id and .cache.json from tickets branch
```

`.tickets-tracker/` is listed in `.git/info/exclude` so it never appears in `git status` on the main branch. It is **not** in `.gitignore` (which is committed), because it is machine-local state.

### Ticket Directory Layout

Each ticket lives in its own subdirectory named by its local ID (e.g., `dso-9aq2/`). The directory contains only append-only event files and the compiled-state cache. Event files are committed to the `tickets` branch; the cache file is gitignored.

### Event File Naming Convention

```
<timestamp>-<uuid>-<TYPE>.json
```

| Component     | Format                                                          |
|---------------|-----------------------------------------------------------------|
| `<timestamp>` | UTC epoch seconds (integer), unpadded (10 digits since 2001-09-09) |
| `<uuid>`      | Lowercase UUID4, hyphens preserved                              |
| `<TYPE>`      | Uppercase event type: `CREATE`, `STATUS`, `COMMENT`, `LINK`, `UNLINK`, `SNAPSHOT`, or `SYNC` |

Example: `1742605200-3f2a1b4c-5e6d-7f8a-9b0c-1d2e3f4a5b6c-CREATE.json`

The timestamp prefix guarantees that lexicographic filename sort equals chronological sort. Any reducer must sort filenames explicitly and must never rely on `readdir` order.

For the complete event file JSON schema (base fields and per-type `data` payloads), see `docs/contracts/ticket-event-format.md`.

### How the Reducer Assembles State from Event Files

The reducer performs two passes over the sorted event file list:

1. **Pass 1 — SNAPSHOT scan**: Finds the latest `SNAPSHOT` event (if any) and records its `source_event_uuids`. All events before the snapshot index are skipped in Pass 2.
2. **Pass 2 — Replay**: Starting from the snapshot index, each event is applied in order. Events whose UUID appears in `source_event_uuids` are skipped (they are already baked into the snapshot). Unknown event types are silently ignored for forward compatibility.

The sort key for event files is a three-tuple `(timestamp_segment, event_type_order, full_basename)`. `LINK` events sort before `UNLINK` events at the same timestamp to ensure links are always applied before their cancellations.

---

## Reducer Usage

### CLI Invocation

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/ticket-reducer.py <ticket_dir_path> # shim-exempt: direct python invocation of internal script, not a shim-wrapped command
```

Prints the compiled ticket state as a single-line JSON object to stdout. Exits non-zero for corrupt or ghost tickets.

Examples:

```bash
# Compile a specific ticket
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/ticket-reducer.py .tickets-tracker/dso-9aq2 # shim-exempt: direct python invocation of internal script

# Pipe to jq for pretty-printing
python3 ${CLAUDE_PLUGIN_ROOT}/scripts/ticket-reducer.py .tickets-tracker/dso-9aq2 | jq . # shim-exempt: direct python invocation of internal script
```

### Public Module Interface: `reduce_ticket()`

The reducer is a standalone Python module. Tests and other callers import it directly without spawning a subprocess:

```python
import importlib, importlib.util, pathlib

# Load module (hyphenated filename requires importlib)
spec = importlib.util.spec_from_file_location(
    "ticket_reducer",
    pathlib.Path("${CLAUDE_PLUGIN_ROOT}/scripts/ticket-reducer.py"),  # shim-exempt: Python importlib path to internal module
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

state = mod.reduce_ticket("/path/to/.tickets-tracker/dso-9aq2")
```

#### Signature

```python
def reduce_ticket(
    ticket_dir_path: str | os.PathLike[str],
    strategy: ReducerStrategy | None = None,
) -> dict | None:
```

#### Return Values

| Condition | Return value |
|-----------|-------------|
| Normal ticket with CREATE event | `dict` of compiled state (see fields below) |
| No event files in directory | `None` |
| Event files present but no parseable CREATE event | `dict` with `{"status": "error", "error": "no_valid_create_event", "ticket_id": ...}` |
| CREATE event present but missing required fields | `dict` with `{"status": "fsck_needed", "error": "corrupt_create_event", "ticket_id": ...}` |

Error-state dicts always have exactly three keys: `{status, error, ticket_id}`.

#### Compiled State Fields

| Field          | Type     | Description                                      |
|----------------|----------|--------------------------------------------------|
| `ticket_id`    | str      | Directory name (e.g., `dso-9aq2`)               |
| `ticket_type`  | str      | `bug`, `epic`, `story`, or `task`                |
| `title`        | str      | Ticket title from CREATE event                   |
| `status`       | str      | Current status: `open`, `in_progress`, `closed`, `blocked` |
| `author`       | str      | `git user.name` from CREATE event                |
| `created_at`   | int      | UTC epoch seconds of CREATE event                |
| `env_id`       | str      | UUID4 environment ID from CREATE event           |
| `parent_id`    | str\|None | Parent ticket ID, or None                       |
| `comments`     | list     | List of `{body, author, timestamp}` dicts        |
| `deps`         | list     | List of `{target_id, relation, link_uuid}` dicts |
| `bridge_alerts`| list     | List of bridge alert dicts (Epic 3 feature)      |
| `reverts`      | list     | List of revert record dicts                      |
| `conflicts`    | list     | Optimistic concurrency conflicts (if any)        |

#### State Cache

`reduce_ticket()` maintains a `.cache.json` file in each ticket directory. The cache key is a SHA-256 hash of `filename:size` pairs for all event files. On cache hit (hash matches), the cached state is returned without reading event files. On cache miss, all events are replayed and the cache is atomically written via `os.rename()`.

The cache is gitignored on the `tickets` branch and is never committed.

#### `strategy` Parameter

The optional `strategy` parameter accepts a `ReducerStrategy`-compatible object for the sync-events merge path. Callers that do not pass a strategy get `LastTimestampWinsStrategy` by default (dedup by UUID, sort ascending by timestamp). See `docs/contracts/ticket-reducer-strategy-contract.md` for the full interface contract.

---

## `.archived` Marker Contract

### Purpose

The `.archived` marker is an empty sentinel file (`<ticket-dir>/.archived`) that allows `reduce_all_tickets()` to skip archived tickets without parsing any event files. Reducing a ticket with 16,000+ event files across thousands of tickets is expensive; the marker makes exclusion an O(1) stat check.

### Writers

Two code paths create the `.archived` marker:

1. **`ticket-lifecycle.sh`** — written immediately after the `ARCHIVED` event file is committed to the `tickets` branch. Writing is error-tolerant: a failure degrades the ticket to the slow (event-replay) path rather than aborting the archive operation.
2. **`ticket-archive-markers-backfill.sh`** — a one-shot migration script that backfills the marker for all tickets that are in a net-archived state (at least one `ARCHIVED` event with no subsequent `REVERT` event cancelling it) but that predate the marker convention. It uses the same `write_marker()` logic as `ticket_reducer.marker.write_marker`.

### When the Marker Is Written

Both writers apply the same sequencing rule: the marker is created **after** the ARCHIVED event file is durably written and committed to the `tickets` branch. This ensures that a process that reads the marker can always find the corresponding event in the event log.

### Marker I/O API

The canonical API is `ticket_reducer.marker` (`scripts/ticket_reducer/marker.py`):

| Function | Description |
|----------|-------------|
| `write_marker(ticket_dir)` | Creates `<ticket_dir>/.archived` under an exclusive per-ticket `fcntl.flock` on `<ticket_dir>/.write.lock`. Idempotent (open with `'a'`). On `OSError`: logs warning to stderr, returns without raising. |
| `remove_marker(ticket_dir)` | Removes `<ticket_dir>/.archived` under the same exclusive lock. Idempotent (ignores `FileNotFoundError`). On `OSError`: logs warning to stderr. |
| `check_marker(ticket_dir)` | Returns `True` if `<ticket_dir>/.archived` exists, `False` otherwise. No locking needed — existence checks are naturally consistent. |

The per-ticket lock file (`.write.lock`) is separate from the global `.ticket-write.lock` used for event writes. This allows marker operations to proceed without contending on the global write serializer.

### Read Path: `reduce_all_tickets()` Fast-Skip

`reduce_all_tickets(tracker_dir, exclude_archived=True)` uses the marker as a fast-skip gate before event replay:

```python
if exclude_archived and os.path.exists(os.path.join(entry_path, ".archived")):
    continue   # skip without reading any event files
```

After event replay, a secondary filter removes any ticket whose reduced state has `archived=True` but whose marker was absent when scanned. This two-layer approach ensures correctness even when the marker is slightly behind the event log.

### Orphan Marker Behavior

An orphan marker is a `.archived` file that is present in a ticket directory but whose corresponding `ARCHIVED` event has been cancelled by a subsequent `REVERT` event (net-archived state is false). When `reduce_all_tickets()` is called with `exclude_archived=True` and encounters a stale `.archived` marker, it calls `_is_net_archived()` to confirm the net archival state. If `_is_net_archived()` returns `False` (all ARCHIVED events are cancelled), the marker is removed via `remove_marker()` and the ticket falls through to the slow path (event replay), returning its correct active state.

To audit marker state across all tickets, run `archive-markers-backfill --dry-run`. To manually remove a specific orphan marker, use `remove_marker()` from `ticket_reducer.marker`.

### `compute_dir_hash()` Marker Extension

`compute_dir_hash()` in `scripts/ticket_reducer/_cache.py` appends a `marker:present` or `marker:absent` sentinel to the hash input. This means that writing or removing the `.archived` marker invalidates the ticket's `.cache.json`, forcing a full re-reduction on the next read. Without this extension, a ticket archived after its cache was primed would return stale (non-archived) state from cache.

---

## Flock Contract Summary

### What the Write Lock Protects

`.tickets-tracker/.ticket-write.lock` is a single global lock file that serializes **all** ticket write operations across all concurrent writers, regardless of which ticket is being written. This prevents index corruption from simultaneous writes on different tickets.

The operations performed while holding the lock are:
1. Atomic rename of staging temp file to final event path (`os.rename()`)
2. `git -C .tickets-tracker add <ticket-id>/<filename>`
3. `git -C .tickets-tracker commit -q -m "ticket: <TYPE> <id>"`

### Timeout Budget

| Parameter        | Value      |
|------------------|------------|
| Per-attempt timeout | 30 seconds |
| Max retries       | 2          |
| Worst-case total  | 60 seconds |

The 60-second worst case is intentionally below the ~73-second Claude tool-call timeout ceiling, leaving ~13 seconds of headroom for the rename and git operations inside the lock.

The lock uses Python `fcntl.flock(LOCK_EX | LOCK_NB)` polled at 100 ms intervals. This is portable across macOS and Linux.

### Recovery Path

| Exit code | Meaning | Action |
|-----------|---------|--------|
| 0 | Lock acquired, write succeeded | None |
| 1 | Lock not acquired within 30s | Retry (up to 2 times); on exhaustion, command exits with `flock: could not acquire lock after 60s` |
| 2 | git operation failed while holding lock | No retry; command exits non-zero |
| 3 | Atomic rename failed while holding lock | Staging temp removed; no retry; command exits non-zero |

On lock exhaustion, the staging temp is removed. No partial state is left on disk. A half-written event that survived a rename but failed git commit is recoverable by `.claude/scripts/dso ticket fsck`.

For the full lock contract including downstream story obligations (compaction, concurrency stress, sync-events), see `docs/contracts/ticket-flock-contract.md`.

---

## Worktree Integration

### How Multi-Agent Sessions Share the Tracker

The `tickets` branch is mounted as a worktree at `.tickets-tracker/` in the **main** repository checkout. When a new code worktree is created (e.g., `git worktree add ../feature-branch feature`), .claude/scripts/dso ticket init creates a **symlink** in the new worktree that points to the main repo's `.tickets-tracker/`:

```bash
# What ticket-init.sh does in a secondary worktree
ln -s <main-repo-root>/.tickets-tracker <worktree-root>/.tickets-tracker
```

Because the symlink resolves to the same physical directory, all worktrees share the same tracker state in real time — no commit or push is needed for ticket changes to be visible across local worktrees. The flock lock (`ticket-write.lock`) provides write serialization across all worktrees sharing the same `.tickets-tracker/`.

### Initialization

Run once per repository clone:

```bash
.claude/scripts/dso ticket-init.sh
```

For a secondary worktree, run the same command from inside the worktree. `ticket-init.sh` detects that `.git` is a file (worktree marker) and creates the symlink instead of mounting a new worktree.

`ticket-init.sh` is idempotent: if `.tickets-tracker/` already exists and is valid (real worktree or correct symlink), it exits 0 immediately.

### gc.auto=0 Safety Setting

`ticket-init.sh` sets `gc.auto=0` in the tickets worktree's local git config (`.tickets-tracker/.git/config`) only — never in the host repository config or the global `~/.gitconfig`. The `write_commit_event` function in `ticket-lib.sh` re-applies this setting idempotently before each write, so even worktrees that did not run `.claude/scripts/dso ticket init` directly have GC disabled before their first write.

This prevents git's automatic garbage collection from holding repository locks during the ~60-second flock window.

### Pushing and Pulling Ticket State

To share tickets between machines or environments:

```bash
# Push local ticket commits to remote tickets branch
git -C .tickets-tracker push origin tickets

# Pull remote ticket commits from remote tickets branch
git -C .tickets-tracker fetch origin tickets
git -C .tickets-tracker rebase origin/tickets
```

`.claude/scripts/dso ticket sync` automates this as a split-phase protocol (fetch → merge under lock → push), ensuring the write lock is never held during network I/O. See `docs/contracts/ticket-sync-events-contract.md`.

---

## --format=llm Design Rationale

The `--format=llm` flag on `.claude/scripts/dso ticket show` and `.claude/scripts/dso ticket list` exists to minimize token overhead when agents read ticket state. The standard (human) output format includes verbose timestamps, null fields, and long key names — all of which consume context window tokens without providing information useful to an agent.

The LLM format applies three transformations:

1. **Key shortening**: Long field names are mapped to abbreviated equivalents (e.g., `ticket_id` → `id`, `ticket_type` → `t`, `title` → `ttl`). See `scripts/ticket_reducer/llm_format.py` for the full key map. # shim-exempt: internal implementation path reference
2. **Null and empty-list stripping**: Fields with `null` values or empty lists are omitted entirely. A ticket with no dependencies produces no `deps` key in LLM output.
3. **Timestamp omission**: `created_at` and `env_id` are omitted (`OMIT_KEYS` in `ticket_reducer/llm_format.py`). Comment timestamps are also omitted — agents care about comment content, not when it was written.

The formatting logic lives in `scripts/ticket_reducer/llm_format.py` (`to_llm()` function) and is shared by both `ticket-show.sh` and `ticket-list.sh`. # shim-exempt: internal implementation path reference Callers import it as a regular package module (`from ticket_reducer.llm_format import to_llm`) — no `importlib` dance is needed.

`.claude/scripts/dso ticket list --format=llm` outputs JSON Lines (one minified JSON object per line) rather than a JSON array, so agents can stream and filter with standard Unix tools without loading the full array into memory.

---

## Multi-Environment Sync Behavior

Ticket sync between environments (e.g., local machine and CI, or two developer machines) uses the `tickets` orphan branch as the shared transport. Each environment pushes and pulls the `tickets` branch independently of the main code branch.

Because event files are append-only and named with timestamp + UUID, concurrent pushes from two environments always produce distinct filenames. `git merge` on the `tickets` branch is always a fast-forward or a trivially auto-resolvable merge — no textual merge conflicts arise between event files.

Conflict detection is handled at the **semantic** level by the reducer, not at the git level:

- **STATUS conflicts**: If two environments independently transition a ticket to different statuses, the reducer detects the mismatch via the `current_status` field in each STATUS event (optimistic concurrency proof). Conflicts are recorded in `state["conflicts"]` and surfaced by `.claude/scripts/dso ticket fsck`.
- **Deduplication**: The `LastTimestampWinsStrategy` deduplicates events by UUID (first occurrence wins) and sorts by timestamp. This handles the case where the same event file appears in both environments' histories after a sync.

For multi-environment conflict resolution strategy (`MostStatusEventsWinsStrategy`), see `docs/contracts/ticket-reducer-strategy-contract.md`.

---

## Bash-Native Dispatch Architecture

### Overview

Starting with the bash-native dispatcher, all ticket CLI subcommand calls are routed through a sourced bash library (`ticket-lib-api.sh`) rather than spawning a Python subprocess per operation. This section documents the key components of that architecture.

### ticket-lib-api.sh

`ticket-lib-api.sh` is the sourceable bash library that implements all ticket operations (create, transition, comment, tag, link, etc.). It is **sourced** (not exec'd) into the current bash process via:

```bash
source "${_PLUGIN_ROOT}/scripts/ticket-lib-api.sh"
```

A source-time guard at the top of the file (`declare -f _ticketlib_dispatch` check) prevents double-sourcing if the library is pulled in from multiple callers in the same shell process — re-sourcing returns immediately if `_ticketlib_dispatch` is already defined. Because the library runs in-process, there is no subprocess overhead per ticket operation.

### _ticketlib_dispatch

`_ticketlib_dispatch` is a subshell wrapper that provides caller-environment isolation:

```bash
( source ticket-lib-api.sh && _ticketlib_dispatch <op> <args...> )
```

The subshell captures all library state (functions, variables set during source) inside a forked child process. When the subshell exits, none of the library's internal variables or function definitions leak back into the caller's shell environment. This isolation keeps the ticket CLI composable in complex shell pipelines without side effects.

### _ticketlib_has_flock

`_ticketlib_has_flock` is a boolean flag set at source time (not at call time):

```bash
if command -v flock >/dev/null 2>&1; then
    _ticketlib_has_flock=1
else
    _ticketlib_has_flock=0
fi
```

The library uses this flag at every write operation to select the locking path:

- **`_ticketlib_has_flock=1`**: uses `flock(1)` for exclusive write serialization (see Flock Contract Summary above)
- **`_ticketlib_has_flock=0`**: falls back to a best-effort advisory lock (acceptable for single-session use; multi-agent concurrency requires `flock(1)`)

`flock(1)` is present on all supported platforms (Linux via `util-linux`; macOS via `brew install util-linux`). The fallback path exists for edge cases (minimal CI containers, custom Docker images).

### Dispatcher Shift: exec → source

The ticket CLI dispatcher was changed from **exec** (spawning a `python3` subprocess per op) to **source** (bash-native library call). The full dispatch path is now:

```
.claude/scripts/dso ticket <op>  →  ticket-lib-api.sh  →  bash function
```

Benefits of the shift:
- No `python3` startup cost per operation (meaningful in batch sessions with hundreds of ticket ops)
- Lock state is shared within the same process (no inter-process flock hand-off)
- Simpler error propagation (bash `set -e` / `return` instead of subprocess exit codes piped through wrappers)

**Rollback**: `DSO_TICKET_LEGACY=1` restores the old exec path (legacy per-op `.sh` subprocess scripts) for debugging or rollback. See `CLAUDE.md` for the sunset schedule.

---

## Tag Policy

### Guarded Tags

| Tag | Guard | Writer |
|-----|-------|--------|
| `brainstorm:complete` | Requires `### Planning Intelligence Log` heading in ticket events (enforced by `_tag_add_checked` in `ticket-lib.sh`) | `/dso:brainstorm` via `.claude/scripts/dso ticket tag` |

Explicitly removable via `.claude/scripts/dso ticket untag`.

### Unguarded Tags

All other tags (e.g., `scrutiny:pending`, `interaction:deferred`, `design:approved`, `design:awaiting_import`, `design:pending_review`) are unguarded. Policy errs toward flexibility — guards are added only when incorrect application causes irreversible harm.

### Writer Taxonomy

**Additive writes** (single-tag operations):
- CLI: `.claude/scripts/dso ticket tag <id> <tag>` and `.claude/scripts/dso ticket untag <id> <tag>`
- Library: `_tag_add` / `_tag_remove` in `ticket-lib.sh`

**Full-replacement writes** (replaces entire tags array):
- CLI: `ticket edit --tags=<json-array>`
- Reserved for: migration script (`ticket-migrate-brainstorm-tags.sh`) and direct tag array resets

Concurrent-writer race between additive and full-replacement writes is accepted — same tolerance as pre-existing full-replacement behavior.

### Accepted Limitations

- **Concurrent-writer race**: two simultaneous additive tag operations can produce a last-writer-wins outcome. Accepted given low concurrency in practice.
- **Source enforcement infeasible**: "only skill X may write tag Y" cannot be enforced at the CLI level. Policy is documented here for reference; enforcement relies on skill instructions.
