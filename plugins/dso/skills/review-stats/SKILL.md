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
