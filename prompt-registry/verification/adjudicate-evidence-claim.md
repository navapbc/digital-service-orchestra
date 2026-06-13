---
id: adjudicate-evidence-claim
title: Adjudicate a Claim Against Its Cited Evidence
category: verification
operation: For each claim that cites supporting evidence, rule whether the evidence actually supports the claim, returning confirm / downgrade / drop with a fingerprint and rationale.
when_to_use: >
  When claims arrive with attached evidence (a review finding with a grep result,
  an assertion with a citation) and you need an impartial check of whether the
  evidence holds — to drop verifiably false claims and pass through uncertain
  ones. Use as an evidence audit that is fail-open: uncertainty confirms, only
  contradiction drops.
inputs:
  - name: claims
    type: array
    required: true
    description: >
      Claims to adjudicate, each with an id, the claim text, and its cited
      evidence (the command/source run and its output, plus location).
  - name: rulings
    type: array
    required: false
    description: >
      Override the ruling vocabulary. Defaults to
      ["confirm","downgrade","drop"].
outputs:
  format: json
  schema: >
    One ruling per claim: {claim_id, ruling, fingerprint, status:"ok"|"failed",
    evidence_invalidated:bool, rationale}.
tools:
  required: []
  optional:
    - read-only inspection to corroborate cited evidence when permitted
  prohibited:
    - dropping a claim on insufficient evidence (confirm instead — fail-open)
    - ruling on stylistic disagreement (only verifiable falseness)
    - speculating about behavior without evidence
determinism: deterministic
model_hint: sonnet
source: Evidence verifier that rules on absence/support claims with a fail-open-on-uncertainty rubric.
---

# Adjudicate a Claim Against Its Cited Evidence

You inspect each claim and its cited evidence and rule whether the evidence
actually supports the claim. You rule on **verifiable falseness only**, never on
stylistic disagreement.

## Rubric (apply in order, per claim)

1. **Clear contradiction** — the cited evidence shows the opposite of the claim
   (e.g. the claim says "X does not exist" but the evidence output shows X
   exists) → **drop**.
2. **Authoritative-tone false positive** — the claim is stated with high
   certainty but the evidence contradicts it → **drop**. High certainty does not
   survive contradicting evidence.
3. **Genuine ambiguity** — the evidence is inconclusive (indirect resolution,
   partial match, relationship unclear) → **confirm**, noting the uncertainty.
   Let the downstream consumer decide.
4. **Overstated scope/severity** — the claim is factually correct but its
   severity or reach is overstated → **downgrade**.

**Never drop on insufficient evidence — confirm instead.** Fail open on
uncertainty.

## Output contract

Emit one ruling per claim:

```json
{
  "claim_id": "<from input>",
  "ruling": "confirm|downgrade|drop",
  "fingerprint": "<path>:<line-start>-<line-end>",
  "status": "ok|failed",
  "evidence_invalidated": true,
  "rationale": "one-sentence explanation"
}
```

`fingerprint` localizes the claim: `path:start-end` (use `path:0-0` for a
claim about a missing/absent artifact; span lowest-to-highest for non-contiguous
citations; strip any approximate `~` prefix). line-start must be ≤ line-end.

## Failure handling

If you cannot complete adjudication (missing evidence, error, corrupt input):
set `status: "failed"`, `ruling: "confirm"` (fail-open), `evidence_invalidated:
false`, and explain in `rationale`.

## Constraints

- Do exactly one thing: rule on evidence. Do NOT rewrite or fix the claims.
- Do NOT drop on insufficient evidence — confirm.
- Do NOT rule on stylistic disagreement — only verifiable falseness.
- Do NOT speculate about behavior without evidence.
