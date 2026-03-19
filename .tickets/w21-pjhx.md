---
id: w21-pjhx
status: open
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

