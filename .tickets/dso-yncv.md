---
id: dso-yncv
status: in_progress
deps: []
links: []
created: 2026-03-18T16:05:03Z
type: task
priority: 2
assignee: Joe Oakhart
parent: dso-ojbb
---
# Write failing dryrun tests for dso-setup.sh (TDD RED)

Write 5 new failing tests in tests/scripts/test-dso-setup.sh that specify expected --dryrun behavior. Tests must FAIL before implementation (RED phase).

TDD REQUIREMENT: Write ONLY tests, no implementation changes. Tests must fail because --dryrun does not exist yet.

Tests to add:
1. test_setup_dryrun_no_shim_created: run with --dryrun, assert .claude/scripts/dso NOT created
2. test_setup_dryrun_no_config_written: run with --dryrun, assert workflow-config.conf NOT written
3. test_setup_dryrun_no_precommit_copied: run with --dryrun, assert .pre-commit-config.yaml NOT copied
4. test_setup_dryrun_output_contains_shim_preview: run with --dryrun, assert stdout contains '[dryrun]'
5. test_setup_dryrun_flag_position_independent: assert --dryrun works as 3rd positional arg

Pattern: follow existing test structure using mktemp -d + git init, assert_eq. Each test uses isolated temp dir.

## ACCEPTANCE CRITERIA

- [ ] test_setup_dryrun_no_shim_created exists in tests/scripts/test-dso-setup.sh
  Verify: grep -q "test_setup_dryrun_no_shim_created" $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] test_setup_dryrun_no_config_written exists in tests/scripts/test-dso-setup.sh
  Verify: grep -q "test_setup_dryrun_no_config_written" $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] test_setup_dryrun_no_precommit_copied exists in tests/scripts/test-dso-setup.sh
  Verify: grep -q "test_setup_dryrun_no_precommit_copied" $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] test_setup_dryrun_output_contains_shim_preview exists in tests/scripts/test-dso-setup.sh
  Verify: grep -q "test_setup_dryrun_output_contains_shim_preview" $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] test_setup_dryrun_flag_position_independent exists in tests/scripts/test-dso-setup.sh
  Verify: grep -q "test_setup_dryrun_flag_position_independent" $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh
- [ ] New tests fail when run without implementation (RED phase confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/scripts/test-dso-setup.sh 2>&1 | grep -q "FAILED:"
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check scripts/*.py tests/**/*.py

## Notes

**2026-03-18T16:17:22Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-18T16:17:33Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-18T16:17:59Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-18T16:18:03Z**

CHECKPOINT 4/6: Implementation complete (tests-only, TDD RED phase) ✓

**2026-03-18T16:18:27Z**

CHECKPOINT 5/6: Validation passed ✓ (5 new tests fail RED, 21 existing pass, ruff clean)

**2026-03-18T16:18:48Z**

CHECKPOINT 6/6: Done ✓ — all 7 ACs pass, 5 new dryrun tests confirmed RED
