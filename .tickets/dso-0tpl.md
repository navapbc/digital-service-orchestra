---
id: dso-0tpl
status: closed
deps: [dso-gccc]
links: []
created: 2026-03-19T05:02:04Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-auwy
---
# Deprecate tdd-workflow with forward pointer to dso:fix-bug

Add a deprecation notice to plugins/dso/skills/tdd-workflow/SKILL.md that forwards practitioners to the new /dso:fix-bug skill.

TDD Exemption: This task is exempt from the RED test requirement.
- Criterion 3 (static assets only): This modifies only static Markdown documentation. No conditional logic, no branching code, no executable behavior is added. The deprecation notice is a forward-pointer paragraph with no behavioral content.
- The addition is verifiable by the structural test in dso-qd5d (which can be extended to check tdd-workflow contains 'fix-bug' or 'deprecated').

Changes Required:
1. Add a deprecation banner at the top of plugins/dso/skills/tdd-workflow/SKILL.md (after frontmatter), before the main heading, with text like:
   > **Deprecated**: This skill is superseded by /dso:fix-bug for individual bug fixes. See plugins/dso/skills/fix-bug/SKILL.md for the full investigation and fix workflow.
   IMPORTANT: The forward pointer MUST use the fully-qualified '/dso:fix-bug' form (not bare 'fix-bug' without the namespace prefix). check-skill-refs.sh enforces qualified skill references in all in-scope files including tdd-workflow/SKILL.md — an unqualified reference will fail CI.
2. Do NOT remove any existing content -- full backward compatibility (the old workflow content remains for reference)

Verify: grep -q 'fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/tdd-workflow/SKILL.md

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: bash $(git rev-parse --show-toplevel)/tests/run-all.sh
- [ ] tdd-workflow skill contains forward pointer to fix-bug
  Verify: grep -q 'fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/tdd-workflow/SKILL.md
- [ ] tdd-workflow skill contains deprecation language
  Verify: grep -qi 'deprecated\|superseded' $(git rev-parse --show-toplevel)/plugins/dso/skills/tdd-workflow/SKILL.md
- [ ] All original tdd-workflow content is preserved (no removals)
  Verify: grep -q 'Red-Green-Refactor' $(git rev-parse --show-toplevel)/plugins/dso/skills/tdd-workflow/SKILL.md
- [ ] check-skill-refs.sh passes (no unqualified skill references introduced)
  Verify: bash $(git rev-parse --show-toplevel)/plugins/dso/scripts/check-skill-refs.sh
- [ ] Forward pointer uses qualified '/dso:fix-bug' form (not bare 'fix-bug')
  Verify: grep -q '/dso:fix-bug' $(git rev-parse --show-toplevel)/plugins/dso/skills/tdd-workflow/SKILL.md

<!-- Gap Analysis Amendment (w21-auwy Step 6): Skill namespace qualification enforced by check-skill-refs.sh CI check — unqualified 'fix-bug' reference would fail CI. -->


## Notes

<!-- note-id: gta5pr2f -->
<!-- timestamp: 2026-03-19T05:31:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 3t96ya84 -->
<!-- timestamp: 2026-03-19T05:32:02Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 1s50w7b5 -->
<!-- timestamp: 2026-03-19T05:32:06Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required — TDD-exempt, static asset only) ✓

<!-- note-id: 421xdkyd -->
<!-- timestamp: 2026-03-19T05:32:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: q76oeft3 -->
<!-- timestamp: 2026-03-19T05:36:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Basic validation passed — ruff all checks passed; test-commit-failure-tracker pre-existing failure (2 pass, 3 fail before and after change); check-skill-refs passes ✓

<!-- note-id: 9guo3ayb -->
<!-- timestamp: 2026-03-19T05:36:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
