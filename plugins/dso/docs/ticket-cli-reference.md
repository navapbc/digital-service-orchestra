# Ticket CLI Reference

Authoritative reference for all commands in the event-sourced ticket system.

## Overview

The ticket system CLI entry point:

| Entry point | Purpose |
|---|---|
| `ticket <subcommand>` | Event-sourced ticket system (dispatcher at `scripts/ticket`) — adds Jira sync, dependency trees, and human-friendly output | # shim-exempt: internal implementation path in table

Source of truth for each subcommand is in `scripts/ticket-*.sh` and `scripts/ticket-*.py`. # shim-exempt: internal implementation paths The dispatcher at `scripts/ticket` routes all subcommands to those implementation scripts. # shim-exempt: internal implementation path reference

The ticket tracker is stored as an orphan git branch (`tickets`) mounted as a worktree at `.tickets-tracker/`. Each ticket is a directory containing append-only JSON event files. The compiled state is produced on-demand by the reducer (`ticket-reducer.py`). # tickets-boundary-ok

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

- Creates an orphan `tickets` branch and mounts it as a worktree at `.tickets-tracker/` # tickets-boundary-ok
- Idempotent: exits 0 if the system is already initialized
- In a git worktree session, creates a symlink to the main repo's `.tickets-tracker/` instead of creating a new worktree # tickets-boundary-ok
- Writes `.gitignore` to the tickets branch (excludes `.env-id` and `.state-cache`)
- Generates a UUID4 env-id at `.tickets-tracker/.env-id` # tickets-boundary-ok
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
.claude/scripts/dso ticket create <ticket_type> <title> [--parent <id>] [--priority/-p <n>] [--assignee <name>] [-d/--description <text>] [--tags <tag1,tag2>]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_type` | Yes | One of: `bug`, `epic`, `story`, `task` |
| `title` | Yes | Non-empty title string (≤ 255 characters for Jira sync compatibility) |
| `--parent` | No | ID of an existing parent ticket |
| `--priority`, `-p` | No | Priority 0-4 (0=critical, 4=backlog; default: 2) |
| `--assignee` | No | Assignee name (default: git config user.name) |
| `-d`, `--description` | No | Optional long-form description text for the ticket |
| `--tags` | No | Comma-separated list of tags to attach to the ticket at creation time (e.g., `CLI_user`) |

**Output:** Prints the generated ticket ID to stdout (e.g., `ab12-cd34`). No other output on success.

**Behavior:**

- Generates a collision-resistant 8-character ID (format: `xxxx-xxxx`) derived from a UUID4
- Validates that `--parent` ticket exists and has a CREATE event before writing
- Writes a `CREATE` event JSON file to `.tickets-tracker/<ticket_id>/` # tickets-boundary-ok
- Commits the event atomically to the tickets branch
- The new ticket has status `open` by default
- Tags are stored as a list on the ticket; use --tags to set them atomically at creation time.

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

$ .claude/scripts/dso ticket create bug "Login fails on mobile Safari" -d "Reproducible on iOS 17 with Safari 17. Steps: 1) Open login page, 2) Enter credentials, 3) Tap Sign In — redirects to blank page instead of dashboard."
w21-c3d4

$ .claude/scripts/dso ticket create bug "User reported: Login fails on mobile" --tags CLI_user
ab12-cd34
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
.claude/scripts/dso ticket list [--type=<type>] [--status=<status>] [--format=llm] [--include-archived]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--type=<type>` | No | Filter by ticket type: `epic`, `story`, `task`, `bug` |
| `--status=<status>` | No | Filter by status: `open`, `in_progress`, `closed`, `blocked` |
| `--format=llm` | No | JSONL output — one minified ticket per line (see Output Formats section) |
| `--include-archived` | No | Include archived tickets in output (default: archived tickets are excluded) |

**Output:** Default: a JSON array of compiled ticket state objects. `--format=llm`: JSONL, one object per line.

**Behavior:**

- Runs the reducer on every ticket directory in `.tickets-tracker/` # tickets-boundary-ok
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

