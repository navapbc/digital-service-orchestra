---
id: w22-zggi
status: closed
deps: []
links: []
created: 2026-03-22T07:01:14Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-9ltc
---
# RED: Write failing unit tests for build-review-agents.sh

TDD RED phase: Write failing unit tests for build-review-agents.sh before the script exists.

Test file: tests/unit/scripts/test-build-review-agents.sh

Tests to write (all must fail RED before implementation):
1. test_build_produces_6_agent_files - runs build script with fixture base+delta; asserts 6 agent files in output dir
2. test_build_agent_list_matches_delta_files - asserts declared agent list in script matches delta files on disk
3. test_build_atomic_write_on_failure - missing delta causes no partial output files written
4. test_build_embeds_content_hash - each generated file contains a content hash of its source inputs

Approach: create fixture dir with minimal reviewer-base.md and 6 reviewer-delta-*.md files; run script against temp output dir; assert expected outcomes.

Fuzzy-match verification: normalized source 'buildreviewagentssh' IS a substring of normalized test 'testbuildreviewagentssh' - no .test-index entry needed.


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Test file tests/unit/scripts/test-build-review-agents.sh exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/unit/scripts/test-build-review-agents.sh
- [ ] Test file contains all 4 required test functions
  Verify: grep -c 'test_build_' $(git rev-parse --show-toplevel)/tests/unit/scripts/test-build-review-agents.sh | awk '{exit ($1 < 4)}'
- [ ] Tests return non-zero when build-review-agents.sh does not exist (RED confirmed)
  Verify: bash $(git rev-parse --show-toplevel)/tests/unit/scripts/test-build-review-agents.sh 2>/dev/null; test $? -ne 0

## Notes

**2026-03-22T10:06:41Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-22T10:07:20Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-22T10:08:57Z**

CHECKPOINT 3/6: Tests written ✓

**2026-03-22T10:09:01Z**

CHECKPOINT 4/6: Implementation complete ✓ (no implementation needed — RED tests only)

**2026-03-22T10:09:09Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-22T11:07:33Z**

CHECKPOINT 6/6: Done ✓
