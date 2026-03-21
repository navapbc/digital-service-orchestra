---
id: w21-yzln
status: closed
deps: []
links: []
created: 2026-03-19T05:55:25Z
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
| 1 | 2026-03-19T05:40:52Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && tk create "RED: test | Exit code 1\nUnknown option: --parent=w21-8igi |
| 2 | 2026-03-19T05:41:12Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && ls "$REPO_ROOT/plugi | Exit code 1 |
| 3 | 2026-03-19T05:42:03Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && tk create "RED: veri | Exit code 1\nUnknown option: --parent=w21-1m1i |
| 4 | 2026-03-19T05:42:07Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && tk create "RED: Writ | Exit code 1 |
| 5 | 2026-03-19T05:42:15Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && tk create "RED: Writ | Exit code 1\nUnknown option: --parent=w21-c4ek |
| 6 | 2026-03-19T05:42:37Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && TASK1_ID=$(tk create | Exit code 1\nUnknown option: --parent=w21-1m1i |
| 7 | 2026-03-19T05:42:39Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && CLAUDE_PLUGIN_ROOT=" | Exit code 1\n(eval):1: no matches found: /tmp/lockpick-test-artifacts-worktree-20260318-172139/review-diff-*.txt |
| 8 | 2026-03-19T05:42:41Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && tk create "test" --p | Exit code 1\nUnknown option: --parent=w21-1m1i |
| 9 | 2026-03-19T05:46:17Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT" && b | Exit code 1\nWARNING: Running all phases sequentially. Use --phase=<name> to run a single phase or --resume to continue  |
| 10 | 2026-03-19T05:46:26Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT" && b | Exit code 1\nplugins/dso/scripts/merge-to-main.sh: line 858: MAIN_REPO: unbound variable |
| 11 | 2026-03-19T05:47:49Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && cd "$REPO_ROOT" && b | Exit code 1\nINFO: Resuming from phase 'sync' (first incomplete phase).\n/Users/joeoakhart/digital-service-orchestra-wor |
| 12 | 2026-03-19T05:49:06Z | Bash | Bash: command=REPO_ROOT=$(git -C /Users/joeoakhart/digital-service-orchestra-wor | Exit code 144 |
| 13 | 2026-03-19T05:50:49Z | Bash | Bash: command=./plugins/dso/scripts/validate.sh --ci, timeout=960000 | Exit code 144\n  (worktree: worktree-20260318-172139) |
| 14 | 2026-03-19T05:51:15Z | Bash | Bash: command=bash "/Users/joeoakhart/digital-service-orchestra-worktrees/worktr | Exit code 1\n\u001b[0;34m=== Issue Tracking Health Check ===\u001b[0m\n\n\u001b[1;33m[WARNING]\u001b[0m Interface task m |
| 15 | 2026-03-19T05:52:04Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && bash "${REPO_ROOT}/p | Exit code 144 |
| 16 | 2026-03-19T05:52:26Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && PLUGIN_SCRIPTS_DIR=/ | Exit code 1\n\u001b[0;34m=== Issue Tracking Health Check ===\u001b[0m\n\n\u001b[1;33m[WARNING]\u001b[0m Interface task m |
| 17 | 2026-03-19T05:52:30Z | Bash | Bash: command=git -C /Users/joeoakhart/digital-service-orchestra merge --ff-only | Exit code 128\nhint: Diverging branches can't be fast-forwarded, you need to either:\nhint:\nhint: \tgit merge --no-ff\n |
| 18 | 2026-03-19T05:54:03Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel)
PLUGIN_ROOT="/Users/joe | Exit code 1\nNEW_HASH=dbc98a8cd26b600b9f851974a12595f48a92a5e8e29e51fb701773698e3462d0\nERROR: diff hash mismatch — code |
| 19 | 2026-03-19T05:54:24Z | Bash | Bash: command=tk list --type epic --status in_progress 2>&1, timeout=30000 | Exit code 1\nUnknown command: list\ntk - minimal ticket system with dependency tracking\n\nUsage: tk <command> [args]\n\ |
| 20 | 2026-03-19T05:55:02Z | Bash | Bash: command=REPO_ROOT=$(git rev-parse --show-toplevel) && bash tests/run-all.s | Exit code 144 |


## Notes

<!-- note-id: 5sbr2sek -->
<!-- timestamp: 2026-03-20T22:33:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Duplicate of dso-42w7. Closing.

<!-- note-id: 31wzx4fp -->
<!-- timestamp: 2026-03-20T22:33:56Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: duplicate of dso-42w7
