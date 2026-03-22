---
id: dso-uu13
status: in_progress
deps: []
links: []
created: 2026-03-17T18:34:27Z
type: epic
priority: 1
assignee: Joe Oakhart
jira_key: DIG-35
---
# Remove CI ticket creation pattern

Because our scripts are in a plugin, CI does not have access to tk to create tickets. Remove any functionality intended to create a ticket as part of CI


## Notes

<!-- note-id: 6jzf2jua -->
<!-- timestamp: 2026-03-22T19:14:23Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Context
When CI fails, `ci-create-failure-bug.sh` auto-creates bug tickets via the `create-failure-bug` workflow job. Because DSO is a plugin and CI doesn't reliably have access to `tk`, these tickets are noise — CI failures are already caught by the existing `ci-status.sh --wait` workflow step, which agents check after pushing. The noise was bad enough that a dedicated cleanup script (`bulk-delete-stale-tickets.sh`) was created to delete the auto-created duplicates.

## Success Criteria
- The `create-failure-bug` job no longer exists in `.github/workflows/ci.yml`
- The `ci-create-failure-bug.sh` script is deleted
- The `bulk-delete-stale-tickets.sh` cleanup script is deleted
- The example CI workflow (`examples/ci.example.yml`) no longer includes the `create-failure-bug` job
- CLAUDE.md rule #3 ("Tracking issues are auto-created") is updated to remove the auto-creation reference
- Existing CI failure detection (`ci-status.sh --wait`) continues to work unchanged
- After the next CI failure post-merge, no auto-created bug tickets appear in `.tickets/` — verified by checking `git log` for commits from `ci-create-failure-bug.sh`

## Dependencies
None

## Approach
Clean removal of `ci-create-failure-bug.sh`, the CI workflow job that calls it, the example workflow job, the `bulk-delete-stale-tickets.sh` cleanup script, and the CLAUDE.md rule referencing auto-creation.
