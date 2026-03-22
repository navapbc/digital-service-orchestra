---
id: w21-4jzh
status: closed
deps: []
links: []
created: 2026-03-21T22:22:54Z
type: task
priority: 3
assignee: Joe Oakhart
parent: w22-ns6l
---
# Fix unused imports in test_bridge_outbound.py (ruff F401)


## Notes

**2026-03-21T22:22:59Z**

Discovered during w21-mrqh RED test writing. test_bridge_outbound.py has two unused imports (time, patch) that cause ruff F401 errors. These are in the sibling RED test task w21-3bqw scope. File: tests/scripts/test_bridge_outbound.py

**2026-03-22T07:51:12Z**

Tier 7: assigned for Project Health Restoration epic w22-ns6l triage.

<!-- note-id: z2eo5huv -->
<!-- timestamp: 2026-03-22T15:53:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Bug already resolved. ruff check passes on tests/scripts/test_bridge_outbound.py — no unused imports (time, patch) found. The file currently imports only: __future__.annotations, importlib.util, json, pathlib.Path, types.ModuleType, unittest.mock.MagicMock, pytest. All are used. Likely cleaned up during earlier bridge hardening commits. Closing as fixed.

<!-- note-id: 01d64yvf -->
<!-- timestamp: 2026-03-22T15:53:45Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: unused imports (time, patch) no longer present in tests/scripts/test_bridge_outbound.py — ruff check passes cleanly; resolved in earlier bridge hardening commits
