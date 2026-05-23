---
name: review-stats
description: Use when the user asks about review metrics, review analytics, reviewer performance, the review dashboard, review trends, resolution rates, or how /dso:review has been performing over time. Runs review-stats.sh and displays its output as-is — reviewer tier distribution (light/standard/deep), autonomous resolution rates, severity-distribution trends, and time-bucketed counts. Trigger phrases include 'review stats', 'review metrics', 'review analytics', 'reviewer performance', 'review dashboard', 'how is review going', 'tier distribution'.
user-invocable: true
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Review Stats

Display aggregated statistics from the review event log.

## Usage

```
/dso:review-stats                        # Stats for the last 30 days (default)
/dso:review-stats --since=2026-03-01     # Stats since a specific date
/dso:review-stats --all                  # All recorded review events
/dso:review-stats --source=central <subcommand> [options]
                                         # Query central telemetry via query-stats.sh
```

### Arguments

| Flag | Description |
|------|-------------|
| `--since=YYYY-MM-DD` | Filter events on or after this date |
| `--all` | Include all recorded review events (no date filter) |
| `--source=central` | Route to central telemetry store via `query-stats.sh` |

Valid `--source` values: `central`. Any other value (e.g. `--source=bogus`, unknown source) is treated as invalid — the agent preserves default local-file behavior and does NOT invoke `query-stats.sh`.

## Execution

### Default behavior (no `--source` flag)

Run the review-stats CLI with any user-provided arguments:

```bash
.claude/scripts/dso review-stats.sh $ARGS
```

where `$ARGS` are the flags passed by the user (e.g., `--since=2026-03-01`, `--all`).

Present the script output to the user as-is.

**Important**: the default route (no `--source` flag) does NOT call `query-stats.sh`. It preserves the existing local-file behavior.

### `--source=central` routing

When the user passes `--source=central`, dispatch `query-stats.sh` with the remaining arguments and surface its stdout verbatim:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/query-stats.sh <subcommand> [options]
```

Supported subcommands (passed directly to `query-stats.sh`):

| Subcommand | Example | Description |
|------------|---------|-------------|
| `roundtrip` | `--source=central roundtrip` | Emit test event + poll S3 until it lands |
| `counts` | `--source=central counts --days=7` | Per-client event counts over N days |
| `recent` | `--source=central recent --days=7 --limit=20` | Most recent N events |
| `missing` | `--source=central missing --days=30` | Date-partition gaps in N-day window |
| `sizes` | `--source=central sizes --days=14` | Per-day object count + total bytes |

Surface `query-stats.sh` stdout to the user as-is. If `query-stats.sh` exits non-zero, report the error message to the user without modification.

### Invalid `--source` values

If `--source=<value>` is provided and the value is not `central` (e.g. `--source=bogus`, unknown source, invalid source), preserve default local-file behavior — do NOT invoke `query-stats.sh`. Optionally inform the user that the provided source is unrecognized and list valid values (`central`).
