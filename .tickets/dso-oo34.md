---
id: dso-oo34
status: open
deps: [dso-8l5h]
links: []
created: 2026-03-22T16:24:24Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Dedicated RED test writer sub-agent


## Notes

<!-- note-id: 6zd8opru -->
<!-- timestamp: 2026-03-22T16:24:41Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->

## Context
Developers using the DSO plugin rely on TDD — every code change requires a failing test (RED) before implementation (GREEN). Today, RED tests are written inline by whatever agent happens to be orchestrating, with no specialization. This produces inconsistent test quality: tests that verify code mechanics rather than user intent, miss edge cases, and vary in style across the three workflows that need them (/dso:fix-bug, /dso:tdd-workflow, /dso:sprint via implementation-plan). A dedicated agent that reads up the ticket hierarchy to understand why a change exists would write tests that verify whether the users goal was accomplished, not just whether code runs.

## Success Criteria
1. A dedicated plugin agent (red-test-writer.md in plugins/dso/agents/) with a Senior SDET identity writes failing tests scoped to a given ticket. The agent reads the tickets parent (story) and grandparent (epic) for intent context, writes tests that verify user intent is accomplished within the tickets specified test type (unit, E2E, integration), and considers edge cases, gaps, and gotchas. Each workflow that currently writes RED tests inline replaces that step with a sub-agent dispatch call through the routing system, passing ticket ID and test type as inputs.
2. When the agent discovers edge cases outside the tickets scope, it calls tk add-note on the parent story or epic with a [RED-EDGE-CASE] prefix so future RED agents pick them up as context — it does not create new tickets or write tests for out-of-scope concerns.
3. The agent is registered under a tdd_red_test routing category in agent-routing.conf and resolved by discover-agents.sh. A structural test verifies the agent is resolvable for the tdd_red_test category, and an integration test verifies that out-of-scope edge case notes appear on the parent story after agent dispatch.
4. The three workflows that produce RED tests (/dso:fix-bug, /dso:tdd-workflow, /dso:sprint via implementation-plan) dispatch RED test work through the tdd_red_test routing category. Validation: after at least 10 RED tests are produced by the agent, a structured audit confirms each tests assertions trace to a done definition or success criterion from the parent story/epic — results recorded in a review note on the epic.

## Dependencies
- dso-8l5h (coordination — follows the same plugin-agent extraction pattern; this epic adopts whatever structural conventions dso-8l5h establishes)
- w21-24kl (risk — the agent traverses the ticket hierarchy via tk show parent fields; targets the current tk CLI and accepts rework if v3 migration lands first)

## Approach
Dedicated plugin agent definition in plugins/dso/agents/ with tier-1 system prompt identity (Senior SDET at Google). Registered in agent-routing.conf under the tdd_red_test category. Callers updated to dispatch through discover-agents.sh rather than writing tests inline. Agent output includes test code, verification command, and .test-index marker entry. Out-of-scope edge cases flow as [RED-EDGE-CASE]-prefixed notes to the parent story/epic via tk add-note.
