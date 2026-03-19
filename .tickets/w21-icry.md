---
id: w21-icry
status: closed
deps: [w21-8yqq]
links: []
created: 2026-03-19T05:43:59Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-c4ek
---
# GREEN: Update SKILL.md BASIC section to reference prompt template and define dispatch assembly

Update the BASIC Investigation section in plugins/dso/skills/fix-bug/SKILL.md to: (1) reference the prompt template at prompts/basic-investigation.md, and (2) include explicit context-assembly instructions for the orchestrator.

Changes to SKILL.md:
1. In the BASIC Investigation subsection (under Step 2), add: 'Dispatch using the prompt template at `prompts/basic-investigation.md`'
2. Add explicit context-assembly block showing how to populate the template placeholders:
   - {ticket_id}: the bug ticket ID
   - {failing_tests}: output of running TEST_CMD (failing test names and output)
   - {stack_trace}: stack trace from test output or error logs
   - {commit_history}: output of git log --oneline -20 -- <affected-files>
   - {prior_fix_attempts}: ticket notes containing fix attempt records
3. Add a note that the sub-agent must produce a RESULT conforming to the Investigation RESULT Report Schema defined in the same file

This update makes the dispatch logic explicit so any agent can assemble the correct prompt without guesswork.

TDD Requirement: After updating SKILL.md, run python3 -m pytest tests/skills/test_fix_bug_skill.py -k 'BasicInvestigation' — all tests must PASS (GREEN). This task depends on w21-8yqq (RED tests must exist first).

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] All BasicInvestigation tests PASS (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/skills/test_fix_bug_skill.py -k 'BasicInvestigation' -q && echo 'GREEN confirmed'
- [ ] SKILL.md BASIC section contains reference to 'basic-investigation.md'
  Verify: grep -q 'basic-investigation.md' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md BASIC section contains context-assembly instructions with named context slots
  Verify: grep -q 'failing_tests\|stack_trace\|commit_history' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py

## Notes

**2026-03-19T05:55:36Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T05:55:47Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T05:55:51Z**

CHECKPOINT 3/6: Tests written (RED tests exist) ✓

**2026-03-19T05:56:09Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T05:57:11Z**

CHECKPOINT 5/6: Tests GREEN (4/4 BasicInvestigation pass) ✓

**2026-03-19T05:57:11Z**

CHECKPOINT 6/6: Done ✓
