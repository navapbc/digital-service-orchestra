# Ticket CLI Reference

Authoritative reference for all commands in the event-sourced ticket system.

## Overview

The ticket system CLI entry point:

| Entry point | Purpose |
|---|---|
| `ticket <subcommand>` | Event-sourced ticket system (dispatcher at `plugins/dso/scripts/ticket`) — adds Jira sync, dependency trees, and human-friendly output |

Source of truth for each subcommand is in `plugins/dso/scripts/ticket-*.sh` and `plugins/dso/scripts/ticket-*.py`. The dispatcher at `plugins/dso/scripts/ticket` routes all subcommands to those implementation scripts.

The ticket tracker is stored as an orphan git branch (`tickets`) mounted as a worktree at `.tickets-tracker/`. Each ticket is a directory containing append-only JSON event files. The compiled state is produced on-demand by the reducer (`ticket-reducer.py`).

---

## Output Formats

### Default JSON output

`.claude/scripts/dso ticket show` and `.claude/scripts/dso ticket list` produce pretty-printed JSON by default.

**`.claude/scripts/dso ticket show` default output** — one JSON object per ticket:

```json
{
  "ticket_id": "ab12-cd34",
  "ticket_type": "task",
  "title": "Fix login redirect",
  "status": "open",
  "author": "Alice",
  "parent_id": "",
  "created_at": 1711123200,
  "env_id": "550e8400-e29b-41d4-a716-446655440000",
  "comments": [],
  "deps": []
}
```

**`.claude/scripts/dso ticket list` default output** — JSON array of the same objects.

### `--format=llm` output mode

Both `.claude/scripts/dso ticket show` and `.claude/scripts/dso ticket list` accept `--format=llm`.

`.claude/scripts/dso ticket show --format=llm` outputs a single minified JSON object on one line.
`.claude/scripts/dso ticket list --format=llm` outputs JSONL — one minified object per line, one ticket per line.

Key differences from default output:

- Keys are shortened (see table below)
- `created_at` and `env_id` are omitted
- `null` values are omitted
- Empty lists are omitted
- Comment timestamps are omitted

**Key mapping:**

| Full key | LLM key |
|---|---|
| `ticket_id` | `id` |
| `ticket_type` | `t` |
| `title` | `ttl` |
| `status` | `st` |
| `author` | `au` |
| `parent_id` | `pid` |
| `comments` | `cm` |
| `deps` | `dp` |
| `conflicts` | `cf` |

**Comment sub-keys:** `body` → `b`, `author` → `au` (timestamp omitted)
**Dep sub-keys:** `target_id` → `tid`, `relation` → `r` (link_uuid omitted)

**Example — `.claude/scripts/dso ticket show --format=llm abc1-def2`:**

```
{"id":"abc1-def2","t":"task","ttl":"Fix login redirect","st":"open","au":"Alice"}
```

---

## Subcommands

### `init`

Initialize the ticket system.

```
.claude/scripts/dso ticket init [--silent]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--silent` | No | Suppress output on success or if already initialized |

**Behavior:**

- Creates an orphan `tickets` branch and mounts it as a worktree at `.tickets-tracker/`
- Idempotent: exits 0 if the system is already initialized
- In a git worktree session, creates a symlink to the main repo's `.tickets-tracker/` instead of creating a new worktree
- Writes `.gitignore` to the tickets branch (excludes `.env-id` and `.state-cache`)
- Generates a UUID4 env-id at `.tickets-tracker/.env-id`
- Sets `gc.auto=0` on the tickets worktree
- Acquires an exclusive lock (30s timeout) during branch creation to prevent concurrent init races

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Initialized successfully (or already initialized) |
| `1` | Not inside a git repository, lock timeout, or branch creation failure |

**Example:**

```
$ .claude/scripts/dso ticket init
Ticket system initialized.
```

---

### `create`

Create a new ticket.

```
.claude/scripts/dso ticket create <ticket_type> <title> [--parent <id>] [--priority <n>] [--assignee <name>]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_type` | Yes | One of: `bug`, `epic`, `story`, `task` |
| `title` | Yes | Non-empty title string (≤ 255 characters for Jira sync compatibility) |
| `--parent` | No | ID of an existing parent ticket |
| `--priority` | No | Priority 0-4 (0=critical, 4=backlog; default: 2) |
| `--assignee` | No | Assignee name (default: git config user.name) |

