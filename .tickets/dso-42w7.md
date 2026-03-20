---
id: dso-42w7
status: open
deps: []
links: []
created: 2026-03-19T18:22:22Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-69
---
# Recurring tool error: command_exit_nonzero (64 occurrences)

## Error Details
Showing most recent 20 of 64 occurrences.
| # | Timestamp | Tool | Input Summary | Error Message |
|---|-----------|------|---------------|---------------|
| 1 | 2026-03-19T05:40:52Z | Bash | tk create --parent=w21-8igi | Exit code 1 — Unknown option |
| 2 | 2026-03-19T05:41:12Z | Bash | ls "$REPO_ROOT/plugi..." | Exit code 1 |
| 3 | 2026-03-19T05:42:03Z | Bash | tk create --parent=w21-1m1i | Exit code 1 — Unknown option |
| 4 | 2026-03-19T05:42:07Z | Bash | tk create "RED: Writ..." | Exit code 1 |
| 5 | 2026-03-19T05:42:15Z | Bash | tk create --parent=w21-c4ek | Exit code 1 — Unknown option |
| 6 | 2026-03-19T05:42:37Z | Bash | TASK1_ID=$(tk create --parent=w21-1m1i) | Exit code 1 — Unknown option |
| 7 | 2026-03-19T05:42:39Z | Bash | review-diff artifacts lookup | Exit code 1 — no matches found |
| 8 | 2026-03-19T05:42:41Z | Bash | tk create "test" --parent=w21-1m1i | Exit code 1 — Unknown option |
| 9 | 2026-03-19T05:46:17Z | Bash | merge-to-main.sh | Exit code 1 — sequential warning |
| 10 | 2026-03-19T05:46:26Z | Bash | merge-to-main.sh | Exit code 1 — MAIN_REPO unbound |
| 11 | 2026-03-19T05:47:49Z | Bash | merge-to-main.sh --resume | Exit code 1 — sync phase failure |
| 12 | 2026-03-19T05:49:06Z | Bash | REPO_ROOT command | Exit code 144 |
| 13 | 2026-03-19T05:50:49Z | Bash | validate.sh --ci | Exit code 144 |
| 14 | 2026-03-19T05:51:15Z | Bash | validate.sh | Exit code 1 — interface task mismatch |
| 15 | 2026-03-19T05:52:04Z | Bash | validate.sh | Exit code 144 |
| 16 | 2026-03-19T05:52:26Z | Bash | validate.sh | Exit code 1 — interface task mismatch |
| 17 | 2026-03-19T05:52:30Z | Bash | git merge --ff-only | Exit code 128 — diverging branches |
| 18 | 2026-03-19T05:54:03Z | Bash | diff hash computation | Exit code 1 — hash mismatch |
| 19 | 2026-03-19T05:54:24Z | Bash | tk list --type epic | Exit code 1 — Unknown command |
| 20 | 2026-03-19T05:55:02Z | Bash | tests/run-all.sh | Exit code 144 |

