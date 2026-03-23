---
id: dso-tdzq
status: in_progress
deps: [dso-qlyk]
links: []
created: 2026-03-23T20:29:31Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-gy45
---
# Write ROLLBACK-PROCEDURE.md documenting git revert recovery steps

Create plugins/dso/docs/ROLLBACK-PROCEDURE.md documenting how to independently revert the reference update commit (from story w21-wbqz) and/or the cleanup commit (from the finalize phase in this story).

## TDD Exemption
test-exempt: criterion 3 (static assets only) — this task produces only a Markdown documentation file with no executable logic. No conditional branches exist to test; any test would be a change-detector.

## Content Requirements

The document must cover:

1. Context: When to use this procedure — if post-cleanup validation fails or old system is needed
2. Pre-conditions: Confirm git tag 'pre-cleanup-migration' exists (recovery anchor)
3. Revert cleanup commit (independently revertible): find cleanup commit SHA, git revert, verify .tickets/ and tk script are restored
4. Revert reference update commit (independently revertible, from w21-wbqz): find ref update SHA, git revert, verify tk references restored
5. Full rollback (both commits reverted in reverse order): revert cleanup first, then reference update
6. Recovery from git tag: access old data via git show pre-cleanup-migration:.tickets/<ticket-id>.md
7. Dry-run verification: how to use --dry-run flag on cutover script to preview finalize phase

## File
plugins/dso/docs/ROLLBACK-PROCEDURE.md (new file)

## ACCEPTANCE CRITERIA
- [ ] bash tests/run-all.sh passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] ruff check passes (exit 0)
  Verify: ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ruff format check passes (exit 0)
  Verify: ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] ROLLBACK-PROCEDURE.md exists at correct path
  Verify: test -f plugins/dso/docs/ROLLBACK-PROCEDURE.md
- [ ] Document contains git revert procedure
  Verify: grep -q 'git revert' plugins/dso/docs/ROLLBACK-PROCEDURE.md
- [ ] Document references pre-cleanup-migration tag
  Verify: grep -q 'pre-cleanup-migration' plugins/dso/docs/ROLLBACK-PROCEDURE.md
- [ ] Document describes independent revertibility of both commits
  Verify: grep -q 'independently' plugins/dso/docs/ROLLBACK-PROCEDURE.md


## Notes

**2026-03-23T21:48:52Z**

CHECKPOINT 1/6: Reviewed ticket dso-tdzq. Task: write plugins/dso/docs/ROLLBACK-PROCEDURE.md covering pre-cleanup tag, independent revert of cleanup commit and reference update commit, full rollback, and git show for old data access.

**2026-03-23T21:49:01Z**

CHECKPOINT 2/6: Read cutover script — finalize phase creates pre-cleanup-migration tag, commits removal of .tickets/ dir, tk script, and test fixtures as cleanup commit. w21-wbqz story did atomic reference update (tk→ticket commands) as a separate commit. dry-run flag is --dry-run.

**2026-03-23T21:49:06Z**

CHECKPOINT 3/6: Test-exempt confirmed — ticket specifies 'test-exempt: criterion 3 (static assets only)'. This task produces only a Markdown file with no executable logic.

**2026-03-23T21:49:30Z**

CHECKPOINT 4/6: Wrote plugins/dso/docs/ROLLBACK-PROCEDURE.md — covers pre-conditions (tag check), independent revert of cleanup commit, independent revert of reference update commit, full rollback (both commits in reverse order), git show from pre-cleanup-migration tag, and --dry-run preview.

**2026-03-23T21:49:39Z**

CHECKPOINT 5/6: Validated — file exists at plugins/dso/docs/ROLLBACK-PROCEDURE.md; 'git revert' appears 6 times; 'pre-cleanup-migration' appears 3 times; 'independently' appears 3 times. All acceptance criteria grep checks pass.

**2026-03-23T21:49:45Z**

CHECKPOINT 6/6: Self-check complete. Document covers all 7 required content areas: (1) when to use, (2) pre-conditions/tag check, (3) revert cleanup commit, (4) revert reference update commit, (5) full rollback in reverse order, (6) git show from tag for old data, (7) --dry-run verification. No commits made, no slash-commands used, no nested Task calls.
