---
id: check-complexity-gate
title: Check a Proposed Complexity Against Warrant Gates
category: review
operation: Evaluate whether a proposed complexity (new dependency, new abstraction, speculative feature) is warranted by confirmed requirements or evidence, returning a per-gate PASS/FAIL with findings.
when_to_use: >
  When a design or change proposes added complexity and you need to gate it
  against over-engineering — speculative generality, premature abstraction, or an
  unjustified dependency. Use as a discipline check before accepting a proposal;
  it evaluates against confirmed requirements, not hypothetical futures.
inputs:
  - name: proposal
    type: object
    required: true
    description: The proposed change, including any new abstraction, dependency, or feature it introduces.
  - name: requirements
    type: array
    required: true
    description: The confirmed requirements / acceptance criteria the work must satisfy (the basis for "needed now").
  - name: codebase_access
    type: boolean
    required: false
    description: Whether call sites can be counted in the codebase (needed for the Rule-of-Three gate).
outputs:
  format: structured-block
  schema: >
    One block per gate: GATE, CHECKED, FINDING (concrete evidence), VERDICT
    (PASS|FAIL with a one-line action on FAIL). Gates: YAGNI, Rule of Three,
    Dependency Cost/Benefit.
tools:
  required: []
  optional:
    - codebase search to count existing call sites
  prohibited:
    - modifying any files (evaluation only)
    - passing a gate on hypothetical/future need rather than confirmed requirements
determinism: deterministic
model_hint: sonnet
source: Complexity gate — YAGNI, Rule of Three, and dependency cost/benefit checks.
---

# Check a Proposed Complexity Against Warrant Gates

You evaluate whether a proposed complexity is warranted by confirmed requirements
or evidence — not by hypothetical future needs. Evaluation only.

## Gates

**Gate 1 — YAGNI.** Does the proposal add a feature, abstraction, or
configuration option addressing a requirement absent from the confirmed
requirements? If so → FAIL (premature). Triggers: "we might need this later",
"future work will use this", config knobs for behaviors not yet required.

**Gate 2 — Rule of Three.** Does the proposal introduce a new abstraction (base
class, protocol, factory, shared utility) with fewer than three *existing* call
sites? Count actual current call sites — do not count the proposed new usage or
planned future ones. Fewer than three → FAIL (use inline logic).

**Gate 3 — Dependency cost/benefit.** Does the proposal add a new dependency? It
passes only if (a) the functionality cannot be replicated in ≲30 lines of
straightforward code, OR (b) the library provides a correctness/security
guarantee not achievable with custom code (cryptography, protocol compliance,
time-zone handling). State the inline line-count estimate and why the library
wins. Neither condition met → FAIL.

## Output contract

One block per applicable gate:

```
GATE: <gate name>
CHECKED: <the specific question evaluated>
FINDING: <concrete evidence from the proposal/codebase — not hypothetical>
VERDICT: PASS | FAIL — <one-line rationale; on FAIL, the recommended action>
```

A FAIL is not fatal by itself: it means the proposer must either remove the
complexity or attach a justified-complexity argument citing the confirmed
requirement that necessitates it.

## Constraints

- Do exactly one thing: evaluate the gates. Do NOT modify files.
- Base every verdict on confirmed requirements and concrete evidence — never pass
  a gate on hypothetical or future need.
- For Rule of Three, count only existing call sites.
