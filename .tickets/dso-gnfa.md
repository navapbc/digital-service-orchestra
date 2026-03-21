---
id: dso-gnfa
status: open
deps: [dso-a4fy]
links: []
created: 2026-03-21T16:09:17Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-k2yz
---
# Update ticket-event-format.md contract with LINK/UNLINK schema

## Description

Update `plugins/dso/docs/contracts/ticket-event-format.md` to promote LINK and UNLINK from forward-references to fully-defined contracts with `data` field schemas.

**Files to modify:**
- `plugins/dso/docs/contracts/ticket-event-format.md`:
  - Add `LINK` event `data` schema definition (under the `data fields by event_type` section):
    ```json
    {
      "relation": "blocks|depends_on|relates_to",
      "target_id": "<ticket-id>"
    }
    ```
  - Add `UNLINK` event `data` schema definition:
    ```json
    {
      "link_uuid": "<uuid of the LINK event being negated>",
      "target_id": "<ticket-id>"
    }
    ```
  - Update the Event Type Contracts table: change LINK status from `forward-reference` to `defined`; add UNLINK row with status `defined`, story `w21-k2yz`
  - Add note: `relates_to` links generate reciprocal LINK events in both ticket dirs

**TDD Requirement:** No executable test for this doc-only task.
Exemption criterion: Unit exemption 3 — static assets only (Markdown documentation). No executable assertion is possible.

## Acceptance Criteria

- [ ] `ticket-event-format.md` contains LINK `data` schema with `relation` and `target_id` fields
  Verify: `grep -q "relation.*blocks\|depends_on\|relates_to" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md`
- [ ] `ticket-event-format.md` contains UNLINK `data` schema with `link_uuid` field
  Verify: `grep -q "link_uuid" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md`
- [ ] LINK event status in table updated from `forward-reference` to `defined`
  Verify: `grep -A2 "LINK" $(git rev-parse --show-toplevel)/plugins/dso/docs/contracts/ticket-event-format.md | grep -q "defined"`
- [ ] `ruff check` passes (exit 0) — no Python files modified
  Verify: `cd $(git rev-parse --show-toplevel) && ruff check plugins/dso/scripts/*.py tests/**/*.py`
- [ ] `bash tests/run-all.sh` passes (exit 0)
  Verify: `cd $(git rev-parse --show-toplevel) && bash tests/run-all.sh`
