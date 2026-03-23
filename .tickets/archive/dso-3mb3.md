---
id: dso-3mb3
status: closed
deps: []
links: []
created: 2026-03-22T15:43:30Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ybey
---
# RED: Write failing tests for suite placement section in project-setup SKILL.md

Write a failing test suite in tests/skills/test_project_setup_suite_placement.py that asserts the project-setup SKILL.md contains the uncovered-suite placement section required by story w22-ybey.

TDD REQUIREMENT: Write these tests FIRST. All tests must FAIL (RED) before task w22-ybey-impl is started. Tests pass only after the SKILL.md section is added.

Implementation steps:
1. Create tests/skills/test_project_setup_suite_placement.py
2. Tests assert SKILL.md Step 5 (CI Workflow section) contains:
   a. Suite coverage detection (parsing .github/workflows/*.yml, substring-matching step run: values)
   b. Placement prompts — fast-gate, separate, skip options all present
   c. Skip placement config write — ci_placement=skip in dso-config.conf
   d. Non-interactive fallback — fast->fast-gate, slow/unknown->separate
   e. Append-to-existing workflow for fast-gate option
   f. New workflow file creation for separate option
   g. YAML validation before writing — actionlint if installed, else yaml.safe_load; temp path → validate → move pattern
3. Add .test-index entry: plugins/dso/skills/project-setup/SKILL.md: tests/skills/test_project_setup_suite_placement.py [test_skill_has_suite_coverage_detection_section]
   NOTE: SKILL.md normalizes to 'skillmd', test basename to 'testprojectsetupsuiteplacement' — 'skillmd' is NOT a substring, so .test-index entry is REQUIRED.

Files:
- CREATE: tests/skills/test_project_setup_suite_placement.py
- EDIT: .test-index (add mapping with RED marker)

## ACCEPTANCE CRITERIA

- [ ] tests/skills/test_project_setup_suite_placement.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_project_setup_suite_placement.py
- [ ] Test file contains at least 6 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_project_setup_suite_placement.py | awk '{exit ($1 < 6)}'
- [ ] All tests FAIL (RED) before implementation task runs — no false positives
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/skills/test_project_setup_suite_placement.py -q 2>&1 | grep -q 'FAILED'
- [ ] Test file includes a test asserting SKILL.md documents YAML validation (actionlint/yaml.safe_load) before writing workflow files
  Verify: grep -q 'yaml_validation\|yaml.safe_load\|actionlint\|validate.*workflow\|workflow.*validat' $(git rev-parse --show-toplevel)/tests/skills/test_project_setup_suite_placement.py
- [ ] .test-index entry added mapping SKILL.md to test file with RED marker [test_skill_has_suite_coverage_detection_section]
  Verify: grep -q 'project-setup/SKILL.md.*test_project_setup_suite_placement.py.*\[test_skill_has_suite_coverage_detection_section\]' $(git rev-parse --show-toplevel)/.test-index
- [ ] ruff check passes on new test file (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_project_setup_suite_placement.py
- [ ] ruff format --check passes on new test file (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_project_setup_suite_placement.py


## Notes

<!-- note-id: 1pvtathp -->
<!-- timestamp: 2026-03-22T15:53:22Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: tjghywx1 -->
<!-- timestamp: 2026-03-22T15:53:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 4j9ob2zg -->
<!-- timestamp: 2026-03-22T15:54:18Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: s3xrob9k -->
<!-- timestamp: 2026-03-22T15:54:50Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: xu6mgyt3 -->
<!-- timestamp: 2026-03-22T15:55:09Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 7 tests FAILED (RED) as expected, ruff check+format clean

<!-- note-id: vnpwq76p -->
<!-- timestamp: 2026-03-22T15:55:31Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — all 7 AC criteria pass

**2026-03-22T16:18:30Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test_project_setup_suite_placement.py, .test-index. Tests: 7 RED (expected).
