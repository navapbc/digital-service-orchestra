---
id: dso-7wks
status: open
deps: []
links: []
created: 2026-03-22T01:59:27Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-9l2x
---
# RED: Structural validation tests for clarification loop in using-lockpick

Write structural validation tests for the clarification loop content in SKILL.md and HOOK-INJECTION.md.

File: tests/skills/test-using-lockpick-clarification.sh

13 named test functions using bash assert.sh framework:
1. test_skill_md_has_clarification_section — grep for "## When No Skill Matches" heading
2. test_skill_md_has_confidence_test — grep for "one sentence what.*why" in context
3. test_skill_md_has_silent_investigation — grep for Read, Grep, tk show as investigation tools
4. test_skill_md_has_intent_probing — grep for Intent as labeled probing area (Intent.*what outcome)
5. test_skill_md_has_scope_probing — Scope as labeled probing area with description
6. test_skill_md_has_risks_probing — Risks as labeled probing area with description
7. test_skill_md_has_interaction_style — "one question" and "multiple-choice"
8. test_skill_md_preserves_existing_routing — "## The Rule" and "## Skill Priority" remain (criterion 1)
9. test_skill_md_has_dogfooding_guidance — intent-match measurement guidance (criterion 6)
10. test_skill_md_clarification_after_user_instructions — line number of "## When No Skill Matches" > "## User Instructions"
11. test_hook_md_has_clarification_section — clarification section heading in HOOK-INJECTION.md
12. test_hook_md_has_confidence_test — confidence test reference in HOOK-INJECTION.md
13. test_hook_md_has_probing_areas — Intent, Scope, Risks in HOOK-INJECTION.md

TDD: This IS the RED test task. All tests FAIL because neither file contains clarification loop yet.

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] Test file exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/tests/skills/test-using-lockpick-clarification.sh
- [ ] Test file contains at least 13 primary assert calls
  Verify: grep -cE 'assert_eq|assert_ne|assert_contains' $(git rev-parse --show-toplevel)/tests/skills/test-using-lockpick-clarification.sh | awk '{exit ($1 < 13)}'
- [ ] Running the test returns non-zero pre-implementation (RED)
  Verify: ! bash $(git rev-parse --show-toplevel)/tests/skills/test-using-lockpick-clarification.sh

