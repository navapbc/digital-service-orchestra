---
id: dso-bgqs
status: open
deps: [dso-p9i6]
links: []
created: 2026-03-19T18:36:36Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-9pp1
---
# GREEN: Expand SKILL.md ESCALATED section with dispatch context slots, veto logic, resolution agent dispatch, and terminal escalation

## Description

Expand the stub ESCALATED Investigation section in `plugins/dso/skills/fix-bug/SKILL.md` to match the detail level of the ADVANCED Investigation section.

**File to edit**: `plugins/dso/skills/fix-bug/SKILL.md`

**Implementation steps**:
1. Locate the `#### ESCALATED Investigation` section (currently lines ~205-215)
2. Replace the stub content with a full dispatch specification including:
   - **Four agents** with their roles and prompt template paths:
     - Agent 1 (Web Researcher) → `prompts/escalated-investigation-agent-1.md` (authorized to use WebSearch/WebFetch)
     - Agent 2 (History Analyst) → `prompts/escalated-investigation-agent-2.md`
     - Agent 3 (Code Tracer) → `prompts/escalated-investigation-agent-3.md`
     - Agent 4 (Empirical Agent) → `prompts/escalated-investigation-agent-4.md` (authorized to add logging/debugging)
   - **Context dispatch slots table** (same format as ADVANCED section): `ticket_id`, `failing_tests`, `stack_trace`, `commit_history`, `prior_fix_attempts`, plus `escalation_history` (previous ADVANCED RESULT report and discovery file contents)
   - **Dispatch concurrency**: dispatch all four agents before awaiting any result
   - **Veto logic**: if Agent 4 empirically disproves the consensus root cause from agents 1-3 (e.g., logging shows a different call path), Agent 4's finding is a veto that triggers resolution agent dispatch
   - **Resolution agent**: receives all four RESULT reports, weighs evidence, conducts additional targeted tests to break any remaining tie; surfaces the highest-confidence conclusion
   - **Terminal escalation**: if ESCALATED investigation (with or without resolution agent) cannot produce a high-confidence root cause, log `ESCALATED terminal — user escalation required`, surface all findings to the user, and do NOT attempt any fix
   - **Artifact revert requirement**: Agent 4's logging/debugging additions must be reverted or stashed after evidence is collected — investigation artifacts must not persist; findings go in the investigation report
3. Run `python -m pytest tests/skills/test_fix_bug_skill_escalated_section.py -q` — all 8 tests must PASS (GREEN)

**TDD Requirement**: Tests from task dso-p9i6 must FAIL before this task. Run `python -m pytest tests/skills/test_fix_bug_skill_escalated_section.py -q` after editing; all 8 must pass.

**Constraints**:
- Preserve `/dso:fix-bug` namespace qualification in any new prose references
- Match the formatting style of the ADVANCED Investigation section (same heading level, same context slot table format)
- Do NOT alter the ADVANCED section, BASIC section, INTERMEDIATE section, or any non-ESCALATED content

## ACCEPTANCE CRITERIA

- [ ] All 8 tests in `test_fix_bug_skill_escalated_section.py` PASS (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_bug_skill_escalated_section.py -q 2>&1 | grep -q 'passed'
- [ ] SKILL.md contains `escalation_history` slot reference
  Verify: grep -q 'escalation_history' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md references all four escalated agent prompt files
  Verify: grep -q 'escalated-investigation-agent-1.md' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md && grep -q 'escalated-investigation-agent-4.md' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md contains veto logic language (`veto`)
  Verify: grep -q 'veto' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md contains resolution agent language
  Verify: grep -q 'resolution agent' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md contains terminal escalation language
  Verify: grep -q 'terminal' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] SKILL.md is valid (file exists and is non-empty)
  Verify: test -s $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] `check-skill-refs.sh` passes (no unqualified skill references in edited SKILL.md)
  Verify: cd $(git rev-parse --show-toplevel) && bash plugins/dso/scripts/check-skill-refs.sh
- [ ] SKILL.md ESCALATED section specifies agents 1-3 dispatch before Agent 4 (sequential constraint documented)
  Verify: grep -qE 'agents 1-3|agents 1, 2, and 3|await.*agents' $(git rev-parse --show-toplevel)/plugins/dso/skills/fix-bug/SKILL.md
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
