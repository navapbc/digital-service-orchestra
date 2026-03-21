---
id: dso-jny6
status: open
deps: [dso-4lbf]
links: []
created: 2026-03-21T17:59:51Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-l60c
---
# RED: Write failing tests for .test-index auto-prune and auto-stage in test-pre-commit-test-gate.sh

Add test functions to tests/hooks/test-pre-commit-test-gate.sh covering:
  1. test_gate_index_prune_stale_entry — .test-index entry whose test file does not exist is removed from the index file on disk and the modified index is staged during pre-commit
  2. test_gate_index_prune_removes_line_when_all_stale — if all test paths for a source entry are nonexistent, the entire source line is removed
  3. test_gate_index_prune_stages_modified_index — after pruning, the modified .test-index is staged (git add .test-index executed within the hook)
  4. test_gate_index_prune_partial — source entry with one valid + one stale test path: stale path removed, valid path retained, line preserved

  TDD requirement: All four tests must FAIL before Task E is implemented.
  Tests must inspect both the on-disk .test-index content and the git staging area to verify the auto-stage behavior.
  Use run_gate_hook (or a variant that does not suppress stderr) to allow inspecting side effects.

  File to edit: tests/hooks/test-pre-commit-test-gate.sh
  Add functions and run_test calls.

## ACCEPTANCE CRITERIA

- [ ] Test file tests/hooks/test-pre-commit-test-gate.sh contains test_gate_index_prune_stale_entry
  Verify: grep -q 'test_gate_index_prune_stale_entry' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Test file contains test_gate_index_prune_removes_line_when_all_stale
  Verify: grep -q 'test_gate_index_prune_removes_line_when_all_stale' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Test file contains test_gate_index_prune_stages_modified_index
  Verify: grep -q 'test_gate_index_prune_stages_modified_index' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] Test file contains test_gate_index_prune_partial
  Verify: grep -q 'test_gate_index_prune_partial' $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh
- [ ] All four prune tests FAIL pre-implementation
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -E 'FAIL.*test_gate_index_prune'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py 2>/dev/null || true
- [ ] ruff format check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py 2>/dev/null || true
