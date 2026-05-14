# .debug-active Marker Schema

## Purpose

The `.debug-active` marker is a session-scoped file created by `/dso:debug-everything` Phase B Step 1 when `merge.strategy=pr` (ci-pr mode). It:

- Enables merge-only enforcement on the session worktree (`check-session-merge-only.sh`)
- Identifies the active debug session for correlation (PreToolUse hook — S10, future consumer)
- Signals to Phase A entry that a prior session may require stale cleanup

## File Location

```text
$REPO_ROOT/.debug-active
```

This path is gitignored (scope: session worktree only).

## Format

Text file, one `key=value` per line:

```text
debug-session-id=<value>
schema_version=<value>
```

## Fields

| Field | Type | Example | Description |
|-------|------|---------|-------------|
| `debug-session-id` | string | `20260512-141045-a3f9c2` | UTC timestamp + 6-char random suffix: `YYYYMMDD-HHMMSS-<6char>` |
| `schema_version` | integer | `1` | Schema version; current value is `1` |

### `debug-session-id` Format

```text
YYYYMMDD-HHMMSS-<6-char-random>
```

Example: `20260512-141045-a3f9c2`

The timestamp is UTC. The 6-char random suffix distinguishes concurrent sessions on the same date/time.

## Stale Detection

A marker is **STALE** when:

1. The timestamp embedded in `debug-session-id` is older than the TTL (default: 24h, configurable via `debug.session_ttl_hours` config key), OR
2. No live process matches the session (implementation note: Phase A uses timestamp-only check for simplicity)

## Pre-Upgrade Pattern

Markers without a `schema_version` field (or `schema_version < 1`) are pre-upgrade in-flight sessions. Phase A must refuse ci-pr operations for these and instruct the user to restart the debug session explicitly.

## Lifecycle

| Event | Actor |
|-------|-------|
| **Created** | Phase B Step 1 when `merge.strategy=pr` |
| **Removed** | Phase K before shutdown |
| **Stale cleanup** | Phase A entry before GHA pre-scan |

## Consumers

| Consumer | Usage |
|----------|-------|
| `check-session-merge-only.sh` | Reads presence of `.debug-active` file only; does NOT parse fields |
| S10 PreToolUse hook | Reads `debug-session-id` field for session correlation (future consumer) |
