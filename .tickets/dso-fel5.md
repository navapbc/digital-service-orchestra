---
id: dso-fel5
status: open
deps: []
links: []
created: 2026-03-18T17:03:13Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Remove pre-compact checkpoint hook from DSO


## Notes

**2026-03-18T17:04:12Z**

## Context
DSO currently registers a `PreCompact` hook (`pre-compact-checkpoint.sh`) that auto-commits uncommitted work before Claude Code compacts its context window. The hook also writes a `.checkpoint-needs-review` sentinel that ties every compaction event to the two-layer code-review gate, forcing review clearance after each compaction. This creates disproportionate friction: practitioners are required to run code review on checkpoint commits that contain no deliberate code changes, and the rollback mechanism (`.checkpoint-pending-rollback`) adds a live working-tree file that must be cleaned up by other scripts. Engineering leadership has decided to remove the hook and all supporting infrastructure so context compaction no longer triggers git operations, review-gate checks, or sentinel-file management.

## Approach
Full surgical removal: delete all 16 checkpoint-dedicated files and strip checkpoint-related code from ~18 shared files. No replacement mechanism is introduced.

## Dependencies
None