**Output:** Prints the generated ticket ID to stdout (e.g., `ab12-cd34`). No other output on success.

**Behavior:**

- Generates a collision-resistant 8-character ID (format: `xxxx-xxxx`) derived from a UUID4
- Validates that `--parent` ticket exists and has a CREATE event before writing
- Writes a `CREATE` event JSON file to `.tickets-tracker/<ticket_id>/`
- Commits the event atomically to the tickets branch
- The new ticket has status `open` by default

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Ticket created; ticket ID printed to stdout |
| `1` | Invalid type, empty title, parent not found, or git commit failure |

**Example:**

```
$ .claude/scripts/dso ticket create task "Add rate limiting to API"
w21-a3f7

$ .claude/scripts/dso ticket create story "As a user, I can reset my password" --parent w21-a3f7
w21-b9c2
```

---

### `show`

Show compiled state for a ticket.

```
.claude/scripts/dso ticket show [--format=llm] <ticket_id>
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_id` | Yes | The ticket ID to display |
| `--format=llm` | No | Minified single-line JSON with shortened keys (see Output Formats section) |

**Output:** Compiled ticket state as JSON to stdout. Unresolved bridge alerts produce a warning on stderr.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Ticket state printed to stdout |
| `1` | Ticket not found, or ticket has no CREATE event |

**Example:**

```
$ .claude/scripts/dso ticket show w21-a3f7
{
  "ticket_id": "w21-a3f7",
  "ticket_type": "task",
  "title": "Add rate limiting to API",
  "status": "open",
  "author": "Alice",
  "parent_id": "",
  "created_at": 1711123200,
  "env_id": "550e8400-...",
  "comments": [],
  "deps": []
}

$ .claude/scripts/dso ticket show --format=llm w21-a3f7
{"id":"w21-a3f7","t":"task","ttl":"Add rate limiting to API","st":"open","au":"Alice"}
```

---

### `list`

List all tickets.

```
.claude/scripts/dso ticket list [--format=llm] [--include-archived]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--format=llm` | No | JSONL output — one minified ticket per line (see Output Formats section) |
| `--include-archived` | No | Include archived tickets in output (default: archived tickets are excluded) |

**Output:** Default: a JSON array of compiled ticket state objects. `--format=llm`: JSONL, one object per line.

**Behavior:**

- Runs the reducer on every ticket directory in `.tickets-tracker/`
- Hidden directories (names starting with `.`) are skipped
- Archived tickets are excluded by default; pass `--include-archived` to include them
- Tickets that fail to reduce produce an error-state entry: `{"ticket_id": "...", "status": "error", "error": "reducer_failed"}`; these are included in the output array rather than causing an early exit
- Aggregate unresolved bridge alert count is emitted to stderr if non-zero

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Array (or JSONL lines) printed to stdout |
| `1` | Tracker directory not found (system not initialized) |

**Example:**

```
$ .claude/scripts/dso ticket list
[{"ticket_id":"w21-a3f7","ticket_type":"task","title":"Add rate limiting to API","status":"open",...}]

$ .claude/scripts/dso ticket list --format=llm
{"id":"w21-a3f7","t":"task","ttl":"Add rate limiting to API","st":"open","au":"Alice"}
{"id":"w21-b9c2","t":"story","ttl":"As a user, I can reset my password","st":"open","au":"Alice"}
```

---

### `transition`

Transition a ticket's status with optimistic concurrency control.

```
.claude/scripts/dso ticket transition <ticket_id> <current_status> <target_status> [--reason <text>]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_id` | Yes | The ticket to transition |
| `current_status` | Yes | Status the caller believes the ticket is currently in |
| `target_status` | Yes | Status to move the ticket to |
| `--reason <text>` | Conditional | Required when closing a bug ticket. Must start with `Fixed:` or `Escalated to user:`. |

**Allowed status values:** `open`, `in_progress`, `closed`, `blocked`

**Behavior:**

