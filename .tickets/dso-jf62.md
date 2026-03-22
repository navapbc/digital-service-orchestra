---
id: dso-jf62
status: open
deps: [dso-b7nb, dso-gfry, dso-b538]
links: []
created: 2026-03-21T23:20:18Z
type: story
priority: 2
assignee: Joe Oakhart
parent: w21-ovpn
---
# As a DSO practitioner, the Deep Opus architectural reviewer applies cross-cutting synthesis checks across all specialist findings


## Notes

<!-- note-id: 62cayy1f -->
<!-- timestamp: 2026-03-21T23:21:40Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Description

**What**: Create the reviewer-delta-deep-architectural.md checklist for the Deep tier Opus (architectural synthesis) reviewer.

**Why**: The opus reviewer is the only agent that sees all 3 specialists' findings plus the full diff plus full ticket context. Its job is cross-cutting synthesis — identifying patterns and risks that no single specialist can see.

## Acceptance Criteria

- When this story is complete, reviewer-delta-deep-architectural.md includes these cross-cutting checks:
  - Cross-cutting coherence: resolve contradictions between specialist findings
  - Untested edge cases: cross-reference Sonnet A edge cases against Sonnet B test coverage findings
  - Architectural boundary shifts: logic/validation/data moving between layers
  - Pattern divergence: new approach to something the codebase already has a pattern for
  - Acceptance criteria completeness: does the change fulfill what the ticket asked for?
  - Unrelated scope: flag changes that include modifications unrelated to the stated ticket objective
  - Regression awareness: repeated patches to same area suggesting deeper issue (via targeted git blame)
  - Root cause vs. symptom: does the fix address the underlying cause or just the visible symptom?
- When this story is complete, the checklist includes instructions for self-directed git history investigation (opus runs targeted git blame/log based on findings — no orchestrator pre-gathering)
- When this story is complete, the checklist includes ticket context instructions: use full ticket (minus verbose status update notes) when available; do not block on missing ticket context
- When this story is complete, build-review-agents.sh regenerates the deep architectural reviewer agent successfully

## Constraints
- This reviewer does not duplicate specialist checks — it synthesizes across them
- Git history investigation is self-directed and targeted, not exhaustive

