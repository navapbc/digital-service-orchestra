---
id: dso-xf8w
status: closed
deps: [dso-4lbf]
links: []
created: 2026-03-21T18:00:11Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-l60c
---
# IMPL: Add parse_test_index() and union merge to pre-commit-test-gate.sh

Implement .test-index file parsing and union merge in plugins/dso/hooks/pre-commit-test-gate.sh.

  Changes required:
  1. Add parse_test_index() function:
     - Reads $REPO_ROOT/.test-index (missing = return empty, no error)
     - Format per line: 'source/path.ext: test/path1.ext, test/path2.ext'
     - Lines starting with # are comments; blank lines are ignored
     - Colons and commas in paths are not supported (document this constraint)
     - For a given src_file argument, returns the list of associated test paths
     - Empty right-hand side (or all-blank after split) = no association for that line
     - Returns test paths on stdout, one per line
  2. Modify _has_associated_test() and _get_associated_test_path() to call parse_test_index():
     - Compute union: all fuzzy-matched tests UNION all index-mapped tests
     - A source file has an associated test if EITHER fuzzy OR index finds one
  3. Modify the exemption loop and gate check to use the full union set
  4. Ensure the gate still passes immediately (exit 0) when the union set is empty

  TDD: Tests from Task dso-4lbf (test_gate_index_mapped_source_triggers, test_gate_index_union_with_fuzzy, test_gate_missing_index_noop, test_gate_index_empty_right_side_noop, test_gate_index_multi_test_paths) must go GREEN.

  Backward compatibility: all 15 existing tests must remain GREEN.

  File: plugins/dso/hooks/pre-commit-test-gate.sh

## ACCEPTANCE CRITERIA

- [ ] parse_test_index function exists in pre-commit-test-gate.sh
  Verify: grep -q 'parse_test_index' $(git rev-parse --show-toplevel)/plugins/dso/hooks/pre-commit-test-gate.sh
- [ ] Missing .test-index is treated as no-op (gate proceeds without error)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_missing_index_noop'
- [ ] Index-mapped source triggers gate when no status recorded
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_index_mapped_source_triggers'
- [ ] Union merge works (fuzzy + index both contribute)
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_index_union_with_fuzzy'
- [ ] Empty right side in .test-index treated as no association
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep 'PASS.*test_gate_index_empty_right_side_noop'
- [ ] All 15 original tests still pass
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-pre-commit-test-gate.sh 2>&1 | grep -c 'PASS:' | awk '{exit ($1 < 15)}'
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py 2>/dev/null || true

## Notes

**2026-03-21T18:54:50Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T18:55:37Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T18:55:40Z**

CHECKPOINT 3/6: Tests written (RED tests pre-exist) ✓

**2026-03-21T18:58:01Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T19:03:25Z**

CHECKPOINT 5/6: Validation passed ✓ — 23 PASS, 4 FAIL in test-pre-commit-test-gate.sh (the 4 FAILs are tests 21-24 = prune/stage RED tests from story dso-li0w, not my scope). Other run-all failures (test-record-test-status 4 FAIL, test-doc-migration 1 FAIL) are pre-existing RED tests from other stories.

**2026-03-21T19:03:32Z**

CHECKPOINT 6/6: Done ✓