- Optimistic concurrency: reads the actual current status inside an `fcntl.flock` lock and compares it to `current_status`. If they differ (another process changed the ticket since the caller last read it), exits non-zero with a conflict error.
- Idempotent: if `current_status == target_status`, exits 0 immediately with "No transition needed".
- Ghost-prevention: verifies the ticket directory and CREATE event exist before acquiring the lock.
- Bug-close guard: when `target_status=closed` and the ticket type is `bug`, `--reason` is required and must begin with `Fixed:` or `Escalated to user:`. Exits non-zero if missing or malformed.
- Open-children guard: when `target_status=closed`, checks for open (non-closed) child tickets. Exits non-zero listing the open children if any are found.
- On close (`target_status=closed`): runs `ticket-unblock.py` to detect newly unblocked tickets and prints `UNBLOCKED: <ids>` (or `UNBLOCKED: none`) to stdout.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Transition committed (or no-op if already at target status) |
| `1` | Ticket not found, invalid status value, concurrency rejection, lock timeout, or git failure |

**Example:**

```
$ .claude/scripts/dso ticket transition w21-a3f7 open in_progress
UNBLOCKED: none

$ .claude/scripts/dso ticket transition w21-a3f7 open closed
Error: current status is "in_progress", not "open"

# Closing a bug ticket requires --reason
$ .claude/scripts/dso ticket transition w21-b1c2 open closed
Error: closing a bug ticket requires --reason with prefix "Fixed:" or "Escalated to user:"

$ .claude/scripts/dso ticket transition w21-b1c2 open closed --reason "Fixed: corrected null check in parser"
UNBLOCKED: none
```

---

### `comment`

Append a comment to a ticket.

```
.claude/scripts/dso ticket comment <ticket_id> <body>
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_id` | Yes | The ticket to comment on |
| `body` | Yes | Non-empty comment text |

**Behavior:**

- Ghost prevention: verifies CREATE event exists before writing COMMENT event
- Writes a `COMMENT` event JSON file and commits it atomically to the tickets branch
- Comment timestamp uses nanosecond precision (`time.time_ns()`)
- Comments are surfaced in `.claude/scripts/dso ticket show` output under the `comments` array

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Comment committed |
| `1` | Ticket not found, empty body, or git commit failure |

**Example:**

```
$ .claude/scripts/dso ticket comment w21-a3f7 "Rate limiting implementation started. Using token bucket algorithm."
```

---

### `link`

Link two tickets with a directional relationship.

```
.claude/scripts/dso ticket link <source_id> <target_id> <relation>
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `source_id` | Yes | The ticket the link originates from |
| `target_id` | Yes | The ticket the link points to |
| `relation` | Yes | One of: `blocks`, `depends_on`, `relates_to` |

**Behavior:**

- Routes to `ticket-graph.py --link` (not `ticket-link.sh`) to perform cycle detection in the same atomic operation as the link write
- Validates that both tickets exist before writing
- Cycle detection: adding a link that would create a cycle in `blocks`/`depends_on` relations is rejected with an error; `relates_to` never creates cycles
- Idempotent: if a net-active LINK with the same `(target_id, relation)` already exists in `source_id`'s directory, the call is a no-op (exits 0)
- `relates_to`: writes reciprocal LINK events in both `source_id` and `target_id` directories
- Writes a `LINK` event JSON file and commits it to the tickets branch

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Link created (or already existed — no-op) |
| `1` | Either ticket not found, invalid relation, or would create a cycle |

**Example:**

```
$ .claude/scripts/dso ticket link w21-a3f7 w21-b9c2 blocks
$ .claude/scripts/dso ticket link w21-b9c2 w21-c0d1 depends_on
$ .claude/scripts/dso ticket link w21-a3f7 w21-e5f6 relates_to
```

---

### `unlink`

Remove a link between two tickets.

```
.claude/scripts/dso ticket unlink <source_id> <target_id>
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `source_id` | Yes | The ticket the link originates from |
| `target_id` | Yes | The ticket the link points to |

**Behavior:**

- Routes to `ticket-link.sh unlink` (not `ticket-graph.py`)
- Replays LINK and UNLINK events chronologically to compute the net-effective link state before writing
- Looks up the most recent net-active LINK from `source_id` to `target_id` to find the link UUID
- Writes an `UNLINK` event that references the original LINK event's UUID (`data.link_uuid`) so the cancellation is traceable
- `relates_to` links: automatically writes a reciprocal UNLINK in `target_id`'s directory
- Exits non-zero if no active link exists between the two tickets

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | UNLINK event committed |
| `1` | Either ticket not found, no active link exists, or git commit failure |

**Example:**

```
$ .claude/scripts/dso ticket unlink w21-a3f7 w21-b9c2
```

---

### `deps`

Show the dependency graph for a ticket.

