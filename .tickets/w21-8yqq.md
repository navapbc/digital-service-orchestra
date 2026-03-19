---
id: w21-8yqq
status: closed
deps: []
links: []
created: 2026-03-19T05:43:34Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-c4ek
---
# RED: Write failing tests asserting SKILL.md BASIC section references prompt template

Add a new test class to tests/skills/test_fix_bug_skill.py (or a separate file) that asserts the BASIC investigation section of plugins/dso/skills/fix-bug/SKILL.md references the prompt template file and includes explicit context-assembly instructions.

Tests FAIL (RED) because SKILL.md does not yet reference 'basic-investigation.md' nor include dispatch assembly instructions — this is the expected RED state before Task 4 updates SKILL.md.

Required test assertions (4 test functions minimum):
1. SKILL.md contains 'basic-investigation.md' (references the prompt template file)
2. SKILL.md BASIC section contains 'prompts/' (uses prompts directory convention)
3. SKILL.md contains explicit context-assembly format description (e.g., 'failing_tests', 'stack_trace', 'commit_history' as named context slots for the BASIC dispatch)
4. SKILL.md BASIC section contains reference to 'RESULT' format conformance (sub-agent must produce RESULT conforming to the schema)

Add as a new class TestBasicInvestigationSkillIntegration in tests/skills/test_fix_bug_skill.py or as tests/skills/test_fix_bug_basic_section.py.

TDD Requirement: Run python3 -m pytest tests/skills/test_fix_bug_skill.py -k 'BasicInvestigation' — tests must FAIL (RED) before Task 4 updates SKILL.md.

## ACCEPTANCE CRITERIA

- [ ] Tests with 'BasicInvestigation' in class name FAIL before Task 4 is implemented (RED confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/skills/test_fix_bug_skill.py -k 'BasicInvestigation' -q 2>&1 | grep -qE 'FAILED|ERROR' && echo 'RED confirmed'
- [ ] New test class exists in tests/skills/test_fix_bug_skill.py or tests/skills/test_fix_bug_basic_section.py
  Verify: grep -rq 'BasicInvestigation' $(git rev-parse --show-toplevel)/tests/skills/
- [ ] At least 4 test functions in the BasicInvestigation test class
  Verify: grep -A 50 'class.*BasicInvestigation' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py | grep -c 'def test_' | awk '{exit ($1 < 4)}'
- [ ] `ruff check` passes on the modified test file (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_fix_bug_skill.py
- [ ] `ruff format --check` passes on the modified test file (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_fix_bug_skill.py

## Notes

**2026-03-19T05:47:04Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T05:47:14Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T05:47:33Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T05:47:38Z**

CHECKPOINT 4/6: Implementation complete (RED test — no impl needed) ✓

**2026-03-19T05:48:16Z**

CHECKPOINT 5/6: RED state confirmed — 3/4 tests FAIL (basic-investigation.md reference, prompts/ convention, context slots); 4th test passes since SKILL.md already has RESULT. AC check grep -qE 'FAILED|ERROR' → RED confirmed ✓

**2026-03-19T05:48:20Z**

CHECKPOINT 6/6: Done ✓ — All 5 AC checks pass: RED confirmed, class exists, 4 test functions, ruff check clean, ruff format clean
