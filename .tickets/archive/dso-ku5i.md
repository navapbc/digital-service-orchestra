---
id: dso-ku5i
status: closed
deps: []
links: []
created: 2026-03-17T21:07:32Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-2x3c
---
# Write failing doc migration completeness test (RED)

## TDD Requirement (RED phase)

Create tests/scripts/test-doc-migration.sh with test that verifies zero legacy ${CLAUDE_PLUGIN_ROOT}/scripts/ invocations remain. FAILS because 57 lines exist.

## Implementation Steps

1. Create tests/scripts/test-doc-migration.sh
2. Source $PLUGIN_ROOT/tests/lib/assert.sh
3. Implement test_no_legacy_plugin_root_refs:

```bash
test_no_legacy_plugin_root_refs() {
    REPO_ROOT=$(git rev-parse --show-toplevel)
    # Count legacy invocations, excluding known-good lines:
    # - PLUGIN_SCRIPTS= variable assignments (10 lines, config-resolution internal)
    # - ls directory listings like: ls "${CLAUDE_PLUGIN_ROOT}/scripts/"*.sh
    COUNT=$(grep -r '${CLAUDE_PLUGIN_ROOT}/scripts/' "$REPO_ROOT/skills" "$REPO_ROOT/docs/workflows" "$REPO_ROOT/CLAUDE.md" 2>/dev/null       | grep -v 'PLUGIN_SCRIPTS='       | grep -v 'ls.*CLAUDE_PLUGIN_ROOT.*scripts/"'       | wc -l | tr -d ' ')
    assert_eq "test_no_legacy_plugin_root_refs" "0" "$COUNT"
}
```

4. chmod +x tests/scripts/test-doc-migration.sh

<!-- REVIEW-DEFENSE: Closing a TDD RED-phase task ticket is valid after the test files are
written and confirmed failing. Writing test files IS the code change that satisfies this
task's acceptance criteria. CLAUDE.md rule 21 ("never close a bug without a code change")
applies to bug tickets, not TDD RED tasks whose deliverable is a failing test suite.
The corresponding GREEN task (dso-uxa1) captures the migration implementation work. -->

## Notes
- 57 invocation lines currently exist → test FAILS (RED confirmed)
- Exclusions: 10 PLUGIN_SCRIPTS= lines + 1 ls directory listing in skills/dev-onboarding/SKILL.md:121

## Acceptance Criteria

- [ ] run-all.sh exits with failures (confirming RED)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh 2>&1 | grep -q 'FAILED: [^0]'
- [ ] ruff check passes
  Verify: ruff check scripts/*.py tests/**/*.py
- [ ] ruff format --check passes
  Verify: ruff format --check scripts/*.py tests/**/*.py
- [ ] test-doc-migration.sh exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/scripts/test-doc-migration.sh
- [ ] Test FAILS while legacy refs exist
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-doc-migration.sh 2>&1 | grep -q 'FAIL'

