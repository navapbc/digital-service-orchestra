---
id: w21-znz7
status: open
deps: [w21-vlje]
links: []
created: 2026-03-19T05:43:46Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-c4ek
---
# GREEN: Create plugins/dso/skills/fix-bug/prompts/basic-investigation.md

Create the BASIC investigation prompt template at plugins/dso/skills/fix-bug/prompts/basic-investigation.md. This is the prompt sent to the sonnet sub-agent for BASIC-tier bug investigation.

File structure and required sections:
1. Header identifying this as a BASIC investigation sub-agent prompt
2. Context section with named placeholders: {ticket_id}, {failing_tests}, {stack_trace}, {commit_history}, {prior_fix_attempts}
3. Investigation instructions:
   a. Structured localization: identify the file, class/function, and line number where the bug originates
   b. Five whys analysis: apply the five whys technique to trace from symptom to root cause
   c. Self-reflection checkpoint: before reporting root cause, review whether the identified root cause fully explains all observed symptoms
4. RESULT output section specifying the exact output format conforming to S1's schema:
   - ROOT_CAUSE: one sentence
   - confidence: high | medium | low
   - proposed_fixes: array with description, risk, degrades_functionality, rationale
   - tests_run: array with hypothesis, command, result

Pattern: follow plugins/dso/skills/implementation-plan/prompts/gap-analysis.md — clear sections, explicit placeholders, output format as JSON or structured text.

TDD Requirement: After creating this file, run python3 -m pytest tests/skills/test_basic_investigation_prompt.py — all tests must PASS (GREEN). This task depends on w21-vlje (RED tests must exist first).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] prompt template file exists at plugins/dso/skills/fix-bug/prompts/basic-investigation.md
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts/basic-investigation.md
- [ ] All 8+ tests in tests/skills/test_basic_investigation_prompt.py PASS (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/skills/test_basic_investigation_prompt.py -q && echo 'GREEN confirmed'
- [ ] `ruff check` passes (exit 0) — no new lint violations introduced
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/skills/fix-bug/prompts/
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `plugins/dso/skills/fix-bug/prompts/` directory exists (create with mkdir -p if needed)
  Verify: test -d $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/prompts