$ .claude/scripts/dso ticket list --type=bug --status=open
[{"ticket_id":"w21-c4d8","ticket_type":"bug","title":"Login fails on Safari","status":"open",...}]

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
| `--dry-run` | No | Preview the link operation without writing any event; prints what would happen (promotion, rejection, or creation) and exits 0 |

**Behavior:**

- Routes to `ticket-graph.py --link` (not `ticket-link.sh`) to perform cycle detection in the same atomic operation as the link write
- Validates that both tickets exist before writing
- Cycle detection: adding a link that would create a cycle in `blocks`/`depends_on` relations is rejected with an error; `relates_to` never creates cycles
- Idempotent: if a net-active LINK with the same `(target_id, relation)` already exists in `source_id`'s directory, the call is a no-op (exits 0)
- `relates_to`: writes reciprocal LINK events in both `source_id` and `target_id` directories
- Writes a `LINK` event JSON file and commits it to the tickets branch

#### Hierarchy Enforcement

When `ticket link` is called, the system resolves the effective link target based on the ticket hierarchy before writing any event.

**Promotion rules** (cross-boundary links are automatically elevated):

| Source | Target | Effective link written |
|--------|--------|----------------------|
| task in story-X | task in story-Y (different story, same epic) | story-X → story-Y |
| task/story in epic-A | task/story in epic-B (different epic) | epic-A → epic-B |
| story in epic-A | story in epic-A (same epic) | story → story (no promotion needed) |

**Rejection rules** (link is rejected with exit 1):

| Attempted link | Reason | Error message |
|----------------|--------|---------------|
| task → its own parent story | Redundant: parent already implies relationship | `redundant link: <task-id> is a direct child of <story-id>` |
| story → its own parent epic | Redundant: parent already implies relationship | `redundant link: <story-id> is a direct child of <epic-id>` |
| A → B where B already reaches A | Circular dependency | `cycle detected: adding <A> → <B> would create a cycle` |

**Before/after example:**

```bash
# Cross-story task link — automatically promoted:
$ .claude/scripts/dso ticket link task-sprint-001 task-sprint-002 depends_on
# task-sprint-001 belongs to story-auth; task-sprint-002 belongs to story-infra
# → Promoted: story-auth depends_on story-infra (LINK event written to story-auth's directory)

# Redundant link — rejected:
$ .claude/scripts/dso ticket link task-sprint-001 story-auth depends_on
# Error: redundant link: task-sprint-001 is a direct child of story-auth

# Preview with --dry-run:
$ .claude/scripts/dso ticket link task-sprint-001 task-sprint-002 depends_on --dry-run
# [DRY RUN] Would promote: story-auth depends_on story-infra (no event written)
```

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
| `--tickets-dir=<path>` | No | Override the tracker directory (defaults to `.tickets-tracker/`) | # tickets-boundary-ok
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

### `archive-markers-backfill`

Backfill `.archived` marker files for all existing tickets that are in a net-archived state but lack the marker file.

```
.claude/scripts/dso archive-markers-backfill [--dry-run] [--tracker-dir=PATH]
```

> **One-shot maintenance utility.** This script is not a ticket dispatcher subcommand — it is a standalone script. Run it directly via the shim:
>
> ```bash
> .claude/scripts/dso archive-markers-backfill [options]
> ```

**Purpose:**

