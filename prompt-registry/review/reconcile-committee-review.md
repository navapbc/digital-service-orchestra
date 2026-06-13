---
id: reconcile-committee-review
title: Reconcile a Multi-Reviewer Committee Review
category: review
operation: Combine the scored outputs of several independent reviewers into one verdict via a pass threshold, and detect and resolve direct contradictions between their findings.
when_to_use: >
  When multiple independent reviewers (a committee) each score an artifact on
  dimensions and emit findings, and you need a single verdict plus a resolution
  of the places they contradict each other. Use to consolidate a parallel review
  panel — distinct from ruling on one reviewer's findings or filtering one set.
inputs:
  - name: reviews
    type: array
    required: true
    description: Each reviewer's output — perspective label, a map of dimension→score, and a findings array (each with severity and the target it concerns).
  - name: pass_threshold
    type: integer
    required: true
    description: The minimum score every dimension must meet for an overall PASS.
  - name: resolution_policy
    type: object
    required: false
    description: >
      How to resolve conflicts. Defaults to: critical-vs-minor → critical wins;
      both critical → escalate; both minor → caller chooses.
outputs:
  format: json
  schema: >
    {verdict: PASS|REVISE, failing_dimensions: [{reviewer, dimension, score}],
    conflicts: [{reviewers, target, pattern, resolution: critical-wins|escalate|caller-chooses}]}.
tools:
  required: []
  optional: []
  prohibited:
    - re-reviewing the artifact or inventing new findings
    - modifying any reviewer's scores or findings
    - dispatching nested sub-agents
determinism: deterministic
model_hint: sonnet
source: Committee review-protocol — score aggregation, conflict detection, and conflict resolution across reviewers.
---

# Reconcile a Multi-Reviewer Committee Review

You consolidate several independent reviewers' outputs into one verdict and
resolve their direct contradictions. You do not re-review the artifact or add
findings.

## Step 1 — Aggregate scores into a verdict

Collect every dimension score across all reviewers. The verdict is **PASS** only
when every dimension score is ≥ `pass_threshold` (or null for N/A). Any dimension
below threshold makes the verdict **REVISE**; list each such dimension with its
reviewer and score in `failing_dimensions`.

## Step 2 — Detect cross-reviewer conflicts

Scan the combined findings for **direct contradictions** — pairs of findings that
target the same task/artifact but pull in opposite directions. Classify each with
a short pattern label, e.g.:

- one says "split / expand" while another says "merge / reduce" → `expand_vs_reduce`
- one says "serialize / add dependency" while another says "keep parallel /
  atomic" → `strict_vs_flexible`
- one says "add coverage / a test" while another says "too many concerns / remove"
  → `add_vs_remove`

A conflict requires opposing directions on the *same* target — differing findings
on different targets are not conflicts.

## Step 3 — Resolve each conflict

Apply `resolution_policy` (defaults below):

- the two findings differ in severity (e.g. critical vs minor) → the higher
  severity wins, no escalation (`critical-wins`).
- both are high severity (both critical/major) → `escalate` to the caller.
- both are low severity → `caller-chooses` the direction.

## Output contract

```json
{
  "verdict": "PASS|REVISE",
  "failing_dimensions": [{"reviewer": "<label>", "dimension": "<name>", "score": 3}],
  "conflicts": [
    {"reviewers": ["A", "B"], "target": "<task/artifact>", "pattern": "expand_vs_reduce", "resolution": "critical-wins|escalate|caller-chooses"}
  ]
}
```

`failing_dimensions` and `conflicts` are empty arrays when none apply.

## Constraints

- Do exactly one thing: aggregate scores and reconcile conflicts. Do NOT
  re-review the artifact or invent findings.
- Do NOT modify any reviewer's scores or findings.
- A conflict requires opposing directions on the same target.
