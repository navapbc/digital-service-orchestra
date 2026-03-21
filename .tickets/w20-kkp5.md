---
id: w20-kkp5
status: in_progress
deps: []
links: []
created: 2026-03-21T16:22:45Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-6k7v
---
# Contract: ReducerStrategy interface for ticket-reducer.py

Create plugins/dso/docs/contracts/ticket-reducer-strategy-contract.md documenting the ReducerStrategy protocol interface that ticket-reducer.py exposes for pluggable conflict resolution.

Fields to document: Signal Name (ReducerStrategy), Emitter (ticket-reducer.py), Consumer (w21-05z9 MostStatusEventsWinsStrategy), Interface definition with resolve(events: list[dict]) -> list[dict] signature, LastTimestampWinsStrategy default behavior, example usage, typing.Protocol note.

This contract must exist BEFORE T1 (RED tests) so w21-05z9 can plan in parallel.

TDD exemption: (1) no conditional logic, (2) any test would be a change-detector, (3) static assets only (Markdown documentation).


## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Contract document exists at correct path
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-reducer-strategy-contract.md
- [ ] Contract contains ReducerStrategy interface definition
  Verify: grep -q 'ReducerStrategy' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-reducer-strategy-contract.md
- [ ] Contract documents resolve method signature with list[dict] types
  Verify: grep -q 'resolve' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-reducer-strategy-contract.md && grep -q 'list' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-reducer-strategy-contract.md

## Notes

<!-- note-id: odcpdfzi -->
<!-- timestamp: 2026-03-21T16:39:27Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 1/6: Task context loaded ✓

<!-- note-id: 1jjyw5i2 -->
<!-- timestamp: 2026-03-21T16:39:48Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 2/6: Code patterns understood ✓

<!-- note-id: daamcee3 -->
<!-- timestamp: 2026-03-21T16:39:53Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 3/6: Tests written (none required) ✓

<!-- note-id: 7wmpkv9e -->
<!-- timestamp: 2026-03-21T16:40:29Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 4/6: Implementation complete ✓

<!-- note-id: z5fzfn6j -->
<!-- timestamp: 2026-03-21T16:46:44Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 5/6: Validation passed ✓

<!-- note-id: jhvycn7p -->
<!-- timestamp: 2026-03-21T16:46:58Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

CHECKPOINT 6/6: Done ✓
