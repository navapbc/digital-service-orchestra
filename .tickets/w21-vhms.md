---
id: w21-vhms
status: open
deps: [w21-37to]
links: []
created: 2026-03-21T22:11:04Z
type: task
priority: 2
assignee: Joe Oakhart
parent: w21-8cw2
---
# ADR: outbound bridge architectural pattern

## Description

Create `plugins/dso/docs/adr/0003-outbound-jira-bridge.md` (or next sequential ADR number — check existing files in plugins/dso/docs/adr/ first).

Sections:
- **Context**: Why async bridge needed (local tk sync requires local credentials, synchronous, can't be push-triggered; SC9: no local Jira creds required)
- **Decision**: GitHub Actions + Python bridge scripts (bridge-outbound.py, acli-integration.py) + ACLI
- **Consequences**: No local credentials required; ~5min latency window; SYNC event format coupling between outbound and inbound bridge (link to w21-5mr1 contract)
- **Alternatives Considered**: Extending `tk sync` — rejected because requires local ACLI credentials and runs synchronously (cannot satisfy SC1 and SC9)
- **SYNC event format reference**: Link to `plugins/dso/docs/contracts/sync-event-format.md`

TDD Requirement: test-exempt — criterion 3 (Markdown documentation file, no conditional logic, no executable code).

## ACCEPTANCE CRITERIA

- [ ] ADR file exists in `plugins/dso/docs/adr/` with 'bridge' or 'outbound' in the filename
  Verify: ls $(git rev-parse --show-toplevel)/plugins/dso/docs/adr/ 2>/dev/null | grep -qiE 'bridge|outbound'
- [ ] ADR contains Context, Decision, and Consequences sections
  Verify: ADR_FILE=$(ls $(git rev-parse --show-toplevel)/plugins/dso/docs/adr/*bridge* $(git rev-parse --show-toplevel)/plugins/dso/docs/adr/*outbound* 2>/dev/null | head -1) && grep -q 'Context' "$ADR_FILE" && grep -q 'Decision' "$ADR_FILE" && grep -q 'Consequences' "$ADR_FILE"
- [ ] ADR references the SYNC contract document (sync-event-format)
  Verify: ADR_FILE=$(ls $(git rev-parse --show-toplevel)/plugins/dso/docs/adr/*bridge* $(git rev-parse --show-toplevel)/plugins/dso/docs/adr/*outbound* 2>/dev/null | head -1) && grep -q 'sync-event-format\|contracts/' "$ADR_FILE"
- [ ] ADR documents alternatives considered (tk sync rejected)
  Verify: ADR_FILE=$(ls $(git rev-parse --show-toplevel)/plugins/dso/docs/adr/*bridge* $(git rev-parse --show-toplevel)/plugins/dso/docs/adr/*outbound* 2>/dev/null | head -1) && grep -qiE 'alternative|tk sync|rejected' "$ADR_FILE"
