---
id: w21-i8qa
status: closed
deps: []
links: []
created: 2026-03-18T23:56:03Z
type: task
priority: 0
assignee: Joe Oakhart
parent: dso-s991
---
# Write failing structural test for TDD story requirements in preplanning SKILL.md

RED test writing task — first step of the TDD cycle for dso-s991.

Create tests/skills/test_preplanning_tdd_story_requirements.py following the pattern of tests/skills/test_implementation_plan_skill_tdd_enforcement.py.

Each test function checks plugins/dso/skills/preplanning/SKILL.md for required TDD guidance. Include a comment at the top documenting that new TDD requirements apply going forward only — no retroactive ticket cleanup needed.

Test functions (each does semantic check of SKILL.md content):
- test_skill_md_contains_unit_test_dod_requirement
- test_skill_md_exempts_docs_and_research_stories
- test_skill_md_contains_e2e_test_story_guidance
- test_skill_md_contains_integration_test_story_guidance
- test_skill_md_contains_test_story_dependency_ordering
- test_skill_md_contains_red_acceptance_criteria
- test_skill_md_contains_internal_epic_exemption

TDD requirement: This IS the failing test. After creating the file, run python3 -m pytest tests/skills/test_preplanning_tdd_story_requirements.py -v to confirm FAIL (RED) before any SKILL.md changes.

TDD exemption (no preceding RED test): Integration exemption criterion 2 — scaffolding task that creates the test mechanism initiating the TDD cycle.


## ACCEPTANCE CRITERIA

- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_preplanning_tdd_story_requirements.py
- [ ] File contains 7 test functions named test_skill_md_*
  Verify: python3 -m pytest $(git rev-parse --show-toplevel)/tests/skills/test_preplanning_tdd_story_requirements.py --collect-only -q 2>&1 | grep -c '::test_' | awk '{exit ($1 < 7)}'
- [ ] Tests run and FAIL (RED — not a collection error)
  Verify: python3 -m pytest "$(git rev-parse --show-toplevel)/tests/skills/test_preplanning_tdd_story_requirements.py" -v 2>&1 | grep -q 'FAILED' && echo 'RED confirmed'

## Notes

<!-- note-id: 5tfi01gk -->
<!-- timestamp: 2026-03-19T00:40:25Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: njho3p8o -->
<!-- timestamp: 2026-03-19T00:40:32Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: pzokp6ch -->
<!-- timestamp: 2026-03-19T00:40:59Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: swgs7ttp -->
<!-- timestamp: 2026-03-19T00:42:19Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: lp04me3x -->
<!-- timestamp: 2026-03-19T00:42:20Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: 09lgygsi -->
<!-- timestamp: 2026-03-19T00:42:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓

<!-- note-id: i3fbjiio -->
<!-- timestamp: 2026-03-19T00:54:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test_preplanning_tdd_story_requirements.py. Tests: 7 RED (expected), 41 passed.

<!-- note-id: 5wp06n03 -->
<!-- timestamp: 2026-03-19T00:54:24Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CLOSE REASON: Fixed: created tests/skills/test_preplanning_tdd_story_requirements.py with 7 RED failing tests asserting TDD requirements in preplanning SKILL.md
