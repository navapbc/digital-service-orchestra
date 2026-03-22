---
id: dso-qwrw
status: in_progress
deps: []
links: []
created: 2026-03-22T03:51:28Z
type: task
priority: 1
assignee: Joe Oakhart
parent: w21-qjcy
---
# Contract: BRIDGE_ALERT event emit/parse interface

Define the canonical BRIDGE_ALERT event format contract between emitters (bridge-inbound.py, bridge-outbound.py) and the parser (ticket-reducer.py / ticket-show.sh / ticket-list.sh).

Create: plugins/dso/docs/contracts/bridge-alert-event.md

Contract document must include:
- Signal Name: BRIDGE_ALERT
- Emitters: bridge-inbound.py (write_bridge_alert), bridge-outbound.py (write_bridge_alert)
- Parser: ticket-reducer.py (detect_bridge_alerts), ticket-show.sh, ticket-list.sh (passive health warning)
- Fields: event_type (string, required, always 'BRIDGE_ALERT'), timestamp (int, required, UTC epoch), uuid (string, required), env_id (string, required), ticket_id (string, required), data.reason (string, required, human-readable alert reason), data.resolved (bool, optional, default false)
- Resolution semantics: an alert is 'unresolved' if no later BRIDGE_ALERT with data.resolved=true and matching data.alert_uuid exists
- Example: representative payload

Note: The two existing write_bridge_alert() implementations (inbound vs outbound) have slightly different field structures — the contract must canonicalize one format and implementation tasks must normalize emitters to it.

TDD Requirement: This is a documentation/contract artifact task. No behavioral code is added. No RED test dependency required (infrastructure-boundary-only: document with no conditional logic, change-detector test only, configuration/specification artifact).
Justification for unit test exemption: (1) no conditional logic — pure specification document; (2) any test would be a change-detector asserting the file exists; (3) infrastructure-boundary-only — this is a spec artifact, not executable code.

## ACCEPTANCE CRITERIA

- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh
- [ ] `ruff check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py
- [ ] `ruff format --check plugins/dso/scripts/*.py tests/**/*.py` passes (exit 0)
  Verify: cd $(git rev-parse --show-toplevel) && ruff format --check plugins/dso/scripts/*.py tests/**/*.py
- [ ] Contract file exists at plugins/dso/docs/contracts/bridge-alert-event.md
  Verify: test -f $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/bridge-alert-event.md
- [ ] Contract document contains all required fields: event_type, timestamp, uuid, env_id, ticket_id, data.reason
  Verify: grep -qE 'event_type|timestamp|uuid|env_id|ticket_id|data\.reason' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/bridge-alert-event.md
- [ ] Contract document defines resolution semantics (resolved/unresolved alert lifecycle)
  Verify: grep -qi 'resolv' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/bridge-alert-event.md
- [ ] Contract canonicalizes the field format discrepancy between bridge-inbound.py and bridge-outbound.py
  Verify: grep -qi 'inbound\|outbound\|canonical\|normalize' $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/bridge-alert-event.md

