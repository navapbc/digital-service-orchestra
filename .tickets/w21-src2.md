---
id: w21-src2
status: closed
deps: []
links: []
created: 2026-03-19T06:05:11Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ahok
---
# RED: Write failing tests asserting SKILL.md INTERMEDIATE section references prompt template

Add a new test class TestIntermediateInvestigationSkillIntegration to tests/skills/test_fix_bug_skill.py asserting that the INTERMEDIATE section of SKILL.md references the prompt template file and defines dispatch context assembly.

Required test assertions (4 test methods minimum):
1. SKILL.md contains 'intermediate-investigation.md' (reference to prompt template file)
2. SKILL.md INTERMEDIATE section uses 'prompts/' directory convention
3. SKILL.md defines context assembly slots: failing_tests, stack_trace, commit_history (already pass if present — verify these are already there from BASIC)
4. SKILL.md references fallback prompt or investigation-specific prompt for general-purpose fallback

Tests FAIL (RED) because SKILL.md does not yet reference 'intermediate-investigation.md'.

TDD Requirement: python3 -m pytest tests/skills/test_fix_bug_skill.py::TestIntermediateInvestigationSkillIntegration - all tests must FAIL before SKILL.md update.

