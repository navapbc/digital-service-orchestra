---
id: w21-4jzh
status: open
deps: []
links: []
created: 2026-03-21T22:22:54Z
type: task
priority: 3
assignee: Joe Oakhart
---
# Fix unused imports in test_bridge_outbound.py (ruff F401)


## Notes

**2026-03-21T22:22:59Z**

Discovered during w21-mrqh RED test writing. test_bridge_outbound.py has two unused imports (time, patch) that cause ruff F401 errors. These are in the sibling RED test task w21-3bqw scope. File: tests/scripts/test_bridge_outbound.py
