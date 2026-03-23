---
id: dso-tdzq
status: open
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

