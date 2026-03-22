---
id: dso-lc3c
status: open
deps: []
links: []
created: 2026-03-22T16:32:36Z
type: story
priority: 2
assignee: Joe Oakhart
parent: dso-oo34
---
# As a developer, a dedicated RED test writer agent produces intent-faithful failing tests

See ticket notes for full story body.


## Notes

<!-- note-id: pwzekg7y -->
<!-- timestamp: 2026-03-22T16:33:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Description

**What**: A dedicated plugin agent (red-test-writer.md) with a Senior SDET identity that writes failing tests (RED) scoped to a given ticket, reading the ticket hierarchy for intent context.
**Why**: Today RED tests are written inline by the orchestrating agent with no specialization, producing tests that verify code mechanics rather than user intent. A dedicated agent ensures every RED test traces to a done definition or success criterion.
**Scope**:
- IN: Agent definition with Senior SDET identity (Google), ticket hierarchy reading (parent story + grandparent epic for intent context), test writing within ticket-specified test type (unit/E2E/integration), edge case discovery with [RED-EDGE-CASE] note propagation via tk add-note on parent, registration under tdd_red_test routing category in agent-routing.conf, structural test (discover-agents.sh resolves agent for tdd_red_test), integration test (edge case notes appear on parent after dispatch), update test-agent-routing-conf.sh expected category count
- OUT: Workflow modifications (separate story), documentation updates (separate story)

## Done Definitions

- When this story is complete, the agent reads a ticket ID, traverses to parent (story) and grandparent (epic) via tk show, and writes failing tests whose assertions trace to done definitions or success criteria from those parents
  Satisfies SC1
- When this story is complete, out-of-scope edge cases are added as [RED-EDGE-CASE]-prefixed notes on the parent story or epic via tk add-note
  Satisfies SC2
- When this story is complete, the agent is registered under tdd_red_test in agent-routing.conf and resolved by discover-agents.sh, with a structural test confirming resolvability and an integration test confirming edge case note propagation
  Satisfies SC3
- When this story is complete, the agent handles orphan tickets (no parent) and closed/missing parents gracefully without crashing
  Satisfies SC1 (reliability)
- When this story is complete, test-agent-routing-conf.sh expected category count is updated to include tdd_red_test
  Adversarial finding: implicit shared state
- Unit tests written and passing for all new or modified logic

## Considerations

- [Reliability] Agent must handle orphan tickets (no parent) and tickets without epic grandparents gracefully
- [Reliability] tk add-note for edge cases — if parent story/epic is closed or missing, degrade gracefully
- [Testing] Agent must be tested in isolation before workflow integration relies on it
- [Architecture] ADVERSARIAL: The routing mechanism (routing-category via agent-routing.conf + discover-agents.sh) vs named-agent dispatch (plugins/dso/agents/ + direct subagent_type) must be resolved — these are mutually exclusive patterns in the current architecture. The epic specifies routing-category dispatch; implementation must determine the correct file placement convention.
