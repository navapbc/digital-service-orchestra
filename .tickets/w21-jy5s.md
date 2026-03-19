---
id: w21-jy5s
status: closed
deps: [w21-src2]
links: []
created: 2026-03-19T06:05:45Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ahok
---
# GREEN: Update SKILL.md INTERMEDIATE section to reference prompt templates and define dispatch slots

Update the INTERMEDIATE Investigation section in plugins/dso/skills/fix-bug/SKILL.md to:
1. Reference the prompt template file: prompts/intermediate-investigation.md (primary — for error-detective)
2. Reference the fallback prompt: prompts/intermediate-investigation-fallback.md (for general-purpose)
3. Add explicit dispatch context assembly table (matching the BASIC section pattern):
   | Slot | Source |
   | {ticket_id} | The bug ticket ID |
   | {failing_tests} | Output of $TEST_CMD |
   | {stack_trace} | Stack trace from test output |
   | {commit_history} | git log --oneline -20 -- <affected-files> |
   | {prior_fix_attempts} | Ticket notes with previous fix records |
4. Clarify the routing logic: when error-debugging:error-detective is available (via discover-agents.sh), use intermediate-investigation.md; when falling back to general-purpose, use intermediate-investigation-fallback.md

The sub-agent RESULT must conform to the INTERMEDIATE RESULT Report Schema (already defined in SKILL.md).

File to edit: plugins/dso/skills/fix-bug/SKILL.md
Section to update: lines around 'INTERMEDIATE Investigation (score 3-5)' in Step 2.

TDD Requirement: python3 -m pytest tests/skills/test_fix_bug_skill.py::TestIntermediateInvestigationSkillIntegration - all tests must PASS (GREEN) after this update.

