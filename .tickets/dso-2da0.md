---
id: dso-2da0
status: open
deps: []
links: []
created: 2026-03-19T18:21:38Z
type: bug
priority: 2
assignee: Joe Oakhart
jira_key: DIG-62
---
# Recurring tool error: command_exit_nonzero (56 occurrences)

## Error Details
Showing most recent 20 of 56 occurrences.
| # | Timestamp | Tool | Input Summary | Error Message |
|---|-----------|------|---------------|---------------|
| 1 | 2026-03-19T02:40:14Z | Bash | REPO_ROOT=$(...) && "$REPO_ROOT/plugins/... | Exit code 144 |
| 2 | 2026-03-19T02:40:28Z | Bash | REPO_ROOT=$(...) && WORKTREE_BRANCH=$(gi... | Exit code 1 |
| 3 | 2026-03-19T02:40:31Z | Bash | REPO_ROOT=$(...) && CLAUDE_PLUGIN_ROOT="... | Exit code 1 — diff hash mismatch |
| 4 | 2026-03-19T02:42:01Z | Bash | REPO_ROOT=$(...) && ls -la "$REPO_ROOT/.tickets/..." | Exit code 1 — no matches found |
| 5 | 2026-03-19T02:43:24Z | Bash | MAIN_REPO=... && BRANCH=... | Exit code 1 — CONFLICT in .tickets/.index.json |
| 6 | 2026-03-19T02:43:40Z | Bash | MAIN_REPO=... && git -C... | Exit code 2 — merge-ticket-index.py usage error |
| 7 | 2026-03-19T02:44:19Z | Bash | merge-to-main.sh | Exit code 1 — sequential warning |
| 8 | 2026-03-19T02:45:09Z | Bash | MAIN_REPO=... merge | Exit code 1 — CONFLICT in .tickets/.index.json |
| 9 | 2026-03-19T02:48:54Z | Bash | HOOK=track-tool-errors.sh test | Exit code 1 |
| 10 | 2026-03-19T02:50:32Z | Bash | REPO_ROOT=$(...) | Exit code 144 |
| 11 | 2026-03-19T02:50:33Z | Bash | test-track-tool-errors.sh | Exit code 144 |
| 12 | 2026-03-19T02:51:43Z | Bash | REPO_ROOT=$(...) | Exit code 144 |
| 13 | 2026-03-19T02:54:40Z | Bash | REPO_ROOT=$(...) | Exit code 144 |
| 14 | 2026-03-19T03:00:01Z | Bash | MAIN_ROOT fetch from remote | Exit code 128 |
| 15 | 2026-03-19T03:01:28Z | Bash | tests/run-all.sh | Exit code 144 |
| 16 | 2026-03-19T03:03:01Z | Bash | tests/run-all.sh | Exit code 144 |
| 17 | 2026-03-19T03:03:27Z | Bash | validate.sh | Exit code 1 — interface task mismatch |
| 18 | 2026-03-19T03:04:01Z | Bash | validate.sh | Exit code 144 |
| 19 | 2026-03-19T03:04:01Z | Bash | tests/run-all.sh (timeout 90) | Exit code 144 |
| 20 | 2026-03-19T03:06:58Z | Bash | run-hook-tests.sh | Exit code 144 |

