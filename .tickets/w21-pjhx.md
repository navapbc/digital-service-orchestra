---
id: w21-pjhx
status: in_progress
deps: []
links: []
created: 2026-03-19T15:21:11Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-dksj
---
# RED: Write failing tests asserting SKILL.md ADVANCED section references prompt templates and context slots

Add class TestAdvancedInvestigationSkillIntegration to tests/skills/test_fix_bug_skill.py.

Tests must assert SKILL.md ADVANCED section:
1. References 'advanced-investigation-agent-a.md' prompt template
2. References 'advanced-investigation-agent-b.md' prompt template
3. Uses 'prompts/' directory convention (likely already passes — confirm)
4. Defines context assembly slots (failing_tests, stack_trace, commit_history) — check if ADVANCED section adds its own or inherits
5. References convergence scoring language ('convergence_score' or 'convergence scoring')

IMPORTANT: Tests in items 1 and 2 MUST FAIL before the SKILL.md GREEN task runs. Check that
'advanced-investigation-agent-a.md' and 'advanced-investigation-agent-b.md' do NOT yet appear in SKILL.md before writing — they don't.

Follow the exact pattern of TestIntermediateInvestigationSkillIntegration in the same file.

TDD Requirement (RED): Run 'python -m pytest tests/skills/test_fix_bug_skill.py::TestAdvancedInvestigationSkillIntegration -v' and confirm at minimum the agent-a and agent-b reference tests FAIL.

## Acceptance Criteria

- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff lint passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format-check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] TestAdvancedInvestigationSkillIntegration class exists in test_fix_bug_skill.py
  Verify: grep -q 'TestAdvancedInvestigationSkillIntegration' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] Tests for advanced-investigation-agent-a.md and agent-b.md references exist
  Verify: grep -q 'advanced-investigation-agent-a.md' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py && grep -q 'advanced-investigation-agent-b.md' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] All 5 new tests FAIL (RED) before SKILL.md update
  Verify: python -m pytest tests/skills/test_fix_bug_skill.py::TestAdvancedInvestigationSkillIntegration -v 2>&1 | grep -c FAILED | awk '{exit ($1 < 2)}'


## Notes

**2026-03-19T17:28:12Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T17:28:53Z**

CHECKPOINT 2/6: Code patterns understood ✓ — TestIntermediateInvestigationSkillIntegration is the model; ADVANCED section exists but does not yet reference advanced-investigation-agent-a.md or advanced-investigation-agent-b.md; convergence_score already in SKILL.md; context slots (failing_tests, stack_trace, commit_history) already present

**2026-03-19T17:29:16Z**

CHECKPOINT 3/6: Tests written ✓ — Added TestAdvancedInvestigationSkillIntegration with 5 tests to tests/skills/test_fix_bug_skill.py

**2026-03-19T17:29:33Z**

CHECKPOINT 4/6: Implementation complete ✓ — This is a RED task (no implementation required). Tests confirmed: 2 FAIL (agent-a.md, agent-b.md), 3 PASS (prompts/ convention, context slots, convergence scoring). GREEN implementation is owned by w21-rtmm.

**2026-03-19T17:29:55Z**

CHECKPOINT 5/6: Validation passed ✓ — ruff lint and ruff format both pass

**2026-03-19T17:32:49Z**

CHECKPOINT 6/6: Done ✓ — All AC verified: class exists, agent-a.md + agent-b.md references in test file, 2 tests FAIL RED (agent-a prompt ref, agent-b prompt ref), 3 PASS (prompts/ convention, context slots, convergence scoring). ruff lint+format pass.
