---
id: w21-ncn7
status: closed
deps: []
links: []
created: 2026-03-19T02:08:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-ag1b
---
# [TDD] Add pre-launch batch title display instruction to sprint skill

Add a 'Display Batch Task List' prose instruction to Phase 5 of plugins/dso/skills/sprint/SKILL.md, inserted between the 'Claim Tasks' and 'Blackboard Write' sections. The instruction must: (a) direct the orchestrator to print a numbered list of [ID: Title] pairs for all tasks in the batch before dispatching any sub-agents, (b) include a concrete example: '1. [dso-abc1] Fix authentication bug', (c) note that titles are parsed from the TASK: tab-separated lines produced by sprint-next-batch.sh — no additional tk show calls needed.

TDD Requirement:
- Before editing SKILL.md, create tests/skills/test_sprint_batch_title_display.py following the pattern in tests/skills/test_implementation_plan_skill_tdd_enforcement.py
- Write test_sprint_skill_contains_pre_launch_title_list that reads plugins/dso/skills/sprint/SKILL.md and asserts: (1) 'Display Batch Task List' appears within Phase 5 section bounds, AND (2) a concrete example format '1. [' appears within that same bounded section. Use regex section extraction between Phase 5 heading and next Phase heading.
- RED proof: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_sprint_batch_title_display.py::test_sprint_skill_contains_pre_launch_title_list --tb=short — confirm non-zero exit
- GREEN proof: after adding instruction, re-run — confirm zero exit + '1 passed'
- Commit test + implementation together as a single atomic unit

Pre-check: ! grep -q 'Display Batch Task List' plugins/dso/skills/sprint/SKILL.md — additive only, no cleanup needed.

## File Impact
- CREATE: tests/skills/test_sprint_batch_title_display.py
- EDIT: plugins/dso/skills/sprint/SKILL.md (Phase 5, between 'Claim Tasks' and 'Blackboard Write')

## ACCEPTANCE CRITERIA
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file exists at tests/skills/test_sprint_batch_title_display.py
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_sprint_batch_title_display.py
- [ ] SKILL.md contains 'Display Batch Task List' section header
  Verify: grep -q 'Display Batch Task List' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] SKILL.md Phase 5 instruction includes a concrete numbered-list example
  Verify: grep -q '1\. \[' $(git rev-parse --show-toplevel)/plugins/dso/skills/sprint/SKILL.md
- [ ] Test test_sprint_skill_contains_pre_launch_title_list passes (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_sprint_batch_title_display.py::test_sprint_skill_contains_pre_launch_title_list -q


## Notes

**2026-03-19T02:25:43Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T02:26:34Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T02:26:58Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-19T02:30:12Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-19T02:32:57Z**

CHECKPOINT 6/6: Done ✓

**2026-03-19T02:35:42Z**

CHECKPOINT 6/6: Done ✓ — Files: plugins/dso/skills/sprint/SKILL.md (added Display Batch Task List section), tests/skills/test_sprint_batch_title_display.py (created). Tests: 1 passed. All AC verified.
