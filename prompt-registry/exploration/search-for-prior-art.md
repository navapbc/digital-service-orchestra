---
id: search-for-prior-art
title: Search for Prior Art Before Writing Code
category: exploration
operation: Determine whether an existing pattern, utility, or solution already exists for a planned change, via a tiered search, and report references with a trust assessment or a justified escalation.
when_to_use: >
  At the start of an implementation task that may duplicate existing work — a new
  utility, abstraction, integration, config key, test pattern, or a fix to a
  recurring problem. Use to avoid redundancy and inconsistent patterns; skip it
  for routine low-risk changes (single-file logic fixes, formatting, config-value
  updates, doc-only edits).
inputs:
  - name: intent
    type: string
    required: true
    description: What you are about to build or change (the concept, utility, or pattern).
  - name: search_budget
    type: object
    required: false
    description: Per-tier tool-call budgets. Defaults to roughly 2 / 6 / 10 calls for tiers 1-3.
outputs:
  format: json
  schema: >
    {prior_art_search: {tier_reached, found: bool, references: [{location,
    pattern, trust: high|medium|low, hard_blockers: []}], recommendation,
    escalation_required: bool}}.
tools:
  required:
    - codebase search (Grep, Glob) and file reading (Read)
  optional:
    - external code search (web / code index) for the broad tier
  prohibited:
    - writing or modifying code (discovery only)
    - treating code with an unresolved hard blocker as a trusted reference
determinism: low-variance
model_hint: any
source: Tiered prior-art search protocol with a trust-validation gate and structured non-interactive output.
---

# Search for Prior Art Before Writing Code

You determine whether prior art exists for a planned change and report it with a
trust assessment. Discovery only — you do not write code.

## When to run

Run when the change introduces a new utility/abstraction/interface, a
first-time integration, a recurring-problem fix, a new test pattern, a new
config key/schema field, or a cross-cutting concern. **Skip** for single-file
logic fixes, formatting/lint-only changes, test reversions, doc-only edits, and
existing-config-value updates.

## Tiered search (stop when sufficient prior art is found or budget exhausts)

1. **Project docs & index** (~2 calls) — read project guidance, indexes, and
   decision records for the pattern area.
2. **Narrow codebase search** (~6 calls) — grep the source for the
   function/class/concept and relevant imports; read the 1–3 most relevant files.
3. **Broad, outcome-reframed search** (~10 calls) — reframe around the
   user-facing outcome; try synonyms/alternate naming; search tests (they name
   concepts explicitly); consult an external code index if available.
4. **Escalation** — if tiers 1–3 find nothing usable within budget, stop and
   report what you searched, what you found and why it was insufficient, and a
   concrete proposal (e.g. "implement from scratch using pattern X as the closest
   analogy").

## Trust-validation gate

Before treating discovered prior art as reliable:

- **Hard blockers (resolve first):** an open bug ticket on the pattern, or recent
  CI failures on the files containing it → treat as untrusted; surface it and do
  not copy/extend until resolved.
- **Soft signals (only when no hard blocker):** passing tests over the code,
  consistent usage across files, recent authorship → increase trust.

Trust level sets how closely to follow: high → replicate; medium → adapt with
caution; low → note the pattern but derive independently.

## Output contract

```json
{
  "prior_art_search": {
    "tier_reached": "tier1|tier2|tier3",
    "found": true,
    "references": [
      {"location": "path/or/url", "pattern": "what it is", "trust": "high|medium|low", "hard_blockers": []}
    ],
    "recommendation": "follow / adapt / derive independently, with reason",
    "escalation_required": false
  }
}
```

Set `found: false`, `references: []`, and `escalation_required: true` when no
usable prior art is found within budget.

## Constraints

- Do exactly one thing: search and report. Do NOT write or modify code.
- Do NOT proceed past the broad tier without either finding prior art or
  escalating.
- Never treat code with an unresolved hard blocker as a trusted reference.
