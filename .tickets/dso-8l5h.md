---
id: dso-8l5h
status: open
deps: []
links: [dso-5ooy]
created: 2026-03-21T18:37:37Z
type: epic
priority: 2
assignee: Joe Oakhart
---
# Extract review and evaluation sub-agents into dedicated plugin agents


## Notes

<!-- note-id: o373k14a -->
<!-- timestamp: 2026-03-21T18:38:00Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Placeholder — candidates for dedicated plugin agent extraction

This epic tracks sub-agents identified as strong candidates for extraction into dedicated plugin agents (plugins/dso/agents/). Each candidate enforces a strict output format, performs impartial review of the orchestrator's work, or both. Brainstorming and spec definition deferred to a future session.

### Priority 1 — Review integrity (orchestrator must not control reviewer identity)

1. **Review fix resolver** (REVIEW-WORKFLOW Resolution Loop) — Strict output contract (RESOLUTION_RESULT). Nesting prohibition (must NOT dispatch nested re-review) is currently prompt-enforced; should be tier-1.
2. **Red team reviewer** (/dso:preplanning Phase 2.5) — Adversarial review of orchestrator's own story decomposition. JSON output. Orchestrator constructs the prompt including the stories to attack.
3. **Blue team reviewer** (/dso:preplanning Phase 2.5) — Filters red team findings. JSON output. Same conflict — orchestrator produced the stories and constructs the filter prompt.
4. **Fidelity reviewers** (/dso:brainstorm Phase 2) — 3 reviewers (Agent Clarity, Scope, Value) that validate epic specs. Strict JSON schema validated by validate-review-output.sh. Orchestrator drafts the spec and constructs reviewer prompts. Could be 3 agents or 1 parameterized agent.
5. **Plan reviewer** (/dso:implementation-plan Step 4) — Reviews orchestrator's implementation plan. Dispatched via /dso:review-protocol. Strict output schema.

### Already tracked elsewhere

- **Code reviewers (6 agents)** — dso-9ltc in w21-ykic (Tiered Review Architecture)
- **Complexity evaluator + conflict analyzer** — dso-2j6u

### Context

See feedback memory: feedback_subagent_tier1_compliance.md for the rationale behind tier-1 promotion of review and evaluation sub-agents.

