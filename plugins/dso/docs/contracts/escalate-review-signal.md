# Contract: escalate_review Signal

- Signal Name: escalate_review
- Status: accepted
- Scope: code-reviewer-* agents → REVIEW-WORKFLOW.md orchestrator Step 4a
- Date: 2026-04-07

## Purpose

This document defines the shared output interface for the `escalate_review` signal emitted by code-reviewer agents when they lack confidence in their review findings for specific items and request escalation to a higher-tier reviewer. The REVIEW-WORKFLOW.md orchestrator consumes this signal at Step 4a (after reviewer return, before overlay dispatch) to determine whether to escalate the review tier or request additional reviewer passes.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure the emitter and parser stay in sync.

---

## Signal Name

`escalate_review`

---

## Emitter

Code-reviewer agents — the following agents may emit this signal:

- `dso:code-reviewer-light` (haiku) — dispatched for complexity score 0–2
- `dso:code-reviewer-standard` (sonnet) — dispatched for complexity score 3–6
- `dso:code-reviewer-deep-correctness` (sonnet) — dispatched for complexity score 7+
- `dso:code-reviewer-deep-verification` (sonnet) — dispatched for complexity score 7+
- `dso:code-reviewer-deep-hygiene` (sonnet) — dispatched for complexity score 7+

The emitter appends an `escalate_review` field to the top-level `reviewer-findings.json` output when one or more findings warrant escalation. The field is optional — omitting it entirely is valid and indicates no escalation is requested.

---

## Parser

`plugins/dso/docs/workflows/REVIEW-WORKFLOW.md` — REVIEW-WORKFLOW.md orchestrator Step 4a # shim-exempt: internal implementation path reference

The parser reads `reviewer-findings.json` after the reviewer sub-agent returns, before overlay dispatch. If the `escalate_review` field is present and non-empty, the parser processes each escalation entry to determine whether to escalate the review tier.

---

## Signal Format

The signal is embedded as a top-level field in `reviewer-findings.json`:

```json
{
  "findings": [...],
  "escalate_review": [
    {
      "finding_index": 2,
      "reason": "This finding involves a subtle concurrency issue near a high-fan-in path I am not fully confident in — a deeper architectural review is warranted."
    },
    {
      "finding_index": 5,
      "reason": "The security implication here is unclear without deeper knowledge of the auth module's trust boundary assumptions."
    }
  ]
}
```

### Field definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `escalate_review` | array | No | Top-level array in `reviewer-findings.json`. Optional field. Absent = valid (no escalation). Empty array = valid (no escalation). Null = **invalid** — parsers must treat null as a malformed signal. |
| `finding_index` | integer | Yes (per element) | Zero-based index into the `findings` array identifying which finding the escalation request applies to. Must be a valid index into `findings`. |
| `reason` | string | Yes (per element) | Free-text explanation of why the reviewer lacks confidence in this finding and believes escalation is warranted. Must not be empty. |

### Validity rules

| Value | Validity |
|---|---|
| Field absent | Valid — no escalation requested |
| Empty array `[]` | Valid — no escalation requested |
| Array with one or more elements | Valid — escalation requested for listed findings |
| `null` | **Invalid** — parser must treat as malformed signal |
| Element with empty `reason` string | **Invalid** — parser must treat as malformed signal |
| Element with `finding_index` out of bounds | **Invalid** — parser must treat as malformed signal |

### Canonical parsing prefix

The parser reads the `escalate_review` key from the top-level JSON object of `reviewer-findings.json`. This is a structured JSON field — not a line-based text signal. The parser MUST:

1. Check whether `escalate_review` exists as a top-level key in the parsed JSON
2. If present, verify it is an array (not null, not a string, not an object)
3. For each element, verify `finding_index` (integer) and `reason` (non-empty string) are present
4. Validate each `finding_index` is within bounds of the `findings` array

No regex or prefix matching is needed — the signal is embedded in the validated JSON schema.

---

