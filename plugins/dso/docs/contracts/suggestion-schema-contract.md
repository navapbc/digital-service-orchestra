# Contract: Suggestion Schema and Orphan-Branch Isolation

- Status: accepted
- Scope: suggestion-capture (epic 6cd2-da08)
- Date: 2026-04-09

## Purpose

This document defines the JSON schema for suggestion records written by `suggestion-record.sh`, the file naming convention, and the orphan-branch isolation invariant. Downstream consumers (retro synthesis, retro-gather.sh, stop hook integration, PostToolUse hook integration) **must** conform to this contract.

---

## Storage Location

```
.tickets-tracker/.suggestions/<filename>.json
```

- **Branch**: `tickets` orphan branch (same worktree as `.tickets-tracker/`)
- **Directory**: `.tickets-tracker/.suggestions/` (hidden directory — starts with `.`)
- **Isolation invariant**: `.suggestions/` starts with `.`, so `ticket-reducer.py`'s `reduce_all_tickets()` batch mode skips it automatically (hidden-dir exclusion: `entry.startswith(".")`). Suggestion records **never** appear in `ticket list` or `ticket health` output.
- **Creation**: `suggestion-record.sh` creates `.suggestions/` on first use (`mkdir -p`). No pre-creation required.

---

## File Naming Convention

```
<timestamp_ms>-<session-id-prefix>-<uuid>.json
```

| Component | Description |
|-----------|-------------|
| `timestamp_ms` | Unix epoch in milliseconds (13 digits) at write time |
| `session-id-prefix` | First 8 alphanumeric characters of the session ID (disambiguates parallel sessions) |
| `uuid` | Full UUID v4 (prevents collision when concurrent sub-agents write at the same millisecond) |

Example: `1775750392123-a1b2c3d4-550e8400-e29b-41d4-a716-446655440000.json`

Files sort lexicographically in chronological order (timestamp-first).

---

## JSON Schema

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `schema_version` | integer | Schema version — currently `1` |
| `timestamp` | integer | Unix epoch in **milliseconds** at write time |
| `session_id` | string | Session identifier (full UUID or `CLAUDE_SESSION_ID` value) |
| `source` | string | Origin of this suggestion. Enumerated values: `"stop-hook"`, `"post-bash-hook"`, `"agent"`, `"manual"`, `"retro-gather"`. Free-form strings are accepted but discouraged. |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `observation` | string | **Objective** description of what happened (what was measured, what occurred). Should be free of recommendations. |
| `recommendation` | string | **Subjective** description of what to change or improve. Should be actionable. |
| `skill_name` | string | The DSO skill that was active when this suggestion was captured (e.g., `"dso:sprint"`, `"dso:fix-bug"`). |
| `affected_file` | string | Path (relative to repo root) of the file most relevant to this suggestion. |
| `metrics` | object | Numeric performance metrics. No fixed schema — consumers must tolerate unknown keys. Common keys: `wall_clock_s` (float), `tokens` (integer), `token_budget` (integer). |

### Example

```json
{
  "schema_version": 1,
  "timestamp": 1775750392123,
  "session_id": "550e8400-e29b-41d4-a716-446655440000",
  "source": "stop-hook",
  "observation": "sprint Phase 5 (red test writing) took 47s wall-clock for a 3-task batch",
  "recommendation": "cap red-test-writer dispatch to 2 parallel agents on haiku when batch size < 5",
  "skill_name": "dso:sprint",
  "affected_file": "plugins/dso/skills/sprint/SKILL.md",
  "metrics": {
    "wall_clock_s": 47.2,
    "tokens": 8400,
    "token_budget": 10000
  }
}
```

---

## Immutability Invariant

Suggestion files are **immutable after creation**. Once written and committed, a suggestion file must never be modified or deleted. Corrections are made by writing a new suggestion record.

---

## Flock Serialization

`suggestion-record.sh` uses `_flock_stage_commit` from `ticket-lib.sh`, acquiring the shared lock at:

```
.tickets-tracker/.ticket-write.lock
```

This is the **same lock** used by ticket write operations. All writes from parallel sessions are serialized. See `ticket-flock-contract.md` for timeout budget and retry behavior.

### Lock parameters

| Parameter | Value |
|-----------|-------|
| Lock file | `.tickets-tracker/.ticket-write.lock` |
| Timeout per attempt | `$SUGGESTION_LOCK_TIMEOUT` (default: 30s) |
| Max retries | 2 |
| Worst-case total wait | 60s |

---

## gc.auto=0 Guard

`suggestion-record.sh` sets `gc.auto=0` in the tickets worktree config (idempotent) before each write, following the same pattern as `ticket-lib.sh`. This prevents Git GC from contending with the write lock during the tool-call timeout ceiling.

---

## Downstream Consumer Obligations

### retro-gather.sh (Story 5)

Must read suggestion files from `.tickets-tracker/.suggestions/` sorted by filename (lexicographic = chronological). Must tolerate unknown optional fields gracefully (forward-compatible). Must not modify or delete suggestion files.

### Stop hook integration (Story 3)

Must call `suggestion-record.sh` with `--source "stop-hook"`. May pass `--session-id "$CLAUDE_SESSION_ID"` if available.

### PostToolUse hook integration (Story 4)

Must call `suggestion-record.sh` with `--source "post-bash-hook"`. Must tolerate write failures gracefully (best-effort capture, never block the tool call).
