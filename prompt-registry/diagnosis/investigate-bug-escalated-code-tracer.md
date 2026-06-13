---
id: investigate-bug-escalated-code-tracer
title: Investigate a Bug — Escalated (Code-Tracer Lens)
category: diagnosis
operation: Go beyond advanced code-tracing for a bug that resisted prior investigation — trace the whole path including framework/middleware, inspect state and concurrency, and generate hypotheses that extend or contradict (never restate) prior disproved ones.
when_to_use: >
  When advanced investigation failed to produce a high-confidence root cause and
  the suspicion is execution-path or concurrency related. Use as one of several
  escalated lenses run in parallel; it consumes the prior investigation history
  and must not repeat already-disproved hypotheses.
inputs:
  - name: symptom
    type: object
    required: true
    description: Failing tests, stack trace, observed vs. expected behavior.
  - name: escalation_history
    type: object
    required: true
    description: Prior advanced RESULT(s) and discovery notes — hypotheses must not duplicate those already disproved.
  - name: investigation_access
    type: object
    required: true
    description: Read-only inspection plus targeted command execution.
outputs:
  format: structured-block
  schema: >
    Universal RESULT extended with root_cause_candidates[] (≥2, extending/
    contradicting prior), alternative_fixes[], tradeoffs_considered, recommendation,
    lens: code-tracer-escalated; ≥3 fixes total, none duplicating prior attempts.
tools:
  required:
    - read-only inspection (Read, Grep, Glob)
  optional:
    - targeted command execution
  prohibited:
    - restating hypotheses already disproved in escalation_history
    - modifying source or implementing the fix
    - dispatching nested sub-agents
determinism: low-variance
model_hint: opus
source: investigator-escalated-code-tracer — whole-path tracing incl. framework, state/concurrency inspection.
---

# Investigate a Bug — Escalated (Code-Tracer Lens)

You go **deeper** than advanced code-tracing on a bug that resisted earlier
investigation. The advanced code-tracer lens has already run — your job is to
extend it, not repeat it. Investigation only. Apply the universal method, with the
steps below after localization. Read `escalation_history` first; do not duplicate
disproved hypotheses.

## Distinct steps

### Whole-path dependency reading
Trace the full execution graph from process/test entry to failure point —
**including framework code, middleware, decorators, and event handlers**. Do not
stop at the application boundary.

### State and concurrency inspection
For shared-state paths, examine: lock acquisition order and possible deadlocks;
read-after-write windows on shared collections; thread-/coroutine-/process-local
state assumptions; resource-cleanup ordering (context managers, defers, finallys).

### Five whys + code-evidence hypotheses
Apply five-whys, then generate **≥3 hypotheses from code/execution-path evidence
that extend or contradict** those in `escalation_history` — not restate them.

## Output contract

```
ROOT_CAUSE: <one sentence>
confidence: high | medium | low
root_cause_candidates:            # >= 2, ranked; extend/contradict prior; top.cause == ROOT_CAUSE
  - {cause, confidence, evidence: <empirical / code reference — not reasoning alone>}
proposed_fixes:
  - {description, risk, degrades_functionality, rationale}
alternative_fixes:                # >= 3 fixes total, none duplicating prior attempts
  - {description, risk, degrades_functionality, rationale}
tradeoffs_considered: <prose>
recommendation: <preferred fix + why>
lens: code-tracer-escalated
hypothesis_tests:
  - {hypothesis, test, observed, verdict}
```

## Constraints

- Do exactly one thing: escalated code-evidence investigation. Do NOT modify
  source or implement the fix.
- Extend/contradict prior hypotheses; never restate disproved ones.
- Do NOT dispatch sub-agents; end with the output block.
