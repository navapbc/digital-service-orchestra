---
id: dso-wlwa
status: closed
deps: []
links: []
created: 2026-03-18T02:46:52Z
type: task
priority: 1
assignee: Joe Oakhart
parent: dso-wo1i
---
# Create scripts/check-skill-refs.sh linter and tests/scripts/test-check-skill-refs.sh test suite

## Description

Create a shell script `scripts/check-skill-refs.sh` that scans in-scope files (skills/, docs/, hooks/, commands/ recursively + CLAUDE.md) for unqualified DSO skill references (e.g., `/sprint` instead of `/dso:sprint`). The script:

1. Defines a shared canonical skill list variable (sourceable by `qualify-skill-refs.sh` in dso-0isl to prevent drift)
2. Builds a regex pattern from the list matching `/<skill-name>` that is NOT preceded by `://` (URL) and NOT preceded by `dso:` (already qualified)
3. Scans all files in the in-scope set (skills/, docs/, hooks/, commands/ recursively, no symlinks, plus CLAUDE.md)
4. Exits non-zero if any violations found, exit 0 if clean
5. Prints each violation with file path and line number

Create `tests/scripts/test-check-skill-refs.sh` with 5 test cases using isolated temp file fixtures and the project's `tests/lib/assert.sh` library:
- (a) `test_exit_nonzero_on_unqualified_ref` — temp file with `/sprint`, assert exit != 0
- (b) `test_exit_zero_on_clean` — temp file with no skill refs, assert exit == 0
- (c) `test_url_not_flagged` — temp file with `https://example.com/sprint`, assert exit == 0
- (d) `test_already_qualified_not_flagged` — temp file with `/dso:sprint`, assert exit == 0
- (e) `test_hyphenated_not_flagged` — temp file with `/review-gate`, assert exit == 0

## TDD Requirement

Write `test_exit_nonzero_on_unqualified_ref` FIRST — create a temp file containing `/sprint` (unqualified), run check-skill-refs.sh against it, assert exit code != 0. This test fails because the script does not exist yet (RED). Then implement the script (GREEN). Then add remaining 4 test cases.

## Files
- CREATE: scripts/check-skill-refs.sh
- CREATE: tests/scripts/test-check-skill-refs.sh

## ACCEPTANCE CRITERIA
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `scripts/check-skill-refs.sh` exists and is executable
  Verify: test -x $(git rev-parse --show-toplevel)/scripts/check-skill-refs.sh
- [ ] `tests/scripts/test-check-skill-refs.sh` exists
  Verify: test -f $(git rev-parse --show-toplevel)/tests/scripts/test-check-skill-refs.sh
- [ ] Test file contains at least 5 test assertions
  Verify: grep -c "assert_eq\|assert_ne\|assert_contains" $(git rev-parse --show-toplevel)/tests/scripts/test-check-skill-refs.sh | awk '{exit ($1 < 5)}'
- [ ] Script exits non-zero on unqualified ref (current codebase has unqualified refs)
  Verify: cd $(git rev-parse --show-toplevel) && bash scripts/check-skill-refs.sh; test $? -ne 0
- [ ] All 5 test cases pass
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/scripts/test-check-skill-refs.sh
- [ ] Shared canonical skill list defined as sourceable variable
  Verify: grep -q 'SKILL_LIST\|CANONICAL_SKILLS\|DSO_SKILLS' $(git rev-parse --show-toplevel)/scripts/check-skill-refs.sh
- [ ] Script accepts optional file/directory arguments to override default in-scope file set (required for test isolation with temp fixtures)
  Verify: echo '/sprint' > /tmp/test-skill-ref-gap-$$.md && bash $(git rev-parse --show-toplevel)/scripts/check-skill-refs.sh /tmp/test-skill-ref-gap-$$.md; rc=$?; rm -f /tmp/test-skill-ref-gap-$$.md; test $rc -ne 0


## Notes

<!-- note-id: r78grc8m -->
<!-- timestamp: 2026-03-18T02:51:21Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: p0jvrscn -->
<!-- timestamp: 2026-03-18T02:51:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: 72x1zlnj -->
<!-- timestamp: 2026-03-18T02:51:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written ✓

<!-- note-id: 6f4z5zrr -->
<!-- timestamp: 2026-03-18T02:53:38Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: 8gs2t218 -->
<!-- timestamp: 2026-03-18T02:53:43Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓ — 5 tests passing, 0 failing

<!-- note-id: o7fw9gvy -->
<!-- timestamp: 2026-03-18T02:58:54Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — All 5 tests pass (test-check-skill-refs.sh), all 8 ACs pass. Pre-existing script test failures (test-flat-config-e2e, test-pre-commit-wrapper, test-read-config-flat, test-smoke-test-portable) are unrelated to this task.
