---
id: prioritize-items-into-tiers
title: Prioritize a Set of Items Into Tiers
category: planning
operation: Assign every item in a set to a priority tier against a stated objective and tradeoff/risk signals, ignoring each item's current priority and propagating priority to the things that block high-priority items.
when_to_use: >
  When prioritizing a whole backlog or set (not scoring one item in isolation) and
  you need each item placed in a defensible tier relative to an objective. Use when
  the ranking must ignore current/legacy priority (re-prioritization is the point)
  and must respect dependencies — a blocker of a high-priority item should not be
  starved below it.
inputs:
  - name: items
    type: array
    required: true
    description: The items to prioritize, each with an id, a description, and any declared blocker/dependency edges.
  - name: objective
    type: object
    required: true
    description: The north-star/goal and the tradeoff signals (preferred direction, quality-vs-speed bias) priorities are judged against.
  - name: risk_posture
    type: string
    required: false
    description: '"risk-averse" to hold risky items back and escalate risky promotions; "neutral" otherwise. Defaults to neutral.'
  - name: tiers
    type: array
    required: false
    description: >
      The ordered tier vocabulary, highest first. Defaults to
      [must-have-high, must-have-low, optional-high, optional-low, out-of-scope].
outputs:
  format: json
  schema: >
    {assignments: [{id, tier, rationale, risk_flag: bool}], escalations:
    [{id, question}]}. Every item appears exactly once.
tools:
  required: []
  optional:
    - read-only inspection to ground an item's scope/risk
  prohibited:
    - letting an item's current priority influence its new tier (anti-anchor)
    - modifying any item or persisting priorities
determinism: low-variance
model_hint: sonnet
source: Backlog prioritization (coarse bucketing + granular sub-tiering) with anti-anchor and dependency-aware inheritance.
---

# Prioritize a Set of Items Into Tiers

You assign every item to a priority tier against the objective. You analyze and
recommend — you do not persist anything.

## Anti-anchor rule

An item's **current** priority MUST NOT influence its new tier. Judge each item
only on its alignment with the objective and its risk — re-prioritization is the
whole point. A previously-lowest item can become highest, and vice versa.

## Procedure

1. **Coarse bucket.** Place each item into a top-level bucket relative to the
   objective: does it directly advance the objective (must-have), is it a
   nice-to-have (optional), or is it out of scope? When a bucket is genuinely
   unclear from the item alone, gather context before deciding rather than
   guessing.
2. **Sub-tier within bucket.** Within each non-out-of-scope bucket, mark each item
   high or low based on alignment with the objective's tradeoff signals and risk
   posture. Small buckets (≤ 3) default to high — there is no meaningful spread.
   Combine bucket + sub-tier into the final `tier` from the `tiers` vocabulary.
3. **Dependency-aware inheritance.** Run a fixed-point pass: if item A is
   high-priority, every item that blocks A (directly or transitively) inherits at
   least A's priority, so a prerequisite is never starved below the thing it
   enables. Scope inheritance within the appropriate bucket band per your tier
   model.
4. **Risk handling.** When `risk_posture` is risk-averse, hold notably risky items
   to a lower tier; if a risky item would otherwise be promoted to the top tier,
   add an `escalation` asking the caller to confirm rather than promoting
   autonomously, and set `risk_flag: true`.

## Output contract

```json
{
  "assignments": [
    {"id": "<item id>", "tier": "<from tiers>", "rationale": "one sentence", "risk_flag": false}
  ],
  "escalations": [
    {"id": "<item id>", "question": "confirm risky promotion to the top tier?"}
  ]
}
```

Every item appears exactly once in `assignments`. `escalations` is empty when no
risky top-tier promotion arises.

## Constraints

- Do exactly one thing: assign tiers and surface escalations. Do NOT persist
  priorities or modify items.
- Anti-anchor: never let current priority influence the new tier.
- Ensure blockers of high-priority items inherit priority (fixed-point pass).
