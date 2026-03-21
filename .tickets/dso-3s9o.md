---
id: dso-3s9o
status: open
deps: [dso-ez3s]
links: []
created: 2026-03-21T19:58:59Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w22-ku13
---
# SKILL: Add test-index generation step to /dso:dev-onboarding

Add a new phase step to plugins/dso/skills/dev-onboarding/SKILL.md that invokes generate-test-index.sh during onboarding to bootstrap .test-index.

TDD REQUIREMENT: This task modifies only a Markdown documentation file (SKILL.md). No executable logic is added or changed. Exemption criterion: 'static assets only — Markdown documentation, no executable assertion possible'. No RED test task required.

SAFEGUARD NOTE: plugins/dso/skills/dev-onboarding/SKILL.md is a safeguarded file (CLAUDE.md rule 20: 'Never edit safeguard files without user approval'). The sub-agent executing this task MUST confirm with the user before making any edits to SKILL.md. The story scope explicitly calls for this change, so user approval is pre-authorized at the story level, but the executing agent must still surface the specific edit for confirmation before applying it.

Implementation:
- Add a new step in Phase 3 (The Enforcer) of dev-onboarding/SKILL.md, after the plugin infrastructure inventory step (Step 0) and before anti-pattern risk assessment.
- Name the step: 'Step 0.5: Bootstrap .test-index via Scanner'
- Content of the step:
  1. Check if .test-index already exists at repo root; if so, report its entry count and skip regeneration (unless --force-scan is given)
  2. If .test-index does not exist (or --force-scan): run the scanner:
     bash plugins/dso/scripts/generate-test-index.sh
  3. Present the coverage summary output to the user
  4. Commit .test-index to version control with message 'chore: bootstrap .test-index via generate-test-index.sh'
  5. Note: .test-index is a living document — future changes to test naming may require re-running the scanner
- The step must note that test files which DO NOT follow fuzzy-match conventions must have .test-index entries, and that generate-test-index.sh auto-discovers these
- Include a note referencing the .test-index format: 'source/path.ext: test/path1.ext, test/path2.ext'
- Place the step consistently with the other numbered steps in Phase 3

Files to edit:
- plugins/dso/skills/dev-onboarding/SKILL.md (edit)

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] SKILL.md contains 'Step 0.5: Bootstrap .test-index via Scanner' (or equivalent)
  Verify: grep -q "Bootstrap.*test-index\|test-index.*Bootstrap\|generate-test-index" $(git rev-parse --show-toplevel)/plugins/dso/skills/dev-onboarding/SKILL.md
- [ ] SKILL.md step includes the generate-test-index.sh command
  Verify: grep -q "generate-test-index.sh" $(git rev-parse --show-toplevel)/plugins/dso/skills/dev-onboarding/SKILL.md
- [ ] SKILL.md references the .test-index format (source/path: test/path)
  Verify: grep -q "source.*test.*path\|test-index.*format\|\.test-index" $(git rev-parse --show-toplevel)/plugins/dso/skills/dev-onboarding/SKILL.md