```
.claude/scripts/dso ticket deps <ticket_id> [--tickets-dir=<path>] [--include-archived]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_id` | Yes | The ticket whose dependency graph to show |
| `--tickets-dir=<path>` | No | Override the tracker directory (defaults to `.tickets-tracker/`) |
| `--include-archived` | No | Include archived tickets in the dep graph (default: archived tickets are excluded) |

**Output:** JSON object with the following fields:

```json
{
  "ticket_id": "w21-a3f7",
  "deps": [
    {"target_id": "w21-b9c2", "relation": "blocks"}
  ],
  "blockers": ["w21-c0d1"],
  "ready_to_work": false
}
```

| Field | Description |
|---|---|
| `deps` | Raw dep entries from the ticket's compiled state (relations stored in this ticket's directory) |
| `blockers` | Direct blocker ticket IDs (tickets that must close before this one can proceed) |
| `ready_to_work` | `true` when all direct blockers are `closed` or tombstoned |

**Behavior:**

- Archived tickets are excluded from the dep graph by default; pass `--include-archived` to include them
- If the queried ticket itself is archived, the command exits with an error unless `--include-archived` is passed: `Error: ticket '<id>' is archived. Use --include-archived to include archived tickets.`
- Uses a graph cache keyed by content hash of all ticket directories to avoid redundant reducer calls on repeated queries
- Tombstone-aware: archived/tombstoned tickets count as closed for `ready_to_work` computation
- Blockers include: tickets with a `depends_on` relation stored in this ticket's directory, and tickets with a `blocks` relation targeting this ticket stored in their own directory

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | JSON dep graph printed to stdout |
| `1` | Ticket not found or ticket is archived (without `--include-archived`) |

**Example:**

```
$ .claude/scripts/dso ticket deps w21-a3f7
{"ticket_id":"w21-a3f7","deps":[{"target_id":"w21-b9c2","relation":"blocks"}],"blockers":[],"ready_to_work":true}

$ .claude/scripts/dso ticket deps w21-a3f7 --include-archived
{"ticket_id":"w21-a3f7","deps":[{"target_id":"w21-b9c2","relation":"blocks"}],"blockers":[],"ready_to_work":true}
```

---

### `sync`

Synchronize tickets with Jira (via the ticket CLI).

```
.claude/scripts/dso ticket sync [--check] [--include-closed] [--force-local] [--no-lock] [--break-lock] [--lock-timeout=N] [--full]
```

`sync` is a ticket CLI command (not a `ticket` dispatcher subcommand). It requires `acli` (Atlassian CLI) in `PATH` and Jira credentials configured (`JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN`).

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--check` | No | Dry-run: report what would sync without making changes |
| `--include-closed` | No | Include closed tickets in the sync pass |
| `--force-local` | No | Accept local state as authoritative on conflict |
| `--no-lock` | No | Skip the sync lock (use with caution) |
| `--break-lock` | No | Break a stale sync lock and exit (mutually exclusive with `--check`) |
| `--lock-timeout=N` | No | Override the default lock acquisition timeout in seconds |
| `--full` | No | Force a full sync (re-examine all tickets, not just changed ones) |

**Behavior:**

- Incremental by default: only processes tickets that have changed since the last sync
- `--full` forces re-examination of all tickets
- Conflict detection: a conflict is raised when both the local ticket and the Jira issue have changed since the last sync
- `--force-local` resolves conflicts by accepting the local state as authoritative

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Sync completed successfully |
| `1` | `acli` not found, Jira credentials missing, or sync error |

**Example:**

```
$ .claude/scripts/dso ticket sync
$ .claude/scripts/dso ticket sync --check
$ .claude/scripts/dso ticket sync --full
```

---

### `archive`

Archive a ticket's event history using snapshot compaction (`.claude/scripts/dso ticket compact`).

```
.claude/scripts/dso ticket compact <ticket_id> [--threshold=N]
```

The compaction operation archives a ticket's raw event history into a single `SNAPSHOT` event, reducing the number of files on the tickets branch. The term "archive" in the event-sourced system refers to this compaction process; it is distinct from the move-to-archive-directory operation used by the legacy markdown ticket system.

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_id` | Yes | The ticket to compact |
| `--threshold=N` | No | Minimum event count before compaction runs (default: `COMPACT_THRESHOLD` env var, or `10`) |

**Behavior:**

