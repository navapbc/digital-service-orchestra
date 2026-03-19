---
id: w21-auwy
status: open
deps: []
links: []
created: 2026-03-19T03:30:38Z
type: story
priority: 0
assignee: Joe Oakhart
parent: dso-tmmj
---
# As a DSO practitioner, I can invoke dso:fix-bug to classify a bug and route it through the appropriate path

## Description

**What**: Core dso:fix-bug skill file with mechanical/behavioral classification, scoring rubric, workflow skeleton, and tdd-workflow deprecation.
**Why**: This is the foundation that all other stories build on — without the skill file, classification logic, and scoring rubric, no investigation tiers or integrations can be implemented.
**Scope**:
- IN: Skill file creation with config resolution pattern (preserved from tdd-workflow), mechanical/behavioral error type classification, scoring rubric (severity 0/1/2, complexity 0/1/2, environment 0/1/2, cascading failure +2, prior fix attempts +2), threshold routing (<3=BASIC, 3-5=INTERMEDIATE, ≥6=ADVANCED), mechanical read→fix→validate path, 8-step workflow skeleton (check known issues → score → investigate → hypothesis test → fix approval → RED test → fix → verify → commit), investigation RESULT report schema definition, discovery file protocol contract, tdd-workflow deprecation with forward pointer
- OUT: Investigation sub-agent prompt templates (S2-S5), integration with other skills (S7-S9), cluster handling (S6)

## Done Definitions

- When this story is complete, invoking dso:fix-bug on a mechanical error (import error, type annotation, lint violation, config syntax) routes to the mechanical path (read→fix→validate) without scoring
  ← Satisfies: "Errors are first classified by type: mechanical skip scoring and route directly to a lightweight read→fix→validate path"
- When this story is complete, invoking dso:fix-bug on a behavioral bug produces a score from the rubric and routes to BASIC, INTERMEDIATE, or ADVANCED based on thresholds
  ← Satisfies: "Investigation depth (BASIC/INTERMEDIATE/ADVANCED) is determined by a scoring rubric"
- When this story is complete, tdd-workflow contains a forward pointer to dso:fix-bug and is no longer the primary bug-fix skill
  ← Satisfies: "tdd-workflow is deprecated with a forward pointer to dso:fix-bug"
- When this story is complete, the workflow skeleton defines the investigation RESULT report schema (ROOT_CAUSE, confidence, proposed fixes) that all investigation tiers (S2-S5) must conform to
  ← Satisfies: SC1 — shared contract prevents incompatible output formats across tiers
- When this story is complete, the workflow skeleton defines the discovery file path convention and required fields that investigation phases populate and fix phases consume
  ← Satisfies: SC1 — shared contract for investigation-to-fix handoff
- When this story is complete, the workflow skeleton includes an explicit hypothesis testing phase that proposes and runs concrete tests to prove or disprove each suspected root cause before proceeding to fix approval
  ← Satisfies: SC4 — hypothesis testing is the primary defense against false root causes (research: 73-81% of patches overfit without it)

## Considerations

- [Testing] Ensure classification logic is testable with mock error inputs
- [Maintainability] Config resolution pattern from tdd-workflow must be preserved
- [Maintainability] The RESULT report schema and discovery file protocol are shared contracts consumed by S2-S5 — define them as part of the workflow skeleton so tiers conform rather than diverge
- [Reliability] Escalation to the next tier must include the previous tier's investigation results (root cause hypotheses, confidence levels, tests run, results, attempted fixes) — not a fresh start. Each tier builds on the previous tier's work

## Escalation Policy

**Escalation policy**: Proceed unless a significant assumption is required to continue — one that could send the implementation in the wrong direction. Escalate only when genuinely blocked without a reasonable inference. Document all assumptions made without escalating.
