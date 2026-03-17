---
id: dso-5l1c
status: closed
deps: []
links: []
created: 2026-03-17T21:06:55Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-r9fa
---
# Write failing tests for dso-setup command (RED)

## TDD Requirement (RED phase)

Create tests/scripts/test-dso-setup.sh with 5 failing tests. All FAIL because scripts/dso-setup.sh does not exist yet.

## Implementation Steps

1. Create tests/scripts/test-dso-setup.sh
2. Source $PLUGIN_ROOT/tests/lib/assert.sh
3. Define SETUP_SCRIPT=$(git rev-parse --show-toplevel)/scripts/dso-setup.sh
4. Each test creates its own TMPDIR=$(mktemp -d) with trap 'rm -rf $TMPDIR' EXIT

## Tests to write:

**test_setup_creates_shim**
- bash "$SETUP_SCRIPT" "$TMPDIR" "$PLUGIN_ROOT"
- Assert: test -f "$TMPDIR/.claude/scripts/dso"

**test_setup_shim_executable**
- bash "$SETUP_SCRIPT" "$TMPDIR" "$PLUGIN_ROOT"
- Assert: test -x "$TMPDIR/.claude/scripts/dso"

**test_setup_writes_plugin_root**
- bash "$SETUP_SCRIPT" "$TMPDIR" "$PLUGIN_ROOT"
- Assert: grep -q '^dso.plugin_root=' "$TMPDIR/workflow-config.conf" (use absolute path to tmpdir file)

**test_setup_is_idempotent**
- Run setup twice on empty config; grep -c '^dso.plugin_root=' must equal 1
- Also: pre-populate config with existing entry, run once, assert count still 1

**test_setup_dso_tk_help_works**
- bash "$SETUP_SCRIPT" "$TMPDIR" "$PLUGIN_ROOT"
- Then: (cd "$TMPDIR" && unset CLAUDE_PLUGIN_ROOT && "./.claude/scripts/dso" tk --help)
- Assert exit 0

5. chmod +x tests/scripts/test-dso-setup.sh

<!-- REVIEW-DEFENSE: Closing a TDD RED-phase task ticket is valid after the test files are
written and confirmed failing. Writing test files IS the code change that satisfies this
task's acceptance criteria. CLAUDE.md rule 21 ("never close a bug without a code change")
applies to bug tickets, not TDD RED tasks whose deliverable is a failing test suite.
The corresponding GREEN task (dso-jl2z) captures the implementation work. -->

## Acceptance Criteria

- [ ] run-all.sh exits with failures (confirming RED)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q 'FAILED: [^0]'
- [ ] ruff check passes
  Verify: ruff check scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: ruff format --check scripts/*.py tests/**/*.py
- [ ] test-dso-setup.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] Contains at least 5 test functions
  Verify: grep -c '^test_setup_' $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh | awk '{exit ($1 < 5)}'
- [ ] Tests fail before setup script exists
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -q 'FAIL'

