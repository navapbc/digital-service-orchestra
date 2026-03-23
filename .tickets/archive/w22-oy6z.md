---
id: w22-oy6z
status: closed
deps: [w22-ds0m]
links: []
created: 2026-03-22T07:04:20Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-9ltc
---
# Create hook_block_generated_reviewer_agents and wire into pre-edit/write dispatchers

Implement the hook function that blocks direct edits/writes to generated agent files and wire it into the pre-edit and pre-write dispatchers.

Implementation:

1. Add hook function hook_block_generated_reviewer_agents to plugins/dso/hooks/lib/pre-edit-write-functions.sh:
   - Fires on Edit and Write tool calls
   - Extracts file_path from tool_input
   - Matches against pattern: plugins/dso/agents/code-reviewer-*.md (the 6 generated agents)
   - On match: exit 2 with stderr message explaining the file is auto-generated, pointing to source fragments in plugins/dso/docs/workflows/prompts/ and build-review-agents.sh as the regeneration command
   - Conflict marker detection: if file_path matches the generated pattern AND the new_string/content field contains <<<<<<< markers, exit 2 with specific regeneration guidance (post-conflict resolution: run build-review-agents.sh to regenerate from source; the embedded content hash ensures stale content is caught)
   - All other cases: exit 0 (fail-open)

2. Wire into dispatchers:
   - Add hook_block_generated_reviewer_agents to the hook function list in plugins/dso/hooks/dispatchers/pre-edit.sh (after existing hooks)
   - Add hook_block_generated_reviewer_agents to the hook function list in plugins/dso/hooks/dispatchers/pre-write.sh (after existing hooks)

After implementing, run the unit tests from task w22-ds0m to confirm GREEN.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] hook_block_generated_reviewer_agents is defined in pre-edit-write-functions.sh
  Verify: grep -q 'hook_block_generated_reviewer_agents' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/pre-edit-write-functions.sh
- [ ] Hook is wired into pre-edit dispatcher
  Verify: grep -q 'hook_block_generated_reviewer_agents' $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-edit.sh
- [ ] Hook is wired into pre-write dispatcher
  Verify: grep -q 'hook_block_generated_reviewer_agents' $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-write.sh
- [ ] Edit to code-reviewer-light.md is blocked (exit 2)
  Verify: echo '{"tool_name":"Edit","tool_input":{"file_path":"$(git rev-parse --show-toplevel)/plugins/dso/agents/code-reviewer-light.md","old_string":"a","new_string":"b"}}' | bash $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-edit.sh 2>/dev/null; test $? -eq 2
- [ ] Edit to complexity-evaluator.md is allowed (exit 0)
  Verify: echo '{"tool_name":"Edit","tool_input":{"file_path":"$(git rev-parse --show-toplevel)/plugins/dso/agents/complexity-evaluator.md","old_string":"a","new_string":"b"}}' | bash $(git rev-parse --show-toplevel)/plugins/dso/hooks/dispatchers/pre-edit.sh; test $? -eq 0
- [ ] Unit tests pass GREEN (all 5 test_hook_* functions)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-edit-block-generated-agents.sh

## Notes

**2026-03-22T09:20:15Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T09:20:24Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T09:20:52Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T09:21:57Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-22T09:22:18Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T09:56:39Z**

CHECKPOINT 6/6: Done ✓
