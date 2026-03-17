---
id: dso-02wk
status: open
deps: []
links: []
created: 2026-03-17T21:06:26Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-0y9j
---
# Write failing tests for shim --lib mode (RED)

## TDD Requirement (RED phase)

Add 4 failing test functions to tests/scripts/test-shim-smoke.sh. All FAIL until --lib is implemented.

**test_lib_mode_exports_dso_root**: helper sh-c sources shim --lib; assert DSO_ROOT equals PLUGIN_ROOT and starts with '/'
**test_lib_mode_produces_no_stdout**: helper sources (not exec) shim --lib; capture stdout; assert empty
**test_lib_mode_does_not_dispatch**: helper sources shim --lib then exit 0; assert exit 0 (no dispatch attempted)
**test_lib_mode_exec_exits_zero**: CLAUDE_PLUGIN_ROOT=PLUGIN_ROOT bash shim --lib; assert exit 0

RED: shim treats '--lib' as script name, exits 127. All 4 FAIL.

## Acceptance Criteria

- [ ] run-all.sh exits with failures (confirming RED phase)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q 'FAILED: [^0]'
- [ ] ruff check passes
  Verify: ruff check scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: ruff format --check scripts/*.py tests/**/*.py
- [ ] test-shim-smoke.sh contains at least 4 lib-mode test functions
  Verify: grep -c '^test_lib_mode_' $(git rev-parse --show-toplevel)/tests/scripts/test-shim-smoke.sh | awk '{exit ($1 < 4)}'
- [ ] New lib-mode tests FAIL before --lib implementation
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-shim-smoke.sh 2>&1 | grep 'FAIL' | grep -q 'lib_mode'

