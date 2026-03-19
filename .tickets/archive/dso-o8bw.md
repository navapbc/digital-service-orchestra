---
id: dso-o8bw
status: closed
deps: []
links: []
created: 2026-03-17T22:38:16Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-y9sz
---
# Write cross-context smoke test for dso shim

Create tests/scripts/test-shim-cross-context.sh with three test functions (test_shim_works_from_repo_root, test_shim_works_from_subdirectory, test_shim_works_from_worktree) using the assert.sh pattern (WORKTREES=()/TMPDIRS=() + single trap EXIT). Create tests/smoke-test-dso-shim.sh as a thin wrapper delegating to the test script. The worktree test gracefully skips (skip-as-pass idiom) if git worktrees are unavailable in CI.


## Notes

<!-- note-id: xtgc125z -->
<!-- timestamp: 2026-03-17T22:49:15Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: tests/scripts/test-shim-cross-context.sh + tests/smoke-test-dso-shim.sh (SHA fb6cde4)
