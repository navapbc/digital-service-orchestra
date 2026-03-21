---
id: dso-fg3m
status: closed
deps: []
links: []
created: 2026-03-21T21:15:59Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1as4
---
# Write RED test: sprint SKILL.md dispatches complexity evaluation via dso:complexity-evaluator

Write a failing pytest test asserting the post-change state of plugins/dso/skills/sprint/SKILL.md dispatch sections BEFORE the SKILL.md is updated.

TDD Requirement: Write test first, verify it FAILS (RED), then Task 4 updates SKILL.md to make it GREEN.

Test file: tests/skills/test_sprint_complexity_evaluator_dispatch.py

The test must assert ALL of:
1. Epic evaluator dispatch section (Step 2b) references 'dso:complexity-evaluator' (will fail before Task 4)
2. Epic evaluator dispatch section does NOT reference loading from sprint/prompts/epic-complexity-evaluator.md
3. Story evaluator dispatch section (Step 1: Identify Stories) references 'dso:complexity-evaluator' (will fail before Task 4)
4. Story evaluator dispatch section does NOT reference loading from sprint/prompts/complexity-evaluator.md
5. Context-specific routing MODERATE->COMPLEX text still exists in SKILL.md (routing must remain in sprint)

Helper: extract the 'Step 2b' section and 'Step 1: Identify Stories' section via regex, following the pattern in test_sprint_batch_title_display.py.

No dependencies (can run in parallel with Tasks 1-2; targets a different file).


## ACCEPTANCE CRITERIA

- [ ] tests/skills/test_sprint_complexity_evaluator_dispatch.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_sprint_complexity_evaluator_dispatch.py
- [ ] Test file contains at least 4 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_sprint_complexity_evaluator_dispatch.py | awk '{exit ($1 < 4)}'
- [ ] Test currently FAILS (RED) — SKILL.md not yet updated
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_sprint_complexity_evaluator_dispatch.py -x --tb=short 2>&1 | grep -qE 'FAILED|AssertionError'
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_sprint_complexity_evaluator_dispatch.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_sprint_complexity_evaluator_dispatch.py

## Notes

**2026-03-21T21:49:00Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T21:49:27Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T21:49:56Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T21:50:01Z**

CHECKPOINT 4/6: Implementation complete ✓ (RED test task — no implementation; test file is the deliverable)

**2026-03-21T21:50:17Z**

CHECKPOINT 5/6: Validation passed ✓ — tests FAIL (RED) as required; ruff check and format both pass

**2026-03-21T21:50:28Z**

CHECKPOINT 6/6: Done ✓ — all AC verified: file exists, 5 test functions (≥4), tests fail RED as required, ruff clean

**2026-03-21T21:59:29Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test_sprint_complexity_evaluator_dispatch.py. Tests: 5 RED (expected). Batch 1.
