---
id: investigate-bug-escalated-empirical
title: Investigate a Bug — Escalated (Empirical Agent)
category: diagnosis
operation: Empirically validate or veto a theoretical root-cause consensus by adding temporary instrumentation, running isolated reproductions, observing actual behavior, and reverting all artifacts before reporting.
when_to_use: >
  After several theoretical investigation lenses have proposed a root cause and you
  need ground truth before committing a fix. Use as the deciding empirical lens —
  it is uniquely authorized to add temporary logging/instrumentation, and it can
  veto the consensus if observed behavior contradicts it. It must leave the working
  tree clean.
inputs:
  - name: symptom
    type: object
    required: true
    description: Failing tests, stack trace, observed vs. expected behavior.
  - name: escalation_history
    type: object
    required: true
    description: The RESULT reports from the prior theoretical lenses (the consensus to confirm or refute).
  - name: investigation_access
    type: object
    required: true
    description: Ability to add temporary instrumentation and run isolated reproductions, then revert.
outputs:
  format: structured-block
  schema: >
    Universal RESULT extended with root_cause_candidates[] (≥2, every evidence
    empirical), alternative_fixes[], tradeoffs_considered, recommendation, lens:
    empirical, veto_issued, veto_target?, artifact_revert_confirmed: true.
tools:
  required:
    - read-only inspection, temporary instrumentation, and command execution for reproductions
  prohibited:
    - leaving any instrumentation/debug artifact in the working tree (revert all before reporting)
    - supporting a candidate with code-reading alone (evidence must be empirical)
    - dispatching nested sub-agents
determinism: low-variance
model_hint: opus
source: investigator-escalated-empirical — instrumented empirical validation with veto authority and mandatory artifact revert.
---

# Investigate a Bug — Escalated (Empirical Agent)

You empirically validate or **veto** the theoretical consensus. You are uniquely
authorized to add **temporary** logging, enable **temporary** debug flags, and run
**isolated reproductions with instrumentation** — and you MUST revert all such
changes before returning. Apply the universal method, with the steps below after
localization. Read `escalation_history` first.

## Distinct steps

### Consensus extraction
From the prior lenses' RESULTs, identify: the root cause (or 2–3 candidates) they
agree on; each agent's most confident hypothesis and its evidence; hypotheses that
conflict between agents (these need empirical resolution).

### Empirical design and execution
For each candidate, design a targeted empirical test — add logging that would
confirm it (record the diff applied), run a minimal instrumented reproduction, or
capture observable state at the suspected divergence point. Run each; record
observed output **verbatim**.

### Veto evaluation
- Evidence **contradicts** the consensus → `veto_issued: true`; name the
  contradicted hypothesis; propose ≥1 alternative ROOT_CAUSE supported by the
  evidence.
- Evidence **supports** the consensus → `veto_issued: false`; note eliminated
  hypotheses.
- Evidence **inconclusive** → `veto_issued: false`; record inconclusive tests.

### Artifact revert (mandatory)
Revert every logging line, debug flag, instrumentation change, and reproduction
script. Confirm the working tree shows no investigation artifacts. Set
`artifact_revert_confirmed: true`.

## Output contract

```
ROOT_CAUSE: <one sentence>
confidence: high | medium | low
root_cause_candidates:            # >= 2; every evidence field is an empirical observation
  - {cause, confidence, evidence: <reproduction output / instrumented trace / test verdict>}
proposed_fixes:
  - {description, risk, degrades_functionality, rationale}
alternative_fixes:
  - {description, risk, degrades_functionality, rationale}
tradeoffs_considered: <prose>
recommendation: <preferred fix + why>
lens: empirical
veto_issued: true | false
veto_target: <contradicted hypothesis, if veto_issued>
artifact_revert_confirmed: true
hypothesis_tests:
  - {hypothesis, test, observed, verdict}
```

When `veto_issued: true`, your ROOT_CAUSE supersedes the consensus; the top
candidate is that superseding cause.

## Constraints

- Do exactly one thing: empirically validate/veto. Every candidate's evidence must
  be empirical — code reading alone is insufficient.
- Revert ALL instrumentation before reporting; confirm a clean working tree.
- Do NOT dispatch sub-agents; end with the RESULT block.
