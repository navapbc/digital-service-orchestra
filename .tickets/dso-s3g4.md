---
id: dso-s3g4
status: open
deps: [dso-12ap]
links: []
created: 2026-03-19T06:04:56Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-slh5
---
# RED: Write failing Python tests for cluster-investigation prompt template

## Description

Add a `TestClusterInvestigationPrompt` class to `tests/skills/test_fix_bug_skill.py` with failing tests that assert the `cluster-investigation.md` prompt template exists and contains required content. All tests must FAIL before the implementation task runs (RED phase).

**File to edit**: `tests/skills/test_fix_bug_skill.py`

**Prompt file path**: `plugins/dso/skills/fix-bug/prompts/cluster-investigation.md`

**Tests to add** (class `TestClusterInvestigationPrompt`):

1. `test_cluster_prompt_file_exists` — asserts `plugins/dso/skills/fix-bug/prompts/cluster-investigation.md` exists
2. `test_cluster_prompt_contains_multiple_ticket_ids_slot` — asserts the prompt contains `{ticket_ids}` placeholder for receiving multiple bug IDs
3. `test_cluster_prompt_contains_single_investigation_instruction` — asserts the prompt instructs investigation as a single problem (language like "single problem", "investigate together", "unified investigation")
4. `test_cluster_prompt_contains_split_instruction` — asserts the prompt contains splitting logic for independent root causes (language like "independent root cause", "per-root-cause", "split")
5. `test_cluster_prompt_contains_result_schema_reference` — asserts the prompt contains RESULT schema output instructions (conforming to the shared Investigation RESULT Report Schema)

**TDD Requirement**: Write these tests FIRST. Run them to confirm they FAIL (RED). Do NOT create the prompt file yet.

**Implementation steps**:
1. Open `tests/skills/test_fix_bug_skill.py`
2. Add `CLUSTER_PROMPT_FILE = REPO_ROOT / "plugins" / "dso" / "skills" / "fix-bug" / "prompts" / "cluster-investigation.md"` constant after the existing `SKILL_FILE` constant
3. Add class `TestClusterInvestigationPrompt` with five test methods
4. Run `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigationPrompt -v` and confirm all 5 tests FAIL

## ACCEPTANCE CRITERIA

- [ ] `python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigationPrompt` exits non-zero (RED phase confirmed)
  Verify: cd $(git rev-parse --show-toplevel) && python -m pytest tests/skills/test_fix_bug_skill.py::TestClusterInvestigationPrompt 2>&1; test $? -ne 0
- [ ] Class `TestClusterInvestigationPrompt` exists in `tests/skills/test_fix_bug_skill.py`
  Verify: grep -q 'class TestClusterInvestigationPrompt' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py
- [ ] All five test functions exist in the class
  Verify: grep -c 'def test_cluster_prompt_' $(git rev-parse --show-toplevel)/tests/skills/test_fix_bug_skill.py | awk '{exit ($1 < 5)}'
- [ ] `ruff check` passes on the test file (no lint errors)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check tests/skills/test_fix_bug_skill.py
- [ ] `ruff format --check` passes on the test file (no format errors)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check tests/skills/test_fix_bug_skill.py
