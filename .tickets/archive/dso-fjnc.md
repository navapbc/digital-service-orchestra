---
id: dso-fjnc
status: closed
deps: []
links: []
created: 2026-03-22T15:44:50Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ond9
---
# RED: Write failing tests for project-setup SKILL.md CI generation step


## Description

Write failing tests for the project-setup SKILL.md Step 5 changes that invoke ci-generator.sh when no CI workflows exist.

TDD REQUIREMENT: Tests must fail (RED) before dso-c1u5 updates SKILL.md. The SKILL.md changes don't exist yet.

Create tests/skills/test-project-setup-ci-generation.sh (new file — complementary to existing skill tests).

Tests to write:
1. test_skill_step5_invokes_ci_generator_when_no_workflows: SKILL.md Step 5 must reference ci-generator.sh (or ci_generator) as the action when no workflows exist
2. test_skill_step5_passes_suites_json_to_generator: SKILL.md must describe passing project-detect.sh --suites output to the generator
3. test_skill_step5_does_not_copy_static_template_when_suites_available: SKILL.md must not fall back to ci.example.yml copy when suites are discovered
4. test_skill_step5_runs_actionlint_or_yaml_safe_load: SKILL.md must reference YAML validation (actionlint or yaml.safe_load)
5. test_skill_step5_speed_class_prompting_documented: SKILL.md must describe the speed_class=unknown prompting flow

File: tests/skills/test-project-setup-ci-generation.sh
Pattern: same as tests/skills/test-project-setup-commands-format.sh (grep for text patterns in SKILL.md)

test-exempt: N/A — this task writes tests, not production code.

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file exists at tests/skills/test-project-setup-ci-generation.sh
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test-project-setup-ci-generation.sh
- [ ] Test file contains at least 5 test assertions
  Verify: grep -c 'assert_eq\|assert_pass\|_snapshot_fail' $(git rev-parse --show-toplevel)/tests/skills/test-project-setup-ci-generation.sh | awk '{exit ($1 < 5)}'
- [ ] Tests fail (RED) before SKILL.md is updated
  Verify: bash $(git rev-parse --show-toplevel)/tests/skills/test-project-setup-ci-generation.sh 2>&1; test $? -ne 0
- [ ] .test-index entry maps project-setup/SKILL.md to test-project-setup-ci-generation.sh
  Verify: grep -q 'test-project-setup-ci-generation' $(git rev-parse --show-toplevel)/.test-index

## Notes

**2026-03-22T15:53:06Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T15:53:56Z**

CHECKPOINT 2/6: Code patterns understood ✓ — existing test uses grep-for-text-patterns in SKILL.md; Step 5 currently describes copying ci.example.yml (no ci-generator.sh reference); test file must check for new Step 5 behavior that doesn't exist yet (RED)

**2026-03-22T15:54:31Z**

CHECKPOINT 3/6: Tests written ✓ — 5 tests in tests/skills/test-project-setup-ci-generation.sh checking for ci-generator.sh, suites JSON input, static template removal, YAML validation, and speed_class prompting

**2026-03-22T15:55:02Z**

CHECKPOINT 4/6: Implementation complete ✓ — test file created at tests/skills/test-project-setup-ci-generation.sh; .test-index updated with RED marker [test_skill_step5_invokes_ci_generator_when_no_workflows]

**2026-03-22T16:12:49Z**

CHECKPOINT 5/6: Validation passed ✓ — test file runs RED (5 FAILED, 0 PASSED); AC criteria all pass; ruff check/format pass; .test-index has RED marker

**2026-03-22T16:12:54Z**

CHECKPOINT 6/6: Done ✓ — all 4 AC criteria verified: test file exists, 15 assertions (≥5), tests are RED, .test-index entry present with RED marker [test_skill_step5_invokes_ci_generator_when_no_workflows]

**2026-03-22T16:18:30Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test-project-setup-ci-generation.sh, .test-index. Tests: 5 RED (expected).
