---
id: dso-baje
status: in_progress
deps: [dso-guxa, dso-wglr]
links: []
created: 2026-03-18T22:59:35Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-p2d3
---
# Update project docs to reflect removal of plugin test step


## What
Update existing documentation and example files that reference the retired plugin test step.

## Why
After the plugin test infrastructure is removed (dso-guxa, dso-l24u, dso-wglr), several documentation files will contain stale references to `make test-plugin`, Step 1.75, or the plugin test concept. These should be cleaned up to prevent confusion.

## Scope

IN:
- `plugins/dso/scripts/validate.sh` header comment (line ~53): Remove `Plugin/hook tests (120s): make test-plugin (from repo root)` from the timeout debugging guide
- `examples/ci.example.yml`: Update test-plugin job and `make test-plugin` references to reflect the new test structure (lines ~156, 185, 1163)
- `.github/workflows/ci.yml`: Remove the `test-plugin` job and remove `test-plugin` from the `needs:` list on the `create-failure-bug` job (the `needs:` reference is a hard dependency — leaving it with a deleted job will make the CI workflow invalid)

OUT: Code changes (handled by other stories), creating new documentation files

## Done Definitions

- When this story is complete, `validate.sh` header contains no reference to `make test-plugin`
  ← Satisfies: "Remove plugin testing as a separate step"
- When this story is complete, `examples/ci.example.yml` contains no `test-plugin` job or `make test-plugin` reference
  ← Satisfies: "Remove plugin testing as a separate step"
- When this story is complete, `.github/workflows/ci.yml` has no `test-plugin` job and the `create-failure-bug` job's `needs:` list no longer references `test-plugin`
  ← Satisfies: "Remove plugin testing as a separate step"

## Considerations
- [Maintainability] Follow `.claude/docs/DOCUMENTATION-GUIDE.md` for formatting conventions
- [Maintainability] CI workflow changes (.github/workflows/) should be made by editing the file in the worktree, not via GitHub API, per CLAUDE.md Rule 19

## Notes

<!-- note-id: d7xyr5s8 -->
<!-- timestamp: 2026-03-18T22:59:55Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

Follow .claude/docs/DOCUMENTATION-GUIDE.md for documentation formatting, structure, and conventions.

<!-- note-id: q0upanxl -->
<!-- timestamp: 2026-03-19T00:46:14Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓ — Files: examples/ci.example.yml, .github/workflows/ci.yml. Tests: n/a (docs-only). Removed test-plugin job and needs: references from both CI workflow files.
