---
id: w21-7juc
status: open
deps: [w21-s63d]
links: []
created: 2026-03-19T15:20:37Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-nl5m
---
# GREEN: Update debug-everything SKILL.md Phase 5 to delegate bug resolution to dso:fix-bug

Update plugins/dso/skills/debug-everything/SKILL.md Phase 5 (Sub-Agent Fix Batches) to delegate individual bug and cluster resolution to dso:fix-bug instead of using fix-task-tdd.md and fix-task-mechanical.md.

Changes required:
1. Phase 5 'Sub-Agent Prompt Template' section: Replace the template selection logic ('TDD required -> fix-task-tdd.md / TDD not required -> fix-task-mechanical.md') with dso:fix-bug invocation. For individual bugs, delegate to: /dso:fix-bug <bug-id>. For clusters, delegate to: /dso:fix-bug <id1> <id2> ... (cluster mode). The dso:fix-bug skill handles its own TDD enforcement and investigation routing.

2. Triage-to-scoring-rubric mapping (satisfies SC8 done definition): When delegating to dso:fix-bug, pass triage severity/complexity classification as pre-loaded context so fix-bug's scoring rubric does not need to re-classify from scratch. Add a mapping section explaining how triage tier maps to scoring dimensions:
   - Tier 0-1 (mechanical): fix-bug classifies as mechanical, bypasses scoring
   - Tier 2+ (behavioral bugs): provide severity from triage priority (P0=critical/2pts, P1=high/2pts, P2=medium/1pt, P3=low/0pts) and complexity classification from Phase 2.5 complexity gate output, environment from triage report (CI failure/staging notes)
   This allows fix-bug to inherit the triage classification rather than re-score.

3. Preserve file ownership context ({file_ownership_context}) — it must still be injected as context when invoking dso:fix-bug.

4. Preserve all other Phase 5 behavior (blackboard, file overlap, critic review, commit workflow).

TDD REQUIREMENT: Tests in tests/skills/test_debug_everything_delegates_to_fix_bug.py must PASS (GREEN) after this change. Run: python -m pytest tests/skills/test_debug_everything_delegates_to_fix_bug.py -v

Also verify full test suite: python -m pytest tests/skills/ -v --tb=short

## ACCEPTANCE CRITERIA

- [ ] `python -m pytest tests/skills/test_debug_everything_delegates_to_fix_bug.py -v` passes (GREEN)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_debug_everything_delegates_to_fix_bug.py -v 2>&1 | grep -q "passed"
- [ ] debug-everything SKILL.md Phase 5 references 'dso:fix-bug' (not fix-task-tdd.md or fix-task-mechanical.md as primary path)
  Verify: cd $(git rev-parse --show-toplevel) && grep -q "dso:fix-bug" plugins/dso/skills/debug-everything/SKILL.md
- [ ] debug-everything SKILL.md contains triage-to-scoring-rubric mapping language
  Verify: cd $(git rev-parse --show-toplevel) && grep -q "scoring rubric\|triage.*classification\|severity.*scoring\|tier.*mapping" plugins/dso/skills/debug-everything/SKILL.md
- [ ] `python -m pytest tests/skills/ -v --tb=short` passes (no regressions)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/ -v --tb=short 2>&1 | tail -5
