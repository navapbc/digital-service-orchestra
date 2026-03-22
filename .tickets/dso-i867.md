---
id: dso-i867
status: in_progress
deps: [dso-3mb3]
links: []
created: 2026-03-22T15:43:49Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ybey
---
# GREEN: Add uncovered-suite placement section to project-setup SKILL.md

Add a new 'Suite Placement' sub-section to Step 5 of plugins/dso/skills/project-setup/SKILL.md that enables the setup skill to identify uncovered test suites and prompt the user for placement.

TDD REQUIREMENT: Task dso-3mb3 (RED tests) must be FAILING before starting this task. This task makes those tests GREEN.

Implementation steps:
1. In SKILL.md Step 5, after the existing 'CI Workflow — Guard Analysis, Not Copy' section, add a new sub-section titled '### Suite Placement for Uncovered Suites' covering:
   a. COVERAGE DETECTION: Parse .github/workflows/*.yml step 'run:' values; check if each suite's command appears as a substring. 'uses:' (reusable workflow references) are treated as uncovered. Suites not matched by any step run: value are 'uncovered'.
   b. PLACEMENT PROMPT: For each uncovered suite, prompt (one at a time) with three options:
      - fast-gate: append a new job to the existing gating workflow (e.g., ci.yml). Job template: checkout -> setup runtime -> run command. Job ID derived from suite name (unit -> test-unit).
      - separate: create a new workflow file (e.g., .github/workflows/ci-<suitename>.yml) with the suite as its sole job, triggered on push to main.
      - skip: record test.suite.<name>.ci_placement=skip in .claude/dso-config.conf (add or update key).
   c. NON-INTERACTIVE FALLBACK: When running in non-interactive mode (test -t 0 returns false), apply defaults automatically: fast suites -> fast-gate (append to ci.yml), slow or unknown suites -> separate workflow (new file), skip option is unavailable.
   d. INCORPORATED DEFINITION: A suite is 'incorporated' when its workflow file or job has been written to disk AND git add has been run on the file.
   e. YAML VALIDATION: Before writing any workflow file (append or new), validate the YAML: run actionlint if on PATH, otherwise python3 yaml.safe_load. Write to a temp path, validate, then move to final destination. Validation failure blocks the write.
2. Remove the RED marker from .test-index after tests pass.

Files:
- EDIT: plugins/dso/skills/project-setup/SKILL.md
- EDIT: .test-index (remove RED marker [test_skill_has_suite_coverage_detection_section] after GREEN)

## ACCEPTANCE CRITERIA

- [ ] All tests in tests/skills/test_project_setup_suite_placement.py pass (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/skills/test_project_setup_suite_placement.py -q && echo "All GREEN"
- [ ] SKILL.md Step 5 contains suite coverage detection (substring-match against step run: values)
  Verify: grep -q 'run:' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md contains all three placement options: fast-gate, separate, skip
  Verify: grep -q 'fast-gate' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md && grep -q 'separate' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md && grep -q 'skip' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md documents ci_placement=skip config write for skip option
  Verify: grep -q 'ci_placement' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md documents non-interactive fallback behavior
  Verify: grep -q 'non-interactive\|non.interactive' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md documents YAML validation before writing workflow files (actionlint or yaml.safe_load, temp-path pattern)
  Verify: grep -q 'actionlint\|yaml.safe_load' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] RED marker removed from .test-index after tests pass
  Verify: ! grep -q 'test_project_setup_suite_placement.py.*\[test_skill_has_suite_coverage_detection_section\]' $(git rev-parse --show-toplevel)/.test-index
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/skills/
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/skills/


## Notes

**2026-03-22T16:21:24Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T16:22:09Z**

CHECKPOINT 2/6: Code patterns understood ✓ — SKILL.md Step 5 has 3 sub-sections; need to add Suite Placement after CI Guard Analysis section. .test-index line 70 exists but does not yet include test_project_setup_suite_placement.py

**2026-03-22T16:22:16Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓ — test_project_setup_suite_placement.py has 7 tests checking for: coverage detection, placement prompts (fast-gate/separate/skip), ci_placement config, non-interactive fallback, append-to-existing, new workflow file creation, YAML validation

**2026-03-22T16:22:50Z**

CHECKPOINT 4/6: Implementation complete ✓ — Added Suite Placement for Uncovered Suites sub-section to Step 5 of SKILL.md with all 7 required sub-sections: coverage detection, placement prompt, non-interactive fallback, incorporated definition, YAML validation

**2026-03-22T16:22:59Z**

CHECKPOINT 5/6: Validation passed ✓ — All 7 tests in test_project_setup_suite_placement.py pass GREEN

**2026-03-22T16:23:32Z**

CHECKPOINT 6/6: Done ✓ — All 9 acceptance criteria pass. SKILL.md updated with Suite Placement section. .test-index updated to include test_project_setup_suite_placement.py (no RED marker). 7/7 tests GREEN.

**2026-03-22T16:29:14Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/skills/project-setup/SKILL.md, .test-index. Tests: 7 GREEN.
