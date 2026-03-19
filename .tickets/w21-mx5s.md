---
id: w21-mx5s
status: open
deps: [w21-0xmw, w21-7juc]
links: []
created: 2026-03-19T15:21:02Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-nl5m
---
# GREEN: Retire fix-task-tdd.md and fix-task-mechanical.md with forward pointers to dso:fix-bug

Add deprecation/forward-pointer notices to:
1. plugins/dso/skills/debug-everything/prompts/fix-task-tdd.md
2. plugins/dso/skills/debug-everything/prompts/fix-task-mechanical.md

These files are no longer selected by debug-everything Phase 5 (replaced in the GREEN task above). Add a notice at the top of each file stating this file is retired and that bug resolution is now delegated to dso:fix-bug. Do NOT delete the files — they serve as documentation of the previous approach and may be referenced by existing sub-agents that were dispatched before the upgrade.

Format for each file (prepend to existing content):
> **DEPRECATED**: This prompt template is no longer used by debug-everything. Bug resolution is now delegated to `/dso:fix-bug`. See `plugins/dso/skills/fix-bug/SKILL.md` for the current workflow.

Preserve all existing content below the notice.

TDD REQUIREMENT: Tests in tests/skills/test_fix_task_prompts_retired.py must PASS (GREEN) after this change. Run: python -m pytest tests/skills/test_fix_task_prompts_retired.py -v

Also verify: python -m pytest tests/skills/ -v --tb=short

## ACCEPTANCE CRITERIA

- [ ] `python -m pytest tests/skills/test_fix_task_prompts_retired.py -v` passes (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_task_prompts_retired.py -v 2>&1 | grep -q "passed"
- [ ] fix-task-tdd.md contains 'DEPRECATED' or 'dso:fix-bug' forward pointer at the top
  Verify: cd $(git rev-parse --show-toplevel) && head -5 plugins/dso/skills/debug-everything/prompts/fix-task-tdd.md | grep -qiE "deprecated|dso:fix-bug"
- [ ] fix-task-mechanical.md contains 'DEPRECATED' or 'dso:fix-bug' forward pointer at the top
  Verify: cd $(git rev-parse --show-toplevel) && head -5 plugins/dso/skills/debug-everything/prompts/fix-task-mechanical.md | grep -qiE "deprecated|dso:fix-bug"
- [ ] `python -m pytest tests/skills/ -v --tb=short` passes (no regressions)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/ -v --tb=short 2>&1 | tail -5
