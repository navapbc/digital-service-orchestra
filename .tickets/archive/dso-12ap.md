---
id: dso-12ap
status: closed
deps: []
links: []
created: 2026-03-19T06:04:50Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-slh5
---
# RED: Write failing Python tests for cluster investigation in SKILL.md

## Description

Add a `TestClusterInvestigation` class to `tests/skills/test_fix_bug_skill.py` with failing tests that assert SKILL.md contains the required cluster investigation content. All tests must FAIL before the implementation task runs (RED phase).

**File to edit**: `tests/skills/test_fix_bug_skill.py`

**Tests to add** (class `TestClusterInvestigation`):

1. `test_skill_accepts_multiple_bug_ids` — asserts SKILL.md contains language indicating it accepts multiple bug IDs (e.g., "cluster" keyword, "multiple bug IDs" phrase, or "cluster invocation")
2. `test_skill_cluster_investigates_as_single_problem` — asserts SKILL.md contains language specifying that multiple bugs are investigated as a single problem (e.g., "single problem", "investigate as a single problem", "cluster investigation")
3. `test_skill_splits_on_independent_root_causes` — asserts SKILL.md contains language about splitting into per-root-cause tracks only when multiple independent root causes are identified (e.g., "independent root cause", "per-root-cause track", "split into")
4. `test_skill_cluster_references_prompt_template` — asserts SKILL.md contains a reference to `cluster-investigation.md` prompt template

**TDD Requirement**: Write these tests FIRST. Run them to confirm they FAIL (RED). Do NOT implement the SKILL.md changes yet.

**Implementation steps**:
1. Open `tests/skills/test_fix_bug_skill.py`
2. Add class `TestClusterInvestigation` after the existing `TestBasicInvestigationSkillIntegration` class
3. Implement the four test methods asserting on `_read_skill()` content
4. Run `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigation -v` and confirm all 4 tests FAIL

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` exits with test failures for the new cluster tests (RED phase confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigation 2>&1; test $? -ne 0
- [ ] Class `TestClusterInvestigation` exists in `tests/skills/test_fix_bug_skill.py`
  Verify: grep -q 'class TestClusterInvestigation' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] All four test functions exist in the class
  Verify: grep -c 'def test_skill_' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py | awk '{exit ($1 < 16)}'
- [ ] `ruff check` passes on the test file (no lint errors)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_fix_bug_skill.py
- [ ] `ruff format --check` passes on the test file (no format errors)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_fix_bug_skill.py
