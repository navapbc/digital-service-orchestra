---
id: dso-cvtx
status: open
deps: []
links: []
created: 2026-03-23T22:01:23Z
type: bug
priority: 1
assignee: Joe Oakhart
---
# Fix CI failures on commit 9b7a7f3 — rollback strategy and log dir preservation


## Notes

<!-- note-id: ohrn1wlv -->
<!-- timestamp: 2026-03-23T22:02:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT: Investigated CI failures. Root causes: (1) _phase_finalize tests passing but RED markers not removed. (2) test_cutover_rollback_committed_uses_revert: _run_commit_before captured after pre-seeded commit — added CUTOVER_COMMIT_BEFORE env override so test can specify baseline commit. (3) test_cutover_exits_with_error_and_log_path_on_failure: git clean -e with absolute path silently failed, removing log dir; printf>>log then failed under set -euo pipefail. Fixed by computing relative path for git clean -e and adding || true to log writes. Updated tests 4+7 to filter cutover-logs/ from git status check. All 99 tests passing (74+25). RED markers removed from .test-index.
