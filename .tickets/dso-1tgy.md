---
id: dso-1tgy
status: in_progress
deps: [dso-mwxz]
links: []
created: 2026-03-21T21:15:48Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1as4
---
# Create plugins/dso/agents/complexity-evaluator.md agent definition

Create the plugins/dso/agents/ directory (if not present) and the complexity-evaluator.md agent definition file.

TDD Requirement: Task dso-mwxz (RED test) must FAIL before this task executes. After this task, re-run the test to confirm GREEN.

The agent definition file must have:

## YAML Frontmatter (lines 1-N ending with ---)
- name: complexity-evaluator
- model: haiku
- tools: [Bash, Read, Glob, Grep]
- (optional) description: one-line summary

## Markdown Body
- Full 5-dimension rubric from plugins/dso/skills/shared/prompts/complexity-evaluator.md (Dimensions 1-5: Files, Layers, Interfaces, scope_certainty, Confidence) — copy the rubric thresholds and classification rules
- Tier schema selector mechanism: document that callers pass tier_schema=TRIVIAL (outputs: TRIVIAL/MODERATE/COMPLEX) or tier_schema=SIMPLE (outputs: SIMPLE/MODERATE/COMPLEX) as a task argument to select tier vocabulary
- Epic-only qualitative override dimensions: multiple personas, UI+backend, new DB migration, foundation/enhancement candidate, external integration — clearly marked 'Applicable when evaluating epics only'
- Done-definition check and single-concern check, marked 'Applicable when evaluating epics only'
- Classification rules and promotion rules
- Output schema (matching fields: classification, confidence, files_estimated, layers_touched, interfaces_affected, scope_certainty, reasoning + epic-only fields: qualitative_overrides, missing_done_definitions, single_concern)
- Procedure: Step 1 Load Context, Step 2 Find Files, Step 3 Apply Rubric, Step 4 Output

## Must NOT contain
- Context-specific routing tables (e.g., 'sprint MODERATE->COMPLEX', 'debug-everything de-escalate', brainstorm routing table) — these stay in each caller's SKILL.md

File placement: /Users/joeoakhart/digital-service-orchestra-worktrees/worktree-20260321-124341/plugins/dso/agents/complexity-evaluator.md


## ACCEPTANCE CRITERIA

- [ ] plugins/dso/agents/complexity-evaluator.md exists
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md
- [ ] YAML frontmatter contains name: complexity-evaluator
  Verify: grep -q 'name: complexity-evaluator' $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md
- [ ] YAML frontmatter contains model: haiku
  Verify: grep -q 'model: haiku' $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md
- [ ] Agent body contains 5-dimension rubric content
  Verify: grep -q 'Dimension' $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md
- [ ] Agent body contains tier_schema mechanism
  Verify: grep -q 'tier_schema' $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md
- [ ] Agent body does NOT contain context-specific routing table
  Verify: ! grep -q 'sprint story evaluator\|debug-everything\|de-escalate' $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md
- [ ] Agent body contains epic-only qualitative overrides
  Verify: grep -qi 'epic' $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md && grep -q 'multiple personas\|UI.*backend\|foundation' $(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md
- [ ] RED test (dso-mwxz) now passes GREEN
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_complexity_evaluator_agent.py -x --tb=short -q && echo PASS
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh

## Notes

**2026-03-21T22:24:11Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T22:24:14Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T22:24:54Z**

CHECKPOINT 3/6: Tests written ✓ (xfail markers removed)

**2026-03-21T22:26:06Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T22:28:11Z**

CHECKPOINT 5/6: Tests passing GREEN ✓ — 9/9 complexity evaluator tests pass, 462 total passed, 0 failures

**2026-03-21T22:28:16Z**

CHECKPOINT 6/6: Done ✓ — All 7 AC checks pass. Created plugins/dso/agents/complexity-evaluator.md. Removed xfail from 8 tests in tests/skills/test_complexity_evaluator_agent.py.