## Deep-Tier Deduplication Note

For complexity score 7+ reviews, three sonnet agents (`code-reviewer-deep-correctness`, `code-reviewer-deep-verification`, `code-reviewer-deep-hygiene`) run in parallel, and the `dso:code-reviewer-deep-arch` (opus) agent synthesizes their findings into a final `reviewer-findings.json`. Escalation deduplication happens **after** opus synthesis — the escalation entries in the final `reviewer-findings.json` reference the synthesized findings array indices, not the per-agent pre-synthesis indices. The opus synthesis agent is responsible for deduplicating escalation requests that refer to the same synthesized finding.

---

## Example Payload

**No escalation (field absent):**
```json
{
  "findings": [
    {"index": 0, "severity": "important", "dimension": "correctness", "description": "Off-by-one in loop bounds"}
  ]
}
```

**No escalation (empty array):**
```json
{
  "findings": [
    {"index": 0, "severity": "important", "dimension": "correctness", "description": "Off-by-one in loop bounds"}
  ],
  "escalate_review": []
}
```

**Escalation requested:**
```json
{
  "findings": [
    {"index": 0, "severity": "important", "dimension": "correctness", "description": "Off-by-one in loop bounds"},
    {"index": 1, "severity": "critical", "dimension": "correctness", "description": "Potential null dereference in auth path"},
    {"index": 2, "severity": "important", "dimension": "maintainability", "description": "Function is 120 lines with nested conditionals"}
  ],
  "escalate_review": [
    {
      "finding_index": 1,
      "reason": "This null dereference is in the auth path which has complex trust-boundary assumptions I am not fully confident about — a security-focused deeper review is warranted."
    }
  ]
}
```

---

## Failure Contract

If the `escalate_review` field is:

- `null` (invalid value),
- contains an element with an empty `reason` string,
- contains an element with a `finding_index` out of bounds for the `findings` array,
- or malformed JSON (unparseable),

then the parser MUST treat the entire `escalate_review` field as absent (no escalation) and log a warning so that silent degradation is detectable in debug output. The parser must NOT halt or block the review workflow on a malformed escalation signal.

---

## Consumers

The following components emit or consume this signal:

| Component | Role | Notes |
|---|---|---|
| `dso:code-reviewer-light` | Emitter | Haiku-tier reviewer (complexity 0–2); may emit escalation for findings beyond its confidence |
| `dso:code-reviewer-standard` | Emitter | Sonnet-tier reviewer (complexity 3–6); may emit escalation for high-blast-radius findings |
| `dso:code-reviewer-deep-correctness` | Emitter | Sonnet deep reviewer; pre-synthesis escalation entries translated to synthesized indices by opus |
| `dso:code-reviewer-deep-verification` | Emitter | Sonnet deep reviewer; pre-synthesis escalation entries translated to synthesized indices by opus |
| `dso:code-reviewer-deep-hygiene` | Emitter | Sonnet deep reviewer; pre-synthesis escalation entries translated to synthesized indices by opus |
| `dso:code-reviewer-deep-arch` | Dedup/synthesizer | Opus arch agent; deduplicates escalation entries across the three deep sonnet agents during synthesis |
| REVIEW-WORKFLOW.md orchestrator Step 4a | Parser | Reads `escalate_review` from `reviewer-findings.json` after reviewer return, before overlay dispatch |

All implementors must read this contract before modifying any code-reviewer agent prompt or the REVIEW-WORKFLOW.md Step 4a parser logic. Changes to the signal format require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (format changes, field removal, type changes) require updating both all emitters and parsers and this document atomically in the same commit. Additive changes that do not affect existing field definitions are backward-compatible.

### Change Log

- **2026-04-07**: Initial version — defines escalate_review signal for code-reviewer-* agents → REVIEW-WORKFLOW.md orchestrator Step 4a. Establishes optional array format, finding_index/reason field definitions, validity rules, deep-tier deduplication semantics, and fail-open failure contract.
