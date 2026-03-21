---
id: dso-76r3
status: open
deps: [dso-xf8w]
links: []
created: 2026-03-21T18:00:45Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w22-l60c
---
# IMPL: Exclude .test-index from compute-diff-hash.sh and review-gate-allowlist.conf

Add .test-index to the hash exclusion list so that auto-staged .test-index changes do not invalidate the diff hash recorded by the review gate.

  Changes required:
  1. plugins/dso/hooks/lib/review-gate-allowlist.conf:
     - Add '.test-index' as an excluded pattern (under a new comment '# Test index metadata')
     - This causes compute-diff-hash.sh (which reads the allowlist) to exclude .test-index from the hash
     - It also causes pre-commit-review-gate.sh to not require review for .test-index-only changes

  2. plugins/dso/hooks/compute-diff-hash.sh:
     - No direct code change required — the allowlist-to-pathspecs mechanism in deps.sh automatically picks up the new pattern from review-gate-allowlist.conf
     - Verify via test that after adding a .test-index change to staging, the hash does NOT change (i.e., .test-index is excluded)

  TDD:
  - Write test_hash_excludes_test_index in tests/hooks/test-compute-diff-hash.sh (if the file exists) or as a new bash test function:
    - Stage a source file and record hash H1
    - Write and stage .test-index
    - Recompute hash H2
    - Assert H1 == H2 (staging .test-index does not change the hash)
  - Test must be RED before this task is implemented (i.e., currently .test-index IS included in the hash)

  File: plugins/dso/hooks/lib/review-gate-allowlist.conf
  Verify: bash tests/hooks/test-compute-diff-hash.sh (or the specific test function) exits 0


**Gap Analysis Amendment**: tests/hooks/test-compute-diff-hash.sh may not exist. This task must:
- Check if tests/hooks/test-compute-diff-hash.sh exists; if not, create it with the standard test file header (copying the pattern from test-pre-commit-test-gate.sh: set -uo pipefail, SCRIPT_DIR, PLUGIN_ROOT, source assert.sh, print_summary at end)
- Add test_hash_excludes_test_index as a new function in that file
- Add run_test test_hash_excludes_test_index and print_summary calls
The test must be verifiable whether the file already exists or is newly created by this task.

## ACCEPTANCE CRITERIA

- [ ] .test-index pattern added to review-gate-allowlist.conf
  Verify: grep -q '\.test-index' $(git rev-parse --show-toplevel)/plugins/dso/hooks/lib/review-gate-allowlist.conf
- [ ] Staging .test-index does not change the diff hash computed by compute-diff-hash.sh
  Verify: bash $(git rev-parse --show-toplevel)/tests/hooks/test-compute-diff-hash.sh 2>&1 | grep 'PASS.*test_hash_excludes_test_index'
- [ ] test_hash_excludes_test_index test function exists in tests/hooks/test-compute-diff-hash.sh
  Verify: grep -q 'test_hash_excludes_test_index' $(git rev-parse --show-toplevel)/tests/hooks/test-compute-diff-hash.sh
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