The `.archived` marker file is a fast-path optimization used by `ticket-list.sh` and other tooling to skip archived tickets without parsing full event logs. Tickets archived before the marker convention was introduced do not have this file. This script backfills it in one pass, permanently switching those tickets to the fast-path exclusion check.

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--dry-run` | No | Report which tickets would receive markers without writing anything |
| `--tracker-dir=PATH` | No | Override the `TICKET_TRACKER_DIR` env var to point at a non-default tracker directory |
| `--help`, `-h` | No | Show built-in usage help |

**Behavior:**

- Scans all non-hidden ticket directories in the tracker directory
- Determines net archival state per ticket: a ticket is net archived when it has at least one `ARCHIVED` event whose UUID has not been cancelled by a subsequent `REVERT` event (`data.target_event_uuid` matches the `ARCHIVED` UUID)
- Skips tickets that already have a `.archived` marker file
- Writes the `.archived` marker file using `fcntl.flock` (per-ticket exclusive lock, 10 s timeout) — mirrors the contract of `ticket_reducer.marker.write_marker`
- Idempotent: safe to run multiple times; already-marked tickets are skipped

**When to run:**

| Scenario | Action |
|---|---|
| Initial deployment of the `.archived` marker convention | Run once after deploying the new `ticket-list.sh` |
| Markers fall out of sync (e.g., after manual ticket-branch surgery) | Run as a recovery step |
| Unsure whether all markers are present | Use `--dry-run` to check without writing |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Backfill completed (or dry-run preview printed) |
| `1` | Tracker directory not found, or unknown argument |

**Example:**

```
# Preview which tickets would receive markers (no writes):
$ .claude/scripts/dso archive-markers-backfill --dry-run
  would write: ab12-cd34/.archived
  would write: w21-a3f7/.archived
Dry-run — would write 2 markers, would skip 14 (already present)

# Write markers for real:
$ .claude/scripts/dso archive-markers-backfill
Wrote 2 markers, skipped 14 (already present)

# Target a non-default tracker directory:
$ .claude/scripts/dso archive-markers-backfill --tracker-dir=/tmp/test-tracker
Wrote 0 markers, skipped 0 (already present)
```

---

### `check-ac`

Check whether a ticket contains a structured Acceptance Criteria block.

```
.claude/scripts/dso ticket check-ac <ticket_id>
```

**Output:** `AC_CHECK: pass (<N> criteria lines)` or `AC_CHECK: fail - no ACCEPTANCE CRITERIA section in <id> (...)`

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | AC block found with ≥ 1 checklist items |
| `1` | AC block missing or empty |

---

### `clarity-check`

Score ticket clarity on a 0–10 scale and return a pass/fail verdict.

```
.claude/scripts/dso ticket clarity-check <ticket_id>
.claude/scripts/dso ticket clarity-check --stdin  # Read ticket JSON from stdin
```

**Output:** Single-line JSON: `{"score": <N>, "verdict": "pass"|"fail", "threshold": <N>}`

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Verdict is `pass` (score ≥ threshold) |
| `1` | Verdict is `fail` (score < threshold) |

---

### `classify`

Classify one or more tickets for routing (model, subagent, complexity, priority).

```
.claude/scripts/dso ticket classify <ticket_id> [<ticket_id> ...]
```

**Output:** JSON array — one object per ticket with fields: `id`, `model`, `subagent`, `class`, `complexity`, `priority`.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Classification succeeded |
| Non-zero | One or more tickets could not be classified |

---

### `purge-bridge`

Remove inbound bridge tickets whose project key does not match the specified project key.

```
.claude/scripts/dso ticket purge-bridge --keep=<PROJECT_KEY> [--dry-run]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--keep=<PROJECT_KEY>` | Yes | Jira project key to retain (e.g., `DSO`). All other `jira-*` tickets are deleted. |
| `--dry-run` | No | Show which tickets would be deleted without deleting |

**Safety:** Only deletes `jira-*` prefixed ticket directories. Never touches `dso-*`, `w20-*`, or other non-jira tickets.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Purge completed (or dry-run output shown) |
| `1` | Missing `--keep` argument or tracker directory not found |

---

### `quality-check`

Check whether a ticket has sufficient detail for issue-as-prompt agent dispatch.

```
.claude/scripts/dso ticket quality-check <ticket_id>
```

**Output:** `QUALITY: pass (<line_count> lines, <keyword_count> criteria, <ac_items> AC items, <file_impact> file impact)` or `QUALITY: fail - description too sparse (...)`

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Quality sufficient for issue-as-prompt dispatch |
| `1` | Too sparse; use inline prompt instead |

---

### `summary`

Produce a one-line summary per ticket including status and blocking information.

```
.claude/scripts/dso ticket summary <ticket_id> [<ticket_id> ...]
```

**Output:** One line per ticket: `<id> [<status>] <title> (blocked by: <ids>|ready)`

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Summary produced |
| `1` | No ticket IDs provided |

---

### `validate`

Validate ticket quality and completeness for sprint readiness.

```
.claude/scripts/dso ticket validate [<ticket_id> ...] [--json] [--terse]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `<ticket_id>` | No | One or more ticket IDs to validate. If omitted, validates all open tickets. |
| `--json` | No | Output results as JSON array |
| `--terse` | No | Short one-line output per ticket |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | All validated tickets score 5 (ready) |
| `1` | One or more tickets score 4 (minor issues) |
| `2` | One or more tickets score 3 (moderate issues) |
| `3` | One or more tickets score 2 (significant issues) |
| `4` | One or more tickets score 1 (incomplete) |

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

