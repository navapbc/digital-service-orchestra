---
id: w21-sjie
status: open
deps: [w21-j4i9]
links: []
created: 2026-03-19T06:05:35Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ahok
---
# GREEN: Create plugins/dso/skills/fix-bug/prompts/intermediate-investigation-fallback.md

Create the INTERMEDIATE investigation fallback prompt template at plugins/dso/skills/fix-bug/prompts/intermediate-investigation-fallback.md.

This prompt is for a general-purpose sub-agent (used when error-debugging:error-detective is not installed). It must cover the same root cause techniques as intermediate-investigation.md — difference is only the persona/role framing.

The prompt must:
- Same context slots as intermediate-investigation.md: {ticket_id}, {failing_tests}, {stack_trace}, {commit_history}, {prior_fix_attempts}
- Same investigation techniques: dependency-ordered code reading, intermediate variable tracking, five whys, hypothesis generation + elimination, self-reflection
- Same RESULT schema output (INTERMEDIATE+ fields): ROOT_CAUSE, confidence, proposed_fixes (at least 2), tests_run, prior_attempts, alternative_fixes, tradeoffs_considered, recommendation
- Same Rules section: investigation only, no source file edits, no sub-agent dispatch

The fallback prompt ensures that missing the error-debugging plugin does not reduce investigation quality — general-purpose agents following this prompt apply the same techniques.

TDD Requirement: Task w21-j4i9 (RED) already includes a test asserting the fallback file exists. That test FAILs (RED) until this file is created. Run python3 -m pytest tests/skills/test_intermediate_investigation_prompt.py::test_intermediate_investigation_fallback_file_exists — must PASS (GREEN) after this file is created.

