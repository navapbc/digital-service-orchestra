---
id: dso-ptzz
status: open
deps: []
links: []
created: 2026-03-22T20:01:07Z
type: bug
priority: 2
assignee: Joe Oakhart
parent: dso-uu13
---
# sprint-next-batch.sh treats tk dep blockers as file conflicts, preventing non-overlapping tasks from batching


## Notes

<!-- note-id: s46n6vmg -->
<!-- timestamp: 2026-03-22T20:01:16Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Description

When sprint-next-batch.sh plans a batch, tasks blocked by tk dep are excluded even when they have zero file overlap with the blocking task. In this sprint (dso-uu13), dso-6r3o (CI workflow/script deletions) and dso-fqye (CLAUDE.md update) touch completely different files but were split into separate batches because dso-fqye depends on dso-6r3o.

The script should distinguish between:
- **File-level conflicts**: tasks that modify the same files (must be serialized)
- **Logical ordering**: tasks with tk dep relationships but no file overlap (can be parallelized)

## Acceptance Criteria

- Tasks with tk dep blockers but zero file overlap are included in the same batch
- Tasks with tk dep blockers AND file overlap remain serialized
- Existing file-overlap detection continues to work
