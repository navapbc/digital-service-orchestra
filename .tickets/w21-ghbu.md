---
id: w21-ghbu
status: open
deps: [w21-j4i9]
links: []
created: 2026-03-19T06:05:24Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-ahok
---
# GREEN: Create plugins/dso/skills/fix-bug/prompts/intermediate-investigation.md

Create the INTERMEDIATE investigation sub-agent prompt template at plugins/dso/skills/fix-bug/prompts/intermediate-investigation.md.

This prompt is for an opus sub-agent (error-debugging:error-detective). It extends the BASIC investigation template with additional techniques.

The prompt must:
- Begin with a role statement: opus-level investigator
- Include the same context slots as basic-investigation.md: {ticket_id}, {failing_tests}, {stack_trace}, {commit_history}, {prior_fix_attempts}
- Add dependency-ordered code reading: trace dependencies from the failure point outward before jumping to conclusions
- Add intermediate variable tracking: trace variable state at each step in the call chain
- Include five whys analysis (extends BASIC technique)
- Add hypothesis generation and elimination: generate multiple hypotheses, then systematically eliminate them with evidence
- Include self-reflection checkpoint before reporting root cause (extends BASIC technique)
- Produce a RESULT conforming to the Investigation RESULT Report Schema (INTERMEDIATE+ fields):
  - ROOT_CAUSE, confidence, proposed_fixes (at least 2), tests_run, prior_attempts, alternative_fixes, tradeoffs_considered, recommendation
- Rules section: investigation only, no source file edits, no sub-agent dispatch

The prompt should be composable with BASIC — shared structure and schema, extended with additional investigation techniques.

TDD Requirement: python3 -m pytest tests/skills/test_intermediate_investigation_prompt.py - all tests must PASS (GREEN) after this file is created.

