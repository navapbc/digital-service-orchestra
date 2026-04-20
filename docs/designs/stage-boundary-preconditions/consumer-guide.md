# Stage-Boundary PRECONDITIONS Consumer Guide

## Overview

This guide explains how to read PRECONDITIONS events as a downstream consumer. Consumers
include skills, agents, and scripts that need to verify upstream stage claims.

---

## `_read_latest_preconditions()` API

The primary read API resolves the latest PRECONDITIONS event for a (ticket, stage) pair:

```bash
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/preconditions-validator-lib.sh"
_read_latest_preconditions --ticket-id "$TICKET_ID" --stage "sprint"
```

Returns:
- `0` on success — JSON printed to stdout
- `2` when no event exists for this (ticket, stage) pair — empty output, non-blocking

**Selection rule**: latest = highest `timestamp` value per `(gate_name, session_id, worktree_id)`.
Ties broken by lexicographic sort on filename (descending).

---

## Snapshot Format (`PRECONDITIONS-SNAPSHOT.json`)

After epic closure, a compacted snapshot is written:

```
<ticket-dir>/PRECONDITIONS-SNAPSHOT.json
```

The snapshot is a merged view of all events, with LWW applied per composite key. Readers
MUST handle both flat event files and the snapshot format:

```bash
# Prefer snapshot if it exists; fall back to flat events
if [ -f "$TICKET_DIR/PRECONDITIONS-SNAPSHOT.json" ]; then
    jq '.' "$TICKET_DIR/PRECONDITIONS-SNAPSHOT.json"
else
    _read_latest_preconditions --ticket-id "$TICKET_ID" --stage "$STAGE"
fi
```

---

## LWW Policy (Last-Write-Wins)

For `gate_verdicts` with composite key `<gate_name>:<session_id>:<worktree_id>`:

- Multiple events may exist for the same composite key
- The event with the highest `timestamp` wins
- The snapshot applies LWW at write time — readers do not need to re-apply it

---

## `harvest-worktree.sh` Integration

`harvest-worktree.sh` copies PRECONDITIONS events from the worktree ticket directory to
the session branch during worktree merge. It does not filter or modify events — all events
are transferred verbatim. The session branch accumulates events from all worktrees.

Attestation: `harvest-worktree.sh` writes a `harvest-attestation.json` entry noting the
PRECONDITIONS event count transferred. See `contracts/harvest-attestation-format.md`.

---

## `merge-to-main.sh` Integration

In the archive phase, `merge-to-main.sh` triggers compaction for any tickets that were
closed during the sprint. Compaction:

1. Reads all flat `<ts>-<uuid>-PRECONDITIONS.json` files for the ticket
2. Applies LWW per composite key
3. Writes `PRECONDITIONS-SNAPSHOT.json` atomically (rename swap)
4. Retries once on transient file-not-found (concurrent write race)

**Ordering invariant**: the epic-closure validator runs **before** compaction. This ensures
the validator reads full event history, not the compacted snapshot.

---

## `ticket_reducer` API

The ticket reducer at `plugins/dso/scripts/ticket-reducer.sh` exposes PRECONDITIONS events
via the standard event stream. Consumers using the reducer API get PRECONDITIONS events
alongside COMMENT, TRANSITION, and other event types.

```bash
"$REPO_ROOT/.claude/scripts/dso" ticket-reducer.sh show "$TICKET_ID" \
  --event-type PRECONDITIONS
```

---

## Legacy-Ticket Graceful Degrade

For tickets created before the PRECONDITIONS system was introduced:

- `_read_latest_preconditions()` returns exit code `2` (no event found)
- Consumers treat `2` as "no preconditions to validate" and proceed
- The epic-closure validator skips PRECONDITIONS checks for legacy tickets silently
- No `[DSO WARN]` is emitted for legacy tickets (expected absence)
