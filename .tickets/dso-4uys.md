---
id: dso-4uys
status: closed
deps: []
links: []
created: 2026-03-22T03:51:41Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Contract: REVERT event emit/parse interface

Define the canonical REVERT event format contract between the emitter (ticket-revert.sh / ticket-lib.sh) and the parser (ticket-reducer.py, bridge-outbound.py).

Create: plugins/dso/docs/contracts/revert-event.md

Contract document must include:
- Signal Name: REVERT
- Emitter: ticket-revert.sh (via write_commit_event in ticket-lib.sh)
- Parsers: ticket-reducer.py (records revert history in compiled state), bridge-outbound.py (checks before pushing revert's outbound effect)
- Fields:
  - event_type: string, required, always 'REVERT'
  - timestamp: int, required, UTC epoch
  - uuid: string, required, UUIDv4
  - env_id: string, required, author environment ID
  - author: string, required, who initiated the revert
  - data.target_event_uuid: string, required, UUID of the event being reverted (must not be a REVERT event — REVERT-of-REVERT is rejected by CLI)
  - data.target_event_type: string, required, type of the event being reverted
  - data.reason: string, optional, human-readable reason
- Reducer semantics: reducer records REVERTs in a 'reverts' list in compiled state; the reducer does NOT automatically undo target_event's effect (undo logic is event-type-specific and handled by bridge-outbound)
- Bridge-outbound semantics: when processing a REVERT for a STATUS or SYNC event, fetch current Jira state before pushing; emit BRIDGE_ALERT if Jira has diverged since the original bad action
- Constraint: REVERT-of-REVERT rejected at CLI level (ticket-revert.sh must validate target is not a REVERT event)

TDD Requirement: This is a documentation/contract artifact task. No behavioral code is added. No RED test dependency required (infrastructure-boundary-only: document with no conditional logic, change-detector test only, configuration/specification artifact).
Justification for unit test exemption: (1) no conditional logic — pure specification document; (2) any test would be a change-detector asserting the file exists; (3) infrastructure-boundary-only — spec artifact only.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Contract file exists at plugins/dso/docs/contracts/revert-event.md
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/revert-event.md
- [ ] Contract defines all required fields: event_type, timestamp, uuid, env_id, author, data.target_event_uuid, data.target_event_type
  Verify: grep -qE 'target_event_uuid|target_event_type' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/revert-event.md
- [ ] Contract documents REVERT-of-REVERT rejection constraint
  Verify: grep -qi 'revert-of-revert\|cannot revert a revert' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/revert-event.md
- [ ] Contract specifies reducer semantics (records in reverts list, does NOT auto-undo target effect)
  Verify: grep -qi 'reverts\|does not.*undo\|not.*auto' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/revert-event.md
- [ ] Contract specifies bridge-outbound check-before-overwrite semantics
  Verify: grep -qi 'check.*before\|fetch.*jira\|diverged' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/revert-event.md

