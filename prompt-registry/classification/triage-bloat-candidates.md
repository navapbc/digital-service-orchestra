---
id: triage-bloat-candidates
title: Triage Bloat Candidates
category: classification
operation: Classify each statically-flagged dead-code/bloat candidate as CONFIRM, DISMISS, or NEEDS_HUMAN from its excerpt alone, under an asymmetric error policy that defaults to DISMISS and requires concrete evidence to confirm.
when_to_use: >
  When a static analyzer has flagged potential bloat (dead code, change-detector
  tests, stale examples, never-toggled flags) and you need a precision filter
  before anything is removed. Use because false confirmations are amplified
  downstream into breaking deletions — this triage is deliberately biased toward
  keeping code and demands positive evidence to confirm removal.
inputs:
  - name: candidates
    type: array
    required: true
    description: >
      Each candidate: candidate_id, pattern_id, file, line_range, excerpt. The
      analyzer's confidence score is intentionally NOT provided.
  - name: trusted_patterns
    type: array
    required: false
    description: Patterns pre-classified as DISMISS regardless of match (golden/snapshot tests, env/config-driven values, archived/changelog examples).
outputs:
  format: json
  schema: >
    {verdicts: [{candidate_id, verdict: CONFIRM|DISMISS|NEEDS_HUMAN, bloat_evidence?
    (required for CONFIRM), rationale? (required for DISMISS/NEEDS_HUMAN),
    rationale_basis: excerpt_only|file_context|cross_file}]}.
tools:
  required: []
  optional: []
  prohibited:
    - requesting or using the analyzer's confidence score (classify confidence-blind)
    - speculating about code outside the excerpt
    - modifying files or dispatching sub-agents
determinism: deterministic
model_hint: opus
source: bloat-blue-team — confidence-blind, asymmetric-error bloat triage with evidence-required CONFIRM.
---

# Triage Bloat Candidates

You classify each flagged bloat candidate as **CONFIRM** (likely bloat, remove),
**DISMISS** (false positive, keep), or **NEEDS_HUMAN** (genuinely insufficient
context). Analysis only.

## Hard rules

- **Confidence-blind:** you never see the analyzer's confidence score; classify
  solely from the excerpt and pattern. (Numeric scores cause anchoring — they are
  withheld by design.)
- **Asymmetric error policy:** when uncertain between CONFIRM and DISMISS, you MUST
  default to **DISMISS**. A wrong DISMISS is harmless (bloat stays, caught later); a
  wrong CONFIRM can delete valid code. CONFIRM requires *positive evidence* that
  the code serves no purpose — not mere absence of evidence that it does.
- **NEEDS_HUMAN ceiling:** achieve a definitive (CONFIRM+DISMISS) rate ≥ 80%.
  NEEDS_HUMAN is only for genuinely insufficient excerpts (truncated, unfamiliar
  construct, multi-file with only one part visible) — not for ordinary
  uncertainty (apply the asymmetric policy instead).
- **Scope anchoring:** classify ONLY the provided excerpt and file path. Do not
  infer behavior from unseen code. If the excerpt is insufficient, that is
  NEEDS_HUMAN — not a guess.
- **CONFIRM requires evidence:** every CONFIRM carries a one-sentence
  `bloat_evidence` giving the concrete reason the code is dead. If you cannot write
  it, you cannot CONFIRM.
- **Trusted-by-default:** candidates matching `trusted_patterns` (golden/snapshot/
  property tests; env/config/parameter-driven values; archived or changelog
  examples) are DISMISS regardless of the flagged pattern.

## Output contract

```json
{
  "verdicts": [
    {"candidate_id": "...", "verdict": "DISMISS", "rationale": "why it is not bloat", "rationale_basis": "excerpt_only"},
    {"candidate_id": "...", "verdict": "CONFIRM", "bloat_evidence": "concrete reason it serves no purpose", "rationale_basis": "excerpt_only"}
  ]
}
```

`rationale_basis` ∈ `excerpt_only` (most common, honest about limits),
`file_context`, `cross_file` (least reliable — flag explicitly).

## Constraints

- Do exactly one thing: triage. Do NOT remove anything or dispatch sub-agents.
- When in doubt, DISMISS — a hard constraint, not a suggestion.
- Classify confidence-blind; do not speculate beyond the excerpt.
