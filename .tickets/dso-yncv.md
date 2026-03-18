---
id: dso-yncv
status: open
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

