---
id: dso-8jp8
status: open
deps: [dso-vl19, dso-cnj5]
links: []
created: 2026-03-23T20:27:52Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-78iq
---
# Integration test: verify dso-setup.sh registers ticket gate hook

Write an integration test verifying that dso-setup.sh's merge_precommit_hooks function correctly adds the pre-commit-ticket-gate hook to a host project's .pre-commit-config.yaml.

TDD REQUIREMENT: Write the test BEFORE completing Task 3's config wiring. The test should fail if the hook ID is missing from the example file.

Integration test location: tests/hooks/test-pre-commit-ticket-gate.sh (add integration test cases at the end of the existing test file from Task 1, or create a dedicated section).

Alternatively, if the established pattern for setup integration tests is a separate file, create tests/hooks/test-ticket-gate-setup-integration.sh.

CHECK FIRST: look for existing dso-setup.sh integration tests (e.g., test-init-skill.sh) to understand the established pattern before creating a new file.

Test cases:
1. test_dso_setup_merges_ticket_gate_hook — run merge_precommit_hooks with a minimal .pre-commit-config.yaml and verify 'pre-commit-ticket-gate' appears in the output file with stages: [commit-msg]
2. test_dso_setup_idempotent — run merge_precommit_hooks twice on same file; verify hook not duplicated

NOTE: This is an integration test crossing the dso-setup.sh/pre-commit-config.example.yaml boundary. Per the Integration Test Task Rule, this test may be written after the implementation tasks (no RED-first requirement) since it verifies the boundary interaction end-to-end.

If a comprehensive existing test already covers this boundary (e.g., test-init-skill.sh exercises merge_precommit_hooks with the example file), document the existing coverage and skip creating a new test file — the exemption applies ('existing coverage' exemption).

## Acceptance Criteria

- [ ] Integration test(s) for ticket gate hook registration exist (either in test-pre-commit-ticket-gate.sh or a separate test file)
  Verify: grep -rq 'test.*dso_setup.*ticket\|test.*ticket.*gate.*setup\|merge_precommit_hooks.*ticket' $(git rev-parse --show-toplevel)/tests/
- [ ] Integration test verifies 'pre-commit-ticket-gate' appears in merged output file
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -q 'test_dso_setup_merges_ticket_gate_hook.*PASS'
- [ ] Integration test verifies idempotency (no duplicate hook IDs)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-ticket-gate.sh 2>&1 | grep -q 'test_dso_setup_idempotent.*PASS'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check $(git rev-parse --show-toplevel)/plugins/dso/scripts/*.py $(git rev-parse --show-toplevel)/tests/**/*.py

