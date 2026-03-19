---
id: dso-j3gm
status: closed
deps: []
links: []
created: 2026-03-17T21:06:10Z
type: task
priority: 0
assignee: Joe Oakhart
---
# Write failing tests for shim --lib mode (RED)

## TDD Requirement (RED phase)

Add 4 failing test functions to tests/scripts/test-shim-smoke.sh. All FAIL until --lib is implemented.

Tests to add:
- test_lib_mode_exports_dso_root: helper subscript sources shim --lib; assert DSO_ROOT == PLUGIN_ROOT and starts with '/'
- test_lib_mode_produces_no_stdout: helper subscript SOURCES shim --lib; capture stdout; assert empty
- test_lib_mode_does_not_dispatch: helper subscript sources shim --lib then exit 0; assert exit 0 (no dispatch)
- test_lib_mode_exec_exits_zero: bash shim --lib; assert exit 0

RED: shim treats '--lib' as script name → exits 127 → all FAIL


## Notes

**2026-03-17T21:06:26Z**

parent: dso-0y9j
