---
id: dso-87p7
status: in_progress
deps: [dso-fjnc, dso-0ey5]
links: []
created: 2026-03-22T15:45:13Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ond9
---
# Update project-setup SKILL.md Step 5 to invoke ci-generator.sh for new projects


## Description

Update plugins/dso/skills/project-setup/SKILL.md Step 5 to generate CI workflows from discovered suites instead of copying a static template.

Changes to SKILL.md Step 5 (CI Workflow — Guard Analysis, Not Copy section):

CURRENT behavior:
- No .github/workflows/*.yml found → copy ci.example.yml to .github/workflows/ci.yml

NEW behavior when no workflows exist:
1. Run project-detect.sh --suites on TARGET_REPO to get JSON array
2. If suites discovered (non-empty array):
   a. For suites with speed_class=unknown: prompt user (fast/slow/skip, default: slow); in non-interactive mode default all unknown to slow
   b. Invoke ci-generator.sh --suites-json=<tmp_file> --output-dir=<TARGET_REPO>/.github/workflows/ [--non-interactive if non-interactive]
   c. ci-generator.sh handles YAML validation internally (actionlint or yaml.safe_load); exits non-zero on failure → surface error to user
   d. Report generated files: "Generated .github/workflows/ci.yml (N fast suites)" and/or "Generated .github/workflows/ci-slow.yml (N slow suites)"
3. If no suites discovered (empty array):
   a. Fall back to existing behavior: copy ci.example.yml → .github/workflows/ci.yml (only if no workflow exists)
   b. Note: "No test suites discovered — copied generic CI template. Review and customize .github/workflows/ci.yml."

Add to dryrun preview output (Step 4 dryrun section):
- "will generate .github/workflows/ci.yml from N fast suites" (if suites discovered)
- "will generate .github/workflows/ci-slow.yml from N slow suites" (if slow suites)
- "will copy ci.example.yml → .github/workflows/ci.yml (no suites discovered)" (fallback case)

TDD REQUIREMENT: Depends on dso-fjnc RED tests. All tests in tests/skills/test-project-setup-ci-generation.sh must pass GREEN after this task.
Also depends on dso-0ey5 (complete ci-generator.sh) — SKILL.md invokes the fully-implemented generator.

## ACCEPTANCE CRITERIA

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format --check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] SKILL.md references ci-generator.sh
  Verify: grep -q 'ci-generator' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md describes passing --suites JSON to the generator
  Verify: grep -q 'suites' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] SKILL.md references YAML validation (actionlint or yaml.safe_load)
  Verify: grep -qE 'actionlint|yaml.safe_load' $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md
- [ ] test-project-setup-ci-generation.sh passes GREEN
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/skills/test-project-setup-ci-generation.sh; test $? -eq 0
- [ ] Skill file is valid markdown
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/project-setup/SKILL.md

## Notes

<!-- note-id: zlk7ret5 -->
<!-- timestamp: 2026-03-22T17:26:11Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 6rip4ps1 -->
<!-- timestamp: 2026-03-22T17:35:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: vn2hn8gv -->
<!-- timestamp: 2026-03-22T17:35:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

<!-- note-id: 7eqal01e -->
<!-- timestamp: 2026-03-22T17:36:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: svm3mx72 -->
<!-- timestamp: 2026-03-22T17:37:01Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: ode1ltx6 -->
<!-- timestamp: 2026-03-22T17:37:11Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

**2026-03-22T17:39:18Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/skills/project-setup/SKILL.md, .test-index. Tests: 5 GREEN.
