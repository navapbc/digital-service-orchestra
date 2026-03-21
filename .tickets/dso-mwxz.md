---
id: dso-mwxz
status: closed
deps: []
links: []
created: 2026-03-21T21:15:30Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-1as4
---
# Write RED test: complexity-evaluator agent file exists with required frontmatter and content

Write a failing pytest test asserting the state of plugins/dso/agents/complexity-evaluator.md BEFORE the agent file is created.

TDD Requirement: Write test first, verify it FAILS (RED), then Task 2 creates the agent file to make it GREEN.

Test file: tests/skills/test_complexity_evaluator_agent.py

The test must assert ALL of:
1. plugins/dso/agents/complexity-evaluator.md exists (will fail before Task 2)
2. YAML frontmatter contains 'name: complexity-evaluator'
3. YAML frontmatter contains 'model: haiku'
4. YAML frontmatter contains 'tools:' with Bash, Read, Glob, Grep listed
5. Markdown body contains 5-dimension rubric content
6. Markdown body contains the tier_schema mechanism (tier vocabulary selector)
7. Markdown body does NOT contain context-specific routing table
8. Markdown body contains epic-specific qualitative override dimensions marked as epic-only

Follow pattern from tests/skills/test_sprint_batch_title_display.py: pathlib.Path, .read_text(), one test function per assertion group.

No dependencies (first task in plan).


## ACCEPTANCE CRITERIA

- [ ] tests/skills/test_complexity_evaluator_agent.py exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_complexity_evaluator_agent.py
- [ ] Test file contains at least 3 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_complexity_evaluator_agent.py | awk '{exit ($1 < 3)}'
- [ ] Test currently FAILS (RED) — agent file does not yet exist
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_complexity_evaluator_agent.py -x --tb=short 2>&1 | grep -qE 'FAILED|FileNotFoundError|AssertionError'
- [ ] ruff check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_complexity_evaluator_agent.py
- [ ] ruff format --check passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_complexity_evaluator_agent.py

## Notes

**2026-03-21T21:48:57Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T21:49:40Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T21:50:19Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-21T21:50:53Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T21:50:53Z**

CHECKPOINT 5/6: Validation passed ✓ — 9 tests fail RED as required; ruff check and ruff format --check both pass

**2026-03-21T21:51:15Z**

CHECKPOINT 6/6: Done ✓ — all 5 ACs verified: file exists, 9 test functions (>3), tests fail RED (FAILED/FileNotFoundError), ruff check passes, ruff format --check passes

**2026-03-21T21:59:29Z**

CHECKPOINT 6/6: Done ✓ — Files: tests/skills/test_complexity_evaluator_agent.py. Tests: 9 RED (expected). Batch 1.
