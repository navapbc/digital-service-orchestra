---
id: w21-vlje
status: closed
deps: []
links: []
created: 2026-03-19T05:43:23Z
type: task
priority: 0
assignee: Joe Oakhart
parent: w21-c4ek
---
# RED: Write failing tests for basic-investigation.md prompt template

Write tests/skills/test_basic_investigation_prompt.py asserting that plugins/dso/skills/fix-bug/prompts/basic-investigation.md exists and contains required content. Tests FAIL (RED) because the file does not exist yet — this is the expected RED state before Task 3 implements the prompt template.

Required test assertions (8 test functions minimum):
1. File exists at plugins/dso/skills/fix-bug/prompts/basic-investigation.md
2. Contains structured localization language: 'file', 'class' or 'function', and 'line' (identifies location of bug)
3. Contains 'five whys' (five whys analysis technique)
4. Contains 'self-reflection' (sub-agent self-reflection before reporting root cause)
5. Contains 'ROOT_CAUSE' (RESULT schema field conforming to S1's schema)
6. Contains 'confidence' (RESULT schema field)
7. Contains context placeholder tokens for pre-loaded context: '{failing_tests}', '{stack_trace}', '{commit_history}'
8. Contains 'RESULT' output section marker

Follow pattern in tests/skills/test_fix_bug_skill.py: pathlib REPO_ROOT, standalone test functions, clear assertion messages.

TDD Requirement: Run python3 -m pytest tests/skills/test_basic_investigation_prompt.py — all tests must FAIL (RED) before Task 3 is implemented.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` returns FAILED/ERROR on test_basic_investigation_prompt.py (RED confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python3 -m pytest tests/skills/test_basic_investigation_prompt.py -q 2>&1 | grep -qE 'FAILED|ERROR' && echo 'RED confirmed'
- [ ] Test file exists at tests/skills/test_basic_investigation_prompt.py
  Verify: test -f $(git rev-parse --show-toplevel)/tests/skills/test_basic_investigation_prompt.py
- [ ] Test file contains at least 8 test functions
  Verify: grep -c 'def test_' $(git rev-parse --show-toplevel)/tests/skills/test_basic_investigation_prompt.py | awk '{exit ($1 < 8)}'
- [ ] `ruff check` passes on the test file (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_basic_investigation_prompt.py
- [ ] `ruff format --check` passes on the test file (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_basic_investigation_prompt.py

## Notes

**2026-03-19T05:46:58Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-19T05:47:08Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-19T05:47:33Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-19T05:47:36Z**

CHECKPOINT 4/6: Implementation complete (RED test — no impl needed) ✓

**2026-03-19T05:47:59Z**

CHECKPOINT 5/6: RED confirmed — 12/12 tests fail (FileNotFoundError: basic-investigation.md does not exist yet) ✓

**2026-03-19T05:47:59Z**

CHECKPOINT 6/6: Done ✓ — AC verify: RED confirmed, file exists, 12 test functions (≥8), ruff check pass, ruff format pass
