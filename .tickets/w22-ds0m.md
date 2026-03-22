---
id: w22-ds0m
status: open
deps: []
links: []
created: 2026-03-22T07:03:31Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-9ltc
---
# RED: Write failing unit tests for hook_block_generated_reviewer_agents

TDD RED phase: Write failing unit tests for the hook function hook_block_generated_reviewer_agents before the function exists.

Test file: tests/hooks/test-edit-block-generated-agents.sh

Tests to write (all must fail RED before the hook is implemented):
1. test_hook_blocks_edit_to_generated_agent_file — input JSON with tool_name=Edit and file_path=plugins/dso/agents/code-reviewer-light.md; expects exit 2 and BLOCKED message with guidance pointing to source fragments and build-review-agents.sh
2. test_hook_blocks_write_to_generated_agent_file — same as above but tool_name=Write; expects exit 2
3. test_hook_allows_edit_to_non_generated_file — file_path=plugins/dso/agents/complexity-evaluator.md (not a generated reviewer); expects exit 0
4. test_hook_blocks_all_6_generated_reviewer_names — verifies each of the 6 code-reviewer-*.md names is blocked
5. test_hook_detects_conflict_markers_in_generated_file — file content includes <<<<<<< markers; expects exit 2 with regeneration guidance

Fuzzy-match check: test-edit-block-generated-agents.sh vs edit-block-generated-agents.sh
- Normalized source: 'editblockgeneratedagentssh'
- Normalized test: 'testeditblockgeneratedagentssh'
- 'editblockgeneratedagentssh' IS a substring ✓

No .test-index entry needed.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/hooks/test-edit-block-generated-agents.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/hooks/test-edit-block-generated-agents.sh
- [ ] Test file contains all 5 required test functions
  Verify: grep -c 'test_hook_' $(git rev-parse --show-toplevel)/tests/hooks/test-edit-block-generated-agents.sh | awk '{exit ($1 < 5)}'
- [ ] Tests return non-zero when hook function does not exist (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-edit-block-generated-agents.sh 2>/dev/null; test $? -ne 0
