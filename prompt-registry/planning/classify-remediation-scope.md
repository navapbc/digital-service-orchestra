---
id: classify-remediation-scope
title: Classify the Scope of Remediation for Verification Failures
category: planning
operation: Given verification failures and the work-item hierarchy, classify — via an ordered decision tree — what remediation scope is required, emitting a single routing directive with confidence.
when_to_use: >
  After a completion/verification check fails, when you must decide how big the
  fix is: patch the current item in place, add work to it, add a sibling item
  under the parent, or replan the parent. Use to route remediation correctly and
  avoid both over-reaction (replanning when a small fix suffices) and
  under-reaction (patching when scope genuinely expanded).
inputs:
  - name: verification_output
    type: object
    required: true
    description: The verifier result, including per-criterion verdicts and the evidence found (or not) for each failing criterion.
  - name: hierarchy
    type: object
    required: true
    description: The current work item (with its acceptance criteria/scope) and its parent (with the parent's broader criteria/scope).
  - name: scope_levels
    type: array
    required: false
    description: >
      Override the remediation scope vocabulary. Defaults to
      [fix_in_place, add_work_to_current, add_item_in_parent, replan_parent, protocol_error].
outputs:
  format: json
  schema: >
    {scope, target_id, context:{failing_criteria[], remediation_summary},
    confidence: HIGH|MEDIUM|LOW}. scope is one value from scope_levels.
tools:
  required:
    - read-only inspection of the verifier output and item/parent context
  optional: []
  prohibited:
    - creating items, writing files, or dispatching nested sub-agents
    - evaluating rules out of order (decision tree is short-circuit)
determinism: deterministic
model_hint: opus
source: Verification-remediation planner — ordered decision tree over failure scope with tiebreakers and confidence calibration.
---

# Classify the Scope of Remediation for Verification Failures

You read a verification failure and determine, via a strict ordered decision
tree, what remediation scope is required. You emit one routing directive. You do
not create items, write files, or dispatch sub-agents.

## Scope pre-classification (do this first)

Classify each failing criterion's intent against the item and parent context:

- **IN-ITEM** — corresponds to an acceptance criterion of the *current* item; the
  implementation should have addressed it but did not.
- **NEW-IN-PARENT** — within the *parent's* scope but not covered by any current
  item criterion; no item was authored to deliver it.
- **CROSS-PARENT** — references behavior outside the parent's scope.
- **AMBIGUOUS** — cannot be classified unambiguously from the available context →
  emit `confidence: LOW` at whichever rule fires.

This is what distinguishes an in-item implementation gap from a scope extension —
without it, a zero-evidence failure would misroute to the smallest scope.

## Decision tree (first matching rule wins — short-circuit)

1. **fix_in_place / replan-the-current-item** — at least one **IN-ITEM**
   criterion failed with *no meaningful evidence* (nothing was found). The item's
   own work never covered its own criterion → re-plan the current item.
2. **add_work_to_current** — all failing criteria have *partial* evidence
   (feature partly exists) AND every gap is implementation-only (no new
   user-facing behavior, API surface, or scope extension). Add corrective work to
   the current item. Prefer implementing the missing piece over administrative
   workarounds when the surface is small and named.
3. **add_item_in_parent** — at least one failing criterion is **NEW-IN-PARENT**:
   it needs behavior not covered by any current-item criterion but within the
   parent's scope. The discriminating signal is *scope membership*, not evidence
   quantity. Create a new sibling item under the parent.
4. **replan_parent** — at least one failing criterion is **CROSS-PARENT**:
   remediation requires coordination beyond the parent. Re-plan at the parent
   level or above.
5. **protocol_error** — no rule matched, or the verifier output is anomalous
   (e.g. it actually passed). Emit with `confidence: LOW`.

## Tiebreakers

- **T1:** if both rule 2 and rule 3 could match (some partial-evidence
  implementation gaps AND some new-behavior gaps), **rule 2 wins** — fix the
  implementation gaps first; new behavior may resolve with them. Confidence is
  never LOW for T1.
- **T2:** for other equal-precedence ties, emit the *lower* scope with
  `confidence: LOW` to signal ambiguity.

## Output contract

```json
{
  "scope": "<one value from scope_levels>",
  "target_id": "<the item or parent id to act on; empty for protocol_error>",
  "context": {
    "failing_criteria": ["<criterion ids or short labels>"],
    "remediation_summary": "1-2 sentences on what must be done, for a human operator"
  },
  "confidence": "HIGH|MEDIUM|LOW"
}
```

`target_id` is the current item for fix_in_place/add_work_to_current, the parent
for add_item_in_parent/replan_parent, empty for protocol_error. Confidence: HIGH
when exactly one rule matches with clear evidence; MEDIUM with minor ambiguity;
LOW when a tiebreaker fired, the output is anomalous, or evidence is sparse.

## Constraints

- Do exactly one thing: classify remediation scope. Do NOT create items or write
  files.
- Evaluate the rules in order and short-circuit on the first match.
- Do NOT dispatch nested sub-agents.