**Status file:** `.tickets-tracker/.bridge-status.json` # tickets-boundary-ok

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

## Environment Variables

| Variable | Used by | Description |
|---|---|---|
| `TICKETS_TRACKER_DIR` | `.claude/scripts/dso ticket show`, `.claude/scripts/dso ticket list`, `.claude/scripts/dso ticket bridge-status`, `.claude/scripts/dso ticket bridge-fsck` | Override the tracker directory (used in tests) |
| `COMPACT_THRESHOLD` | `.claude/scripts/dso ticket compact` | Default event count threshold for compaction (default: `10`) |
| `TICKET_SYNC_CMD` | `.claude/scripts/dso ticket compact` | Override the sync command run before compact (default: `.claude/scripts/dso ticket sync`) |
| `DSO_UNBLOCK_SCRIPT` | `.claude/scripts/dso ticket transition` | Override the path to `ticket-unblock.py` |
| `JIRA_URL`, `JIRA_USER`, `JIRA_API_TOKEN` | `.claude/scripts/dso ticket sync` | Jira credentials for sync |
| `JIRA_SYNC_TIMEOUT_SECONDS` | `.claude/scripts/dso ticket sync` | Override the sync lock timeout |
| `DSO_TICKET_LEGACY` | `.claude/scripts/dso ticket` dispatcher | Set to `1` to route all ticket ops to legacy per-op `.sh` subprocess scripts instead of `ticket-lib-api.sh`. See [Sourceable Library API](#sourceable-library-api) and [Troubleshooting](#troubleshooting). |

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

---

### `exists`

O(1) presence check for a ticket in the tracker.

```
.claude/scripts/dso ticket exists <ticket_id>
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_id` | Yes | The ticket ID to check |

**Behavior:**

- Checks for a `*-CREATE.json` OR `*-SNAPSHOT.json` event file in the ticket directory. SNAPSHOT files are produced by `ticket compact` — so compacted tickets are correctly detected as present.
- Does not invoke the reducer — this is a filesystem-level check only.
- Respects `TICKETS_TRACKER_DIR` for tracker directory override (no git subprocess when set).

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Ticket exists (CREATE or SNAPSHOT event found) |
| `1` | Ticket does not exist, or no ticket ID provided |

**Example:**

```
$ .claude/scripts/dso ticket exists abc1-def2
$ echo $?
0
```

---

### `list-epics`

List open epics, optionally including blocked ones.

```
.claude/scripts/dso ticket list-epics [--all] [--min-children=N] [--max-children=N] [--has-tag=TAG] [--without-tag=TAG]
```

Canonical implementation. `sprint-list-epics.sh` is the thin delegate. # tickets-boundary-ok

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--all` | No | Include BLOCKED epics in output (prefixed with `BLOCKED\t`) |
| `--min-children=N` | No | Only show epics with at least N children |
| `--max-children=N` | No | Only show epics with at most N children |
| `--has-tag=TAG` | No | Only show epics with the specified tag |
| `--without-tag=TAG` | No | Exclude epics with the specified tag |

**Output:** Tab-separated lines, one per eligible epic:

```
<id>\tP*\t<title>\t<child_count>[\tBLOCKING]       # in-progress epics
<id>\tP<priority>\t<title>\t<child_count>[\tBLOCKING]  # unblocked open epics
BLOCKED\t<id>\tP<priority>\t<title>\t<child_count>\t<blocker_ids>  # blocked (only with --all)
```

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | One or more eligible epics printed |
| `1` | No open epics exist |
| `2` | All open epics are blocked (regardless of `--all`; `--all` controls whether blocked epics are printed, not the exit code) |

---

### `list-descendants`

BFS walk from a root ticket, bucketed by ticket type.

```
.claude/scripts/dso ticket list-descendants <ticket_id>
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `ticket_id` | Yes | The root ticket ID to walk from |

**Output:** JSON object with descendant IDs grouped by type:

```json
{
  "epics":               ["id", ...],
  "stories":             ["id", ...],
  "tasks":               ["id", ...],
  "bugs":                ["id", ...],
  "parents_with_children": ["id", ...]
}
```

| Field | Description |
|---|---|
| `epics` / `stories` / `tasks` / `bugs` | Descendant IDs of each type (root excluded) |
| `parents_with_children` | IDs of tickets in the traversal that themselves have children (includes root when it has children) |

**Behavior:**

- All arrays are empty when the root has no descendants or when the root does not exist in the tracker.
- Uses `reduce_all_tickets` for bulk state loading; error and fsck_needed tickets are excluded.
- Cycle-safe: visited-set prevents infinite loops.

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | JSON printed to stdout (arrays may be empty) |
| `1` | No ticket ID provided (usage error) |

---

### `next-batch`

Select the next parallel agent batch for an epic.

```
.claude/scripts/dso ticket next-batch <epic_id> [--limit=N|unlimited] [--json]
```

Canonical implementation. `sprint-next-batch.sh` is the thin delegate. # tickets-boundary-ok

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `epic_id` | Yes | The epic to compute a batch for |
| `--limit=N` | No | Cap batch size at N tasks (default: unlimited) |
| `--limit=0` | No | Produce an empty batch (BATCH_SIZE: 0) |
| `--json` | No | Machine-readable JSON output (see below) |

**Text output lines:**

```
EPIC: <id>  <title>
AVAILABLE_POOL: <n>
BATCH_SIZE: <n>
TASK: <id>  P<priority>  <type>  <model>  <subagent>  <class>  <title>  [story:<id>]
SKIPPED_OVERLAP: <id>  deferred (overlaps with <other-id> on <file>)
SKIPPED_BLOCKED_STORY: <id>  deferred (parent story <story-id> is blocked)
SKIPPED_OPUS_CAP: <id>  deferred (opus cap reached)
SKIPPED_IN_PROGRESS: <id>  already in_progress
SKIPPED_NEEDS_PLANNING: <id>  needs implementation planning
```

**JSON output keys** (with `--json`):

| Key | Description |
|---|---|
| `epic_id` / `epic_title` | Epic identifier and title |
| `batch_size` / `available_pool` / `opus_cap` | Batch metrics |
| `batch` | Array of selected task objects |
| `skipped_overlap` / `skipped_blocked_story` / `skipped_opus_cap` | Arrays of deferred task objects |
| `skipped_in_progress` / `skipped_needs_planning` | Arrays of deferred task objects |

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Batch generated (BATCH_SIZE may be 0) |
| `1` | Epic not found or ticket CLI error |
| `2` | Usage error (no epic ID provided) |

---

### `ready`

List tickets that are ready to work (all blockers closed).

```
.claude/scripts/dso ticket ready [--epic=<id>] [--format=ids|llm]
```

**Arguments:**

| Argument | Required | Description |
|---|---|---|
| `--epic=<id>` | No | Limit results to direct children of this epic |
| `--format=ids` | No | One ticket ID per line (default) |
| `--format=llm` | No | One minified JSON object per line (JSONL, LLM-optimised) |

**Output:** By default (`--format=ids`), one ticket ID per line for all tickets where `ready_to_work=true`. With `--format=llm`, one minified JSON object per line (same compact schema as `ticket show --format=llm`).

**Behavior:**

- Scans all tickets via `reduce_all_tickets`; O(N) where N is total ticket count.
- A ticket is ready when: status is `open` or `in_progress`, AND all tickets it `depends_on` are `closed`.
- Handles asymmetric blocking: `depends_on` (X depends on Y → Y blocks X) and `blocks` (X blocks Y → X is blocker for Y).

**Exit codes:**

| Code | Meaning |
|---|---|
| `0` | Output printed (may be empty — including when tracker directory is absent) |
| `1` | Not inside a git repo and `TICKETS_TRACKER_DIR` is unset |
| `2` | Invalid argument (argparse error) |

---

## Sourceable Library API

The ticket dispatcher routes all subcommand calls through `ticket-lib-api.sh`, a bash-native sourced library. Scripts that need to call ticket operations in-process (without spawning a subprocess) can source this library directly.

### `_ticketlib_dispatch <op> <args...>`

Subshell wrapper for calling library functions. Each call runs `op` in a subshell so that per-call `set -e`, traps, and variable mutations cannot leak back into the caller's shell state.

```bash
# Source the library (idempotent — re-sourcing is a no-op)
source "$_PLUGIN_ROOT/scripts/ticket-lib-api.sh"

# Call a ticket operation in-process
_ticketlib_dispatch ticket_show --format=llm "$ticket_id"
```

### `_ticketlib_has_flock`

Detection variable set at source time (`0` or `1`). Indicates whether `flock(1)` is available on the current platform. Callers and internal functions branch on this to avoid repeated `command -v flock` calls.

```bash
source "$_PLUGIN_ROOT/scripts/ticket-lib-api.sh"
if [ "$_ticketlib_has_flock" = "1" ]; then
    echo "flock available — full concurrency protection enabled"
fi
```

### `DSO_TICKET_LEGACY=1` — Rollback to subprocess mode

Setting `DSO_TICKET_LEGACY=1` routes all ticket operations back to the legacy per-op `.sh` subprocess scripts instead of the in-process library functions. Use this flag when debugging a suspected regression in the bash-native path or when rolling back temporarily.

```bash
DSO_TICKET_LEGACY=1 .claude/scripts/dso ticket show "$ticket_id"
```

See [Troubleshooting](#troubleshooting) below for full details.

### Sourceability contract

Scripts that source `ticket-lib-api.sh` can rely on the following guarantees:

| Contract | Details |
|---|---|
| No `exit` at library scope | Library never calls `exit` at file scope — sourcing it cannot kill the caller |
| No `set -euo pipefail` at library scope | Strict mode is not enabled at file scope — it does not leak into the caller |
| No `trap` at file scope | Caller traps are not clobbered |
| No `GIT_*` mutation at source time | `GIT_DIR`, `GIT_INDEX_FILE`, `GIT_WORK_TREE`, and `GIT_COMMON_DIR` are not mutated at file scope |
| Functions use `return`, not `exit` | All library functions signal failure via `return <n>`, not `exit` |
| Idempotent source guard | Re-sourcing is a no-op (guarded by `declare -f _ticketlib_dispatch`) |

---

## Troubleshooting

### `DSO_TICKET_LEGACY=1` — Rollback flag for `_ensure_initialized`

**Syntax:**

```bash
DSO_TICKET_LEGACY=1 .claude/scripts/dso ticket <subcommand>
```

**Effect:**

Routes the `_ensure_initialized` function in the ticket dispatcher to the pre-refactor Python-backed path instead of the current bash-native implementation. All subcommands that call `_ensure_initialized` (e.g., `list`, `create`, `show`, `transition`) are affected.

**When to use:**

- On regression in the bash-native `_ensure_initialized` path (e.g., incorrect sync behavior, unexpected exits).
- When investigating a suspected performance bug introduced in the bash-native refactor.

Do not use this flag as a permanent workaround. File a bug ticket and reference the session where the regression was first observed.

**Observable behavior:**

When active, the dispatcher emits a notice to stderr before running initialization:

```
DSO_TICKET_LEGACY=1: using Python-backed _ensure_initialized path
```

This notice is intentional — it signals that the legacy path is active and should not be suppressed.

**Deprecation plan:**

`DSO_TICKET_LEGACY` is scheduled for removal after 2 stable plugin releases with no reported issues against the bash-native path. Once removed, setting this variable will have no effect.