1. Runs `.claude/scripts/dso ticket sync` before compacting to pull the latest remote state (gracefully skipped if sync is unavailable)
2. Skips compaction if a remote `SNAPSHOT` file already exists (to avoid redundant snapshots)
3. Checks event count against threshold — skips if below threshold
4. Runs the reducer to compile the current state
5. Acquires `fcntl.flock` for the entire write+delete+commit pipeline
6. Writes a `SNAPSHOT` event containing `compiled_state` and `source_event_uuids`
7. Deletes only the specific event files that were read into the snapshot
8. Commits all changes atomically with a single `ticket: COMPACT <ticket_id>` commit

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Compaction completed (or skipped — below threshold, remote snapshot exists, or already compacted) |
| `1` | Ticket not found, reducer failed, sync failed, or git commit failure |

**Example:**

```
$ .claude/scripts/dso ticket compact w21-a3f7
compacted 15 events into SNAPSHOT for w21-a3f7

$ .claude/scripts/dso ticket compact w21-a3f7 --threshold=5
below threshold (3 <= 5) — skipping compaction
```

---

### `bridge-status`

Show the status of the last bridge (Jira sync) run.

```
.claude/scripts/dso ticket bridge-status [--format=json]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--format=json` | No | Output raw JSON from the status file plus computed `unresolved_alerts_count` |

**Status file:** `.tickets-tracker/.bridge-status.json`

**Default output fields:**

```
Last run time:            1711123200
Status:                   success
Unresolved conflicts:     0
Unresolved BRIDGE_ALERTs: 2
```

**`--format=json` output:**

```json
{
  "last_run_timestamp": 1711123200,
  "success": true,
  "error": null,
  "unresolved_conflicts": 0,
  "unresolved_alerts_count": 2
}
```

**Behavior:**

- Reads `.bridge-status.json` written by `bridge-inbound.py` / `bridge-outbound.py` at the end of each bridge run
- Scans all ticket directories to count unresolved `BRIDGE_ALERT` events (those without a matching resolution event)
- Exits non-zero if the status file does not exist (bridge has not run yet)

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Status displayed |
| `1` | Status file not found |

**Example:**

```
$ .claude/scripts/dso ticket bridge-status
Last run time:            1711123200
Status:                   success
Unresolved conflicts:     0
Unresolved BRIDGE_ALERTs: 0

$ .claude/scripts/dso ticket bridge-status --format=json
{"last_run_timestamp":1711123200,"success":true,"error":null,"unresolved_conflicts":0,"unresolved_alerts_count":0}
```

---

### `bridge-fsck`

Audit bridge mappings for anomalies.

```
.claude/scripts/dso ticket bridge-fsck [--tickets-tracker=<path>] [--now-ts=<epoch>]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--tickets-tracker=<path>` | No | Override the tracker directory path (defaults to `TICKETS_TRACKER_DIR` env var or `<repo-root>/.tickets-tracker`) |
| `--now-ts=<epoch>` | No | Override the current timestamp for stale detection (UTC epoch seconds; intended for testing) |

**Output:** Human-readable audit report printed to stdout.

**Checks performed:**

| Check | Description |
|---|---|
| Orphaned mappings | A `SYNC` event exists for a ticket with no `CREATE` event — the mapping has no local counterpart |
| Duplicate Jira mappings | Multiple tickets share the same `jira_key` |
| Stale SYNC events | The most recent `SYNC` event is older than 30 days and there are no `BRIDGE_ALERT` events after it |

**Example output:**

```
=== Bridge FSck Report ===
Orphans: none found
Duplicates: none found
Stale SYNCs: 1

--- Stale SYNC Events ---
  stale_sync: ticket=w21-a3f7 jira_key=DSO-42 last_sync_ts=1706745600
```

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | No issues found |
| `1` | One or more issues found |

**Example:**

```
$ .claude/scripts/dso ticket bridge-fsck
=== Bridge FSck Report ===
Orphans: none found
Duplicates: none found
Stale SYNCs: none found

No issues found.

$ .claude/scripts/dso ticket bridge-fsck --tickets-tracker=/path/to/tracker
```

---

### `ticket-benchmark.sh`

Benchmark the ticket list or close command against a seeded ticket system.

