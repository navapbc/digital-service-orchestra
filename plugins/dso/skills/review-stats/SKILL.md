---
name: review-stats
description: Display review event statistics — shows reviewer tier distribution, resolution rates, and trends over time.
user-invocable: true
allowed-tools:
---

# Review Stats

Display aggregated statistics from the review event log.

## Usage

```
/dso:review-stats              # Stats for the last 30 days (default)
/dso:review-stats --since=2026-03-01  # Stats since a specific date
/dso:review-stats --all        # All recorded review events
```

## Execution

Run the review-stats CLI with any user-provided arguments:

```bash
.claude/scripts/dso review-stats.sh $ARGS
```

where `$ARGS` are the flags passed by the user (e.g., `--since=2026-03-01`, `--all`).

Present the script output to the user as-is.
