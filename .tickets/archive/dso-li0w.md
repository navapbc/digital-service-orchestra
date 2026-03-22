---
id: dso-li0w
status: closed
deps: [dso-jny6, dso-xf8w]
links: []
created: 2026-03-21T18:00:23Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-l60c
---
# IMPL: Add auto-prune and auto-stage of .test-index to pre-commit-test-gate.sh

Implement auto-pruning of stale .test-index entries and auto-staging of the modified index in plugins/dso/hooks/pre-commit-test-gate.sh.

  Changes required:
  1. Add prune_test_index() function:
     - Called once at the start of the gate run (after REPO_ROOT and .test-index presence are confirmed)
     - For each source line in .test-index, filter out test paths that do not exist on disk
     - If all test paths for a source entry are removed (all stale), remove the entire line
     - If right-hand side becomes empty after pruning, remove the line
     - If any pruning occurred, write the modified .test-index to disk (atomic write: write to .test-index.tmp, then mv)
     - After writing, run: git -C "$REPO_ROOT" add .test-index  (auto-stage the modified index)
     - Log to stderr: 'pre-commit-test-gate: pruned N stale entries from .test-index, re-staged'
  2. Call prune_test_index() before the STAGED_FILES loop
  3. Edge case: if .test-index does not exist, prune_test_index() returns immediately (no-op)
  4. Concurrent commit safety: use flock or ensure atomic writes (write to .test-index.tmp first, then mv) to handle concurrent pre-commit runs
  5. Partial write protection: the mv from .test-index.tmp to .test-index is atomic on POSIX filesystems

  TDD: Tests from Task dso-jny6 (test_gate_index_prune_stale_entry, test_gate_index_prune_removes_line_when_all_stale, test_gate_index_prune_stages_modified_index, test_gate_index_prune_partial) must go GREEN.

  File: plugins/dso/hooks/pre-commit-test-gate.sh

## ACCEPTANCE CRITERIA

- [ ] prune_test_index function exists in pre-commit-test-gate.sh
  Verify: grep -q 'prune_test_index' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] Stale entries are pruned from .test-index on disk
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_index_prune_stale_entry'
- [ ] Source line is removed when all test paths are stale
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_index_prune_removes_line_when_all_stale'
- [ ] Modified .test-index is auto-staged after pruning
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_index_prune_stages_modified_index'
- [ ] Partial prune retains valid paths, removes only stale ones
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_index_prune_partial'
- [ ] Atomic write uses tmp file + mv pattern
  Verify: grep -q 'test-index.tmp' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] git add failure in prune_test_index is handled gracefully (warning to stderr, hook continues)
  Verify: grep -q 'add.*test-index.*||\|git.*add.*test-index.*warn' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh || grep -A3 'git.*add.*test-index' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh | grep -q '||\|warn\|echo.*WARNING'

## Notes

<!-- note-id: 50zdli9u -->
<!-- timestamp: 2026-03-21T19:39:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: u2yvph2d -->
<!-- timestamp: 2026-03-21T19:39:55Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: js82ennd -->
<!-- timestamp: 2026-03-21T19:40:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (RED tests pre-exist with guards) ✓

<!-- note-id: c3t7wai1 -->
<!-- timestamp: 2026-03-21T19:40:30Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: 83d0u1bs -->
<!-- timestamp: 2026-03-21T19:41:32Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: 50dwk4ks -->
<!-- timestamp: 2026-03-21T19:41:36Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