```
plugins/dso/scripts/ticket-benchmark.sh [-n <count>] [--threshold <seconds>] [--mode=list|close]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `-n <count>` | No | Number of tickets to seed (default: `300`; `0` = use existing repo tickets) |
| `--threshold <seconds>` | No | Max acceptable wall-clock time in seconds. Defaults: `3s` for n≤300, `10s` for n≤1000, `30s` for n>1000 (list mode); `10s` (close mode) |
| `--mode=list\|close` | No | Benchmark mode (default: `list`). `list` measures `ticket list` wall-clock time. `close` seeds a mixed population and measures `ticket transition open→closed`. |

**Behavior:**

- When run without `-n` (or with `-n 0`) inside a repo with an initialized ticket system, benchmarks the existing tickets
- Otherwise creates a temporary git repo, seeds N tickets, and benchmarks that
- `close` mode seeds a mix of open, in-progress, and archived tickets, then measures a single `ticket transition open→closed` including all `batch_close_operations` work

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Elapsed time was below the threshold |
| `1` | Elapsed time exceeded the threshold |
| `2` | Invalid arguments |

**Output:**

```
Elapsed: X.XXs for N tickets                                        (list mode)
Elapsed: X.XXs for closing ticket with N non-archived tickets in tracker  (close mode)
```

**Example:**

```
$ plugins/dso/scripts/ticket-benchmark.sh --mode=list -n 300
Elapsed: 1.23s for 300 tickets

$ plugins/dso/scripts/ticket-benchmark.sh --mode=close -n 100
Elapsed: 0.87s for closing ticket with 100 non-archived tickets in tracker
```

---

## Environment Variables

| Variable | Used by | Description |
|---|---|---|
| `TICKETS_TRACKER_DIR` | `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket list`, `.claude/scripts/dso ticket bridge-status`, `.claude/scripts/dso ticket bridge-fsck` | Override the tracker directory (used in tests) |
| `COMPACT_THRESHOLD` | `.claude/scripts/dso ticket compact` | Default event count threshold for compaction (default: `10`) |
| `TICKET_SYNC_CMD` | `.claude/scripts/dso ticket compact` | Override the sync command run before compact (default: `.claude/scripts/dso ticket sync`) |
| `DSO_UNBLOCK_SCRIPT` | `.claude/scripts/dso ticket transition` | Override the path to `ticket-unblock.py` |
| `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN` | `.claude/scripts/dso ticket sync` | Jira credentials for sync |
| `JIRA_SYNC_TIMEOUT_SECONDS` | `.claude/scripts/dso ticket sync` | Override the sync lock timeout |

---

## Event Types

The ticket system is append-only. All mutations write a new event JSON file. The reducer replays events in lexicographic (chronological) filename order to produce compiled state.

| Event type | Written by | Description |
|---|---|---|
| `CREATE` | `.claude/scripts/dso ticket create` | Creates the ticket with type, title, and optional parent |
| `STATUS` | `.claude/scripts/dso ticket transition` | Changes ticket status (open, in_progress, closed, blocked) |
| `COMMENT` | `.claude/scripts/dso ticket comment` | Appends a comment |
| `LINK` | `.claude/scripts/dso ticket link` | Creates a directional relationship to another ticket |
| `UNLINK` | `.claude/scripts/dso ticket unlink` | Cancels a prior LINK event (references the original LINK UUID) |
| `SNAPSHOT` | `.claude/scripts/dso ticket compact` | Compacts event history; replaces prior events with compiled state |
| `SYNC` | bridge scripts | Records a Jira synchronization mapping (`jira_key`) |
| `BRIDGE_ALERT` | bridge scripts | Records a bridge anomaly; may include a resolution event |

---

## Common Workflows

**Create a bug and transition to in-progress:**

```bash
id=$(.claude/scripts/dso ticket create bug "Login fails on mobile Safari")
.claude/scripts/dso ticket transition "$id" open in_progress
```

**Link a task as a dependency of a story:**

```bash
.claude/scripts/dso ticket link w21-story depends_on w21-task
# Now w21-story is blocked until w21-task is closed
```

**Check if a ticket is ready to work:**

```bash
.claude/scripts/dso ticket deps w21-story | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['ready_to_work'])"
```

**List all tickets in LLM-friendly format:**

```bash
.claude/scripts/dso ticket list --format=llm
```

**Compact a ticket after heavy editing:**

```bash
.claude/scripts/dso ticket compact w21-a3f7 --threshold=20
```

**Audit bridge health after a sync run:**

```bash
.claude/scripts/dso ticket bridge-status
.claude/scripts/dso ticket bridge-fsck
```
