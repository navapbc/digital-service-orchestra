---
id: w21-milk
status: open
deps: [w21-f9uo]
links: []
created: 2026-03-20T19:10:10Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-uqfn
---
# IMPL: Register pre-commit-test-gate.sh in .pre-commit-config.yaml

Add pre-commit-test-gate.sh to .pre-commit-config.yaml as a local hook, registered alongside the existing review gate.

The hook entry should mirror the review gate entry pattern:

  - id: pre-commit-test-gate
    name: Test Gate (10s timeout)
    entry: ./plugins/dso/scripts/pre-commit-wrapper.sh pre-commit-test-gate 10 "./plugins/dso/hooks/pre-commit-test-gate.sh"
    language: system
    pass_filenames: false
    always_run: true
    stages: [pre-commit]

Placement: Insert AFTER the pre-commit-review-gate entry (not before) so the review gate error is shown first on a combined failure. This follows the story consideration: '.pre-commit-config.yaml has fail_fast: true — hook ordering determines which gate error the developer sees first; design the ordering so the test gate error is actionable regardless of review gate state.'

Both gates should be listed in sequence so developers see the review gate error first (since fixing the review gate is the first step in /dso:commit workflow), and then the test gate error.

Actually, reconsider ordering: The test gate should run BEFORE the review gate because:
- If tests fail, the developer should fix tests first (running /dso:commit will still require review)
- The test gate error is more actionable as the first blocker (run tests, re-run record-test-status.sh)
- This ensures the developer addresses test failures before investing in review

Insert BEFORE the pre-commit-review-gate entry.

Implementation constraint: Follow the exact pattern of existing hook entries in .pre-commit-config.yaml.

## Acceptance Criteria

- [ ] .pre-commit-config.yaml contains pre-commit-test-gate hook entry
  Verify: grep -q 'pre-commit-test-gate' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml
- [ ] Hook entry includes pre-commit-wrapper.sh with 10s timeout
  Verify: grep -A3 'pre-commit-test-gate' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml | grep -q 'pre-commit-wrapper.sh.*10'
- [ ] Hook entry has always_run: true
  Verify: grep -A5 'id: pre-commit-test-gate' $(git rev-parse --show-toplevel)/.pre-commit-config.yaml | grep -q 'always_run: true'
- [ ] coexistence tests pass (test-gate-coexistence.sh)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/hooks/test-test-gate-coexistence.sh 2>&1 | grep -q 'PASS.*test_pre_commit_config_registers_test_gate'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

