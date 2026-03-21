---
id: w20-0aaw
status: in_progress
deps: []
links: []
created: 2026-03-21T16:34:53Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-6llo
---
# Contract: tombstone file format for archived ticket dependency resolution

Define the cross-component contract for tombstone files written by archive-closed-tickets.sh and consumed by tk dep tree. Tombstone files: path .tickets/archive/tombstones/<id>.json, fields: {id: string, type: string (one of: bug, epic, story, task), final_status: string (one of: closed)}. Exactly 3 top-level fields — no extra fields allowed. Written atomically (write to .tmp, then mv). Idempotent: if tombstone already exists and has matching id, skip (do not overwrite). Consumer: tk dep tree reads tombstones to show '[archived: <final_status> (<type>)]' instead of '[missing — treated as satisfied]'. Tombstone deps remain treated as satisfied for ready_to_work computation. Create contract doc at plugins/dso/docs/contracts/tombstone-archive-format.md. test-exempt: documentation-only task (no code change — pure contract specification). test-exempt criteria: (1) no conditional logic, (2) no behavioral content, (3) infrastructure-boundary-only.

## ACCEPTANCE CRITERIA

- [ ] Contract document exists at plugins/dso/docs/contracts/tombstone-archive-format.md
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/tombstone-archive-format.md
- [ ] Contract document contains required sections: Signal Name, Emitter, Parser, Fields, Example
  Verify: grep -q 'Emitter\|Parser\|Fields\|Example' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/tombstone-archive-format.md
- [ ] Contract specifies exactly 3 fields: id, type, final_status
  Verify: grep -q 'id.*type.*final_status\|id.*final_status\|final_status' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/tombstone-archive-format.md
- [ ] test-exempt: documentation-only (no code), no behavioral content, no conditional logic
  Verify: grep -q 'test-exempt:' $(git rev-parse --show-toplevel)/.tickets/w20-0aaw.md


## Notes

**2026-03-21T16:39:20Z**

CHECKPOINT 1/6: Task context loaded ✓

**2026-03-21T16:39:38Z**

CHECKPOINT 2/6: Code patterns understood ✓

**2026-03-21T16:39:42Z**

CHECKPOINT 3/6: Tests written (none required) ✓

**2026-03-21T16:40:18Z**

CHECKPOINT 4/6: Implementation complete ✓

**2026-03-21T16:40:29Z**

CHECKPOINT 5/6: Validation passed ✓

**2026-03-21T16:40:31Z**

CHECKPOINT 6/6: Done ✓
