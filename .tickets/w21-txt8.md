---
id: w21-txt8
status: closed
deps: [w21-jtkr]
links: []
created: 2026-03-21T00:02:52Z
type: story
priority: 1
assignee: Joe Oakhart
parent: w21-ykic
---
# As a DSO practitioner, high-complexity changes receive parallel multi-reviewer scrutiny with opus architectural oversight

## Description

**What**: Upgrade Deep tier from single sonnet to 3 parallel sonnet reviewers + sequential opus architectural reviewer. Sonnet A: correctness. Sonnet B: verification. Sonnet C: hygiene + design + maintainability. Each writes to a separate temp findings file. Opus receives all three plus full diff, writes the final authoritative reviewer-findings.json. Single-writer invariant preserved.

**Why**: Complex cross-cutting changes need multi-dimensional review that a single reviewer can't provide. Parallel sonnets reduce wall-clock time while opus ensures cross-cutting coherence.

**Scope**:
- IN: Deep tier dispatch logic in REVIEW-WORKFLOW.md, per-reviewer prompt templates, sonnet temp file handling, opus merge/synthesis pass, resolution sub-agent isolation from reviewer-findings.json
- OUT: Standard and Light tier dispatch (already in w21-jtkr), enriched checklist content (Epic B)

## Done Definitions

- When this story is complete, Deep tier dispatches 3 parallel sonnet sub-agents, each writing findings to a separate temp file ($ARTIFACTS_DIR/reviewer-findings-{a,b,c}.json)
  ← Satisfies: "Three parallel sonnet reviewers followed sequentially by an opus architectural reviewer"
- When this story is complete, an opus reviewer reads all 3 sonnet findings + full diff and writes the authoritative reviewer-findings.json
  ← Satisfies: "Opus receives all three plus full diff, writes final reviewer-findings.json"
- When this story is complete, the opus-authored reviewer-findings.json passes record-review.sh's file-overlap validation against the staged diff
  ← Satisfies: "Review gate integrity guarantees remain intact"
- When this story is complete, the resolution sub-agent cannot read or write reviewer-findings.json — it receives findings via task prompt only
  ← Satisfies: "Single-writer invariant preserved"
- Unit tests written and passing for all new or modified logic

## Considerations

- [Performance] 4 sub-agent dispatches per Deep review — significant token cost; ensure this tier is triggered appropriately
- [Testing] Integration testing needed for the sonnet→opus handoff and the opus output passing record-review.sh validation
- [Reliability] Sonnet temp files must pass schema validation equivalent to write-reviewer-findings.sh before opus consumes them

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.

## Notes

<!-- note-id: 3si4rxvs -->
<!-- timestamp: 2026-03-21T18:14:17Z -->
<!-- origin: agent -->
<!-- sync: unsynced -->


## Update: Named agent dispatch due to dso-9ltc (review agent build process)

With dedicated review agents defined in dso-9ltc, Deep tier dispatches to named agents:
- Sonnet A (correctness): dispatch to dso:code-reviewer-deep-correctness
- Sonnet B (verification): dispatch to dso:code-reviewer-deep-verification
- Sonnet C (hygiene + design + maintainability): dispatch to dso:code-reviewer-deep-hygiene
- Opus architectural reviewer: dispatch to dso:code-reviewer-deep-arch

Each agent's system prompt already contains the universal review procedure (schema, output contract, scoring rules) and its dimension-specific checklist. The dispatch prompt only needs per-review context (diff path, working directory, diff stat).

Done definitions about dispatching 3 parallel sonnet sub-agents should reference the named agent types. The opus reviewer (dso:code-reviewer-deep-arch) receives all 3 sonnet findings + full diff and writes the authoritative reviewer-findings.json.


**2026-03-22T17:41:00Z**

COMPLEXITY_CLASSIFICATION: COMPLEX
