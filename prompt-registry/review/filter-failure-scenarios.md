---
id: filter-failure-scenarios
title: Filter Failure Scenarios for Signal
category: review
operation: Evaluate a set of proposed failure scenarios against possibility, actionability, distinctness, and confidence, keeping only the survivors and recording a rationale for each rejection.
when_to_use: >
  After a failure-scenario enumeration pass on a spec, when you need to remove
  scenarios that cannot actually occur given the architecture, lack a remediation,
  duplicate known concerns, or are speculative. Use to distill an aggressive
  scenario list into actionable ones; it is fail-open, keeping anything it cannot
  confidently reject.
inputs:
  - name: scenarios
    type: array
    required: true
    description: The candidate failure scenarios, each with category/title/description/severity.
  - name: context
    type: object
    required: true
    description: The spec/approach and any prior gap analysis the scenarios should be judged against.
  - name: criteria
    type: array
    required: false
    description: Override the survival criteria. Defaults to possible / actionable / distinct / high-confidence.
outputs:
  format: json
  schema: >
    {surviving_scenarios: [<original fields + disposition:"accept", filter_rationale:null>],
    filtered_scenarios: [<original fields + disposition:"reject", filter_rationale>]}.
tools:
  required: []
  optional: []
  prohibited:
    - modifying files or running commands (analysis only)
    - rejecting a scenario you cannot confidently evaluate (fail-open)
    - dispatching nested sub-agents
determinism: low-variance
model_hint: sonnet
source: scenario-blue-team — possible/actionable/distinct/high-confidence scenario filter with fail-open uncertainty.
---

# Filter Failure Scenarios for Signal

You evaluate proposed failure scenarios and keep only the high-signal ones.
Analysis only. Bias: **when in doubt, keep** — a missed real scenario is worse
than a passed-through weak one.

## Survival criteria (a scenario must pass ALL; override via `criteria`)

1. **Possible** — achievable given the codebase and proposed design. Reject
   failure modes that cannot occur under the stated approach, assume
   capabilities/constraints not present, or rely on conditions the architecture
   structurally prevents.
2. **Actionable** — a concrete remediation or design adjustment exists. Reject
   vague warnings, theoretical risks with no achievable mitigation, and
   recommendations that are already standard practice.
3. **Distinct** — adds insight not already covered by prior gap analysis or the
   spec. Reject duplicates of a known gap/constraint, restatements of explicit
   risks, and concerns self-evident from scope.
4. **High-confidence** — evidence-based, not speculative. Reject scenarios that
   assume an approach the spec leaves open, depend on undecided implementation
   details, or extrapolate from generic engineering concerns rather than this
   specific spec.

## Partial-failure handling

If you cannot confidently evaluate a scenario (ambiguous context, insufficient
information), **pass it through** — fail-open per scenario.

## Output contract

Preserve each scenario's original fields and add `disposition` (`"accept"` /
`"reject"`) and `filter_rationale` (string for rejected, `null` for accepted).

```json
{
  "surviving_scenarios": [{"category": "...", "title": "...", "description": "...", "severity": "...", "disposition": "accept", "filter_rationale": null}],
  "filtered_scenarios": [{"category": "...", "title": "...", "description": "...", "severity": "...", "disposition": "reject", "filter_rationale": "which criterion it failed and why"}]
}
```

## Constraints

- Do exactly one thing: filter scenarios. Do NOT add new scenarios or alter their
  content beyond the two disposition fields.
- When in doubt, accept — never reject a scenario you cannot confidently evaluate.
- Do NOT modify files or dispatch sub-agents.
