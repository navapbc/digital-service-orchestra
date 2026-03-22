---
id: dso-7wks
status: closed
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


## Notes

**2026-03-22T02:41:44Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T02:43:33Z**

CHECKPOINT 2/6: Code patterns understood ✓ — tests/skills/ tests use bash assert.sh framework; standalone (not in run-all.sh); pattern matches test-quick-ref-skill.sh

**2026-03-22T02:44:24Z**

CHECKPOINT 3/6: Tests written ✓ — 13 named test functions in tests/skills/test-using-lockpick-clarification.sh

**2026-03-22T02:59:39Z**

CHECKPOINT 4/6: Implementation complete ✓ — tests/skills/test-using-lockpick-clarification.sh created with 13 named test functions using assert.sh framework

**2026-03-22T02:59:43Z**

CHECKPOINT 5/6: Validation passed ✓ — test exits 1 (RED: 12 fail, 1 pass for routing preservation); run-all.sh unaffected; assert count=13

**2026-03-22T02:59:55Z**

CHECKPOINT 6/6: Done ✓ — All AC checks pass: AC1 (run-all unaffected), AC2 (file executable), AC3 (13 asserts), AC4 (RED exits 1)

**2026-03-22T03:04:59Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test-using-lockpick-clarification.sh. Tests: 1 pass, 12 fail (RED phase expected).
