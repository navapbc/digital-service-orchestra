# Contract: review-findings-schema

- Signal Name: review-findings-schema
- Status: accepted
- Scope: finding records and relation taxonomy (cycle-N+1 reviewer Call 2 → review orchestrator)
- Date: 2026-05-07

> **Scope disambiguation**: This contract defines finding records and relation taxonomy. For review lifecycle events see [review-event-schema.md](review-event-schema.md).

## Purpose

This document defines the canonical schema for reviewer finding records emitted in `reviewer-findings.json`, with particular focus on the `relation` field taxonomy introduced for multi-cycle review (cycle-N+1). The relation field allows the review orchestrator to classify each finding as new (on changed code or pre-existing code), a re-raise of a prior defended finding, or a reframing of a prior finding — enabling deterministic severity rules, arbiter dispatch, and completeness validation without LLM calls on the schema layer.

This contract must be agreed upon before any implementation begins to prevent implicit assumptions and ensure all reviewer agents and the review orchestrator remain in sync.

---

## Signal Name

`review-findings-schema`

---

## Emitter

Cycle-N+1 reviewer agents emit the `relation` field (and optional `prior_finding_id` / `escape_rationale` fields) in their Call 2 output. Applicable agents:

- `dso:code-reviewer-light` (haiku)
- `dso:code-reviewer-standard` (sonnet)
- `dso:code-reviewer-deep-correctness` (sonnet)
- `dso:code-reviewer-deep-verification` (sonnet)
- `dso:code-reviewer-deep-hygiene` (sonnet)
- `dso:code-reviewer-deep-arch` (opus) — synthesizes parallel deep-tier findings; writes final `reviewer-findings.json`

On the **first review cycle** (no prior findings), relation is always `NEW_INTRODUCED` and `prior_finding_id` is absent.

---

## Parser

The review orchestrator (`docs/workflows/REVIEW-WORKFLOW.md`) reads `reviewer-findings.json` after the reviewer sub-agent returns. It applies auto-downgrade rules, validates `prior_finding_id` references, checks `escape_rationale` structural validity, and enforces Call 2 completeness — all without LLM calls.

---

## Signal Format

Each element of the `findings` array in `reviewer-findings.json` MAY include the relation fields:

```json
{
  "findings": [
    {
      "index": 0,
      "finding_id": "f-abc123",
      "severity": "important",
      "dimension": "correctness",
      "description": "...",
      "cited_lines": ["src/foo.py:42"],
      "relation": "NEW_INTRODUCED",
      "prior_finding_id": null,
      "escape_rationale": null
    },
    {
      "index": 1,
      "finding_id": "f-def456",
      "severity": "minor",
      "dimension": "maintainability",
      "description": "...",
      "cited_lines": ["src/bar.py:10"],
      "relation": "NEW_PRE_EXISTING",
      "prior_finding_id": null,
      "escape_rationale": null
    },
    {
      "index": 2,
      "finding_id": "f-ghi789",
      "severity": "important",
      "dimension": "correctness",
      "description": "...",
      "cited_lines": ["src/baz.py:77"],
      "relation": "RESUSTAIN_OF",
      "prior_finding_id": "f-abc000",
      "escape_rationale": null
    },
    {
      "index": 3,
      "finding_id": "f-jkl012",
      "severity": "critical",
      "dimension": "security",
      "description": "...",
      "cited_lines": ["src/auth.py:5"],
      "relation": "REFRAME_OF",
      "prior_finding_id": "f-xyz999",
      "escape_rationale": null
    }
  ]
}
```

---

### Canonical parsing prefix

`reviewer-findings.json` is a JSON file, not a line-prefix-delimited format. Parsers identify relation fields by reading the `relation` key from each element of the `findings` array.

**Parsing rules**:

1. Read `reviewer-findings.json` as a JSON object. The `findings` key is an array of finding objects.
2. For each finding, read the `relation` field:
   - If `relation` is present and a recognized enum value, apply the corresponding semantics.
   - If `relation` is absent or null (first-cycle reviews), treat as `NEW_INTRODUCED` (fail-open default).
   - If `relation` contains an unrecognized value, treat as `NEW_INTRODUCED` and emit a warning.
3. Parsers MUST NOT reject a finding solely because `relation` is absent — absence is valid on first-cycle reviews and on cycle-N+1 findings that survived the completeness check fallback.

There is no line-based prefix for this signal. The JSON file itself is the record; parsers operate on the parsed object, not on raw text lines.

---

## Field Definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `finding_id` | string | Yes | Stable identifier for this finding, unique within the review cycle. Format: `f-<hex8>`. |
| `severity` | string | Yes | One of: `critical`, `important`, `minor`. Auto-downgrade rules may lower this value (see below). |
| `dimension` | string | Yes | Review dimension: `correctness`, `security`, `maintainability`, `performance`, `hygiene`. |
| `description` | string | Yes | Finding description. |
| `cited_lines` | array of string | Yes | List of `<file>:<line>` references supporting the finding. |
| `relation` | string | Yes (cycle N+1) | One of four enum values — see Relation Enum table. Absent on first-cycle reviews (treated as `NEW_INTRODUCED`). |
| `prior_finding_id` | string or null | Conditional | Required for `RESUSTAIN_OF` and `REFRAME_OF`. Must match a `finding_id` in `prior_findings.json`. Absent (null) for `NEW_INTRODUCED`. Absent for `NEW_PRE_EXISTING` unless `escape_rationale` is provided. |
| `escape_rationale` | string or null | Conditional | See escape_rationale format section. |
| `severity_history` | array | Auto-populated | Populated by the orchestrator on auto-downgrade. Each entry: `{"from": "<sev>", "to": "<sev>", "reason": "<reason>", "cycle": <N>}`. |

---

## Relation Enum

| Value | Semantics | `prior_finding_id` | Severity rules |
|---|---|---|---|
| `NEW_INTRODUCED` | Finding is on code lines present in the cycle-N fix delta (changed/added lines). No prior finding connection. | Absent (null) unless `escape_rationale` overrides proximity-overlap check. | Unrestricted — reviewer may assign `critical`, `important`, or `minor`. |
| `NEW_PRE_EXISTING` | Finding is on pre-existing code not previously flagged by any prior finding. | Absent (null) unless `escape_rationale` is provided. | Auto-downgraded to `minor` UNLESS `prior_finding_id` references a prior finding previously rated `important` or `critical`. |
| `RESUSTAIN_OF` | Re-raises a specific prior finding. The reviewer asserts the prior finding's concern was not adequately resolved. | **Required** — must match a `finding_id` in `prior_findings.json`. | No automatic severity change. Triggers arbiter dispatch when the prior finding was defended (R5). |
| `REFRAME_OF` | Re-casts a prior finding with different framing, new cited lines, or updated severity assessment. | **Required** — must match a `finding_id` in `prior_findings.json`. | No automatic severity change. The reframed finding replaces the prior finding for resolution tracking purposes. |

### Validity rules

| Condition | Validity |
|---|---|
| `relation` absent on first-cycle review | Valid — treated as `NEW_INTRODUCED` |
| `relation` absent on cycle N+1 review | **Invalid** — orchestrator must flag and default to `NEW_INTRODUCED` with a warning |
| `prior_finding_id` present for `NEW_INTRODUCED` without `escape_rationale` | **Invalid** — orchestrator rejects; `prior_finding_id` must be null |
| `prior_finding_id` absent for `RESUSTAIN_OF` or `REFRAME_OF` | **Invalid** — orchestrator rejects the finding; reviewer must be re-dispatched |
| `prior_finding_id` does not match any ID in `prior_findings.json` | **Invalid** — orchestrator rejects the finding |

---

## Auto-Downgrade Rule

`NEW_PRE_EXISTING` findings are subject to automatic severity downgrade. The orchestrator applies this rule without LLM calls:

**Trigger preconditions** — ALL of the following must be true for auto-downgrade to apply:
1. The finding's `relation` is `NEW_PRE_EXISTING`.
2. `prior_finding_id` is absent (null).
3. The finding's `severity` is `important` or `critical`.

**Rule**: When all three preconditions are met, the orchestrator lowers `severity` to `minor`.

**Exception** — auto-downgrade does NOT apply when:
- `prior_finding_id` references a prior finding previously rated `important` or `critical`. In this case the severity is preserved as emitted.
- The finding is `NEW_INTRODUCED` (different relation; rule does not apply).

**Allowed severity transitions under auto-downgrade**:

| Emitted severity | Downgraded to | Condition |
|---|---|---|
| `critical` | `minor` | `NEW_PRE_EXISTING`, no qualifying `prior_finding_id` |
| `important` | `minor` | `NEW_PRE_EXISTING`, no qualifying `prior_finding_id` |
| `minor` | `minor` (no change) | Auto-downgrade is a no-op; no `severity_history` entry added |

**Irreversibility**: Downgrade is irreversible within a review cycle. A subsequent cycle may re-raise a previously-downgraded finding only via `RESUSTAIN_OF` or `REFRAME_OF` with a valid `prior_finding_id`.

**severity_history entry**: When auto-downgrade fires, the orchestrator appends one entry to the finding's `severity_history` array:

```json
{
  "from": "important",
  "to": "minor",
  "reason": "auto_downgrade",
  "cycle": 2
}
```

---

## escape_rationale Format

`escape_rationale` is a free-text string, maximum 512 characters.

**Purpose**: When a reviewer believes a `NEW_INTRODUCED` finding covers code on new lines but its `cited_lines` overlap with the proximity window of a prior finding, `escape_rationale` justifies treating it as `NEW_INTRODUCED` rather than `RESUSTAIN_OF`.

**Structural validity requirement** (evaluated by orchestrator without LLM calls): When `escape_rationale` is supplied, it MUST reference at least one token or cited-line pattern that is:

1. Present in the new finding's diff context, AND
2. NOT present in the prior finding's `cited_lines` content, AND
3. NOT within the ±5-line proximity overlap region between the new finding's `cited_lines` and the prior finding's `cited_lines`.

The orchestrator evaluates this by token-level set comparison on the cited-line content, not by LLM judgment.

**Rejection behavior**: Rationales failing the structural validity check are rejected and the finding is treated as if no `escape_rationale` was provided. The orchestrator logs the rejection reason so silent degradation is detectable.

| Field | Validity |
|---|---|
| `escape_rationale` null or absent | Valid — no escape claimed |
| Non-empty string ≤ 512 chars | Valid structurally — subject to proximity-overlap check |
| String > 512 chars | **Invalid** — orchestrator truncates to 512 chars and treats as if no `escape_rationale` |
| Empty string `""` | **Invalid** — treated as absent |

---

## Call 2 Completeness Check Protocol

On cycle N+1 reviews, the reviewer performs two calls: Call 1 (initial findings) and Call 2 (reconciled findings with relation fields). The orchestrator enforces that Call 2 is complete relative to Call 1.

**Protocol**:

1. After Call 1, the orchestrator captures all `finding_id` values as the Call 1 reference set.
2. After Call 2, the orchestrator checks that every `finding_id` from Call 1 appears in the Call 2 output.
3. If any `finding_id` is missing from Call 2, the orchestrator dispatches a single re-request with message:

   > "Finding `<id>` was present in Call 1 but absent from your response; include it with an appropriate relation."

   One re-dispatch is issued per missing finding ID, or a batched message listing all missing IDs.

4. **Persistent absence**: If a finding ID is still absent after re-dispatch, the orchestrator carries it forward with `relation: NEW_INTRODUCED` as the safe default and logs a warning.

**Rationale**: Completeness is enforced to prevent silent finding drops between cycles, which could allow a reviewer to implicitly dismiss prior concerns without explicit `REFRAME_OF` or `RESUSTAIN_OF` classification.

---

## Example Payloads

### First cycle (no prior findings, relation absent)

```json
{
  "findings": [
    {
      "index": 0,
      "finding_id": "f-a1b2c3d4",
      "severity": "important",
      "dimension": "correctness",
      "description": "Off-by-one in loop bounds at line 42",
      "cited_lines": ["src/processor.py:42"]
    }
  ]
}
```

### Cycle N+1 — NEW_INTRODUCED (on changed code)

```json
{
  "findings": [
    {
      "index": 0,
      "finding_id": "f-e5f6g7h8",
      "severity": "critical",
      "dimension": "security",
      "description": "SQL injection vector in new query builder",
      "cited_lines": ["src/db.py:88"],
      "relation": "NEW_INTRODUCED",
      "prior_finding_id": null,
      "escape_rationale": null
    }
  ]
}
```

### Cycle N+1 — NEW_PRE_EXISTING (auto-downgraded)

```json
{
  "findings": [
    {
      "index": 0,
      "finding_id": "f-i9j0k1l2",
      "severity": "minor",
      "dimension": "maintainability",
      "description": "Long function with nested conditionals (pre-existing)",
      "cited_lines": ["src/legacy.py:210"],
      "relation": "NEW_PRE_EXISTING",
      "prior_finding_id": null,
      "escape_rationale": null,
      "severity_history": [
        {"from": "important", "to": "minor", "reason": "auto_downgrade", "cycle": 2}
      ]
    }
  ]
}
```

### Cycle N+1 — RESUSTAIN_OF (triggers arbiter dispatch)

```json
{
  "findings": [
    {
      "index": 0,
      "finding_id": "f-m3n4o5p6",
      "severity": "important",
      "dimension": "correctness",
      "description": "Off-by-one still present — prior defense was insufficient",
      "cited_lines": ["src/processor.py:42"],
      "relation": "RESUSTAIN_OF",
      "prior_finding_id": "f-a1b2c3d4",
      "escape_rationale": null
    }
  ]
}
```

### Cycle N+1 — REFRAME_OF (replaces prior finding)

```json
{
  "findings": [
    {
      "index": 0,
      "finding_id": "f-q7r8s9t0",
      "severity": "critical",
      "dimension": "security",
      "description": "The prior finding was framed as correctness, but the real risk is an auth bypass",
      "cited_lines": ["src/processor.py:42", "src/auth.py:15"],
      "relation": "REFRAME_OF",
      "prior_finding_id": "f-a1b2c3d4",
      "escape_rationale": null
    }
  ]
}
```

---

## Failure Contract

The orchestrator MUST handle the following failure cases without halting the review workflow:

| Failure | Orchestrator behavior |
|---|---|
| `relation` absent on cycle N+1 finding | Default to `NEW_INTRODUCED`; emit warning |
| `prior_finding_id` absent for `RESUSTAIN_OF` or `REFRAME_OF` | Reject finding; re-dispatch reviewer with error message |
| `prior_finding_id` does not match any ID in `prior_findings.json` | Reject finding; re-dispatch reviewer with error message |
| `escape_rationale` fails structural validity check | Treat as absent; log rejection reason; apply default relation rules |
| `escape_rationale` exceeds 512 chars | Truncate to 512; log warning; apply structural validity check on truncated value |
| Call 2 missing findings from Call 1 (after re-dispatch) | Carry forward with `relation: NEW_INTRODUCED`; log warning |
| `severity_history` contains entries outside allowed transitions | Log warning; keep the emitter-supplied `severity_history` entry for audit |

All failures must be logged so silent degradation is detectable in debug output. No failure mode may block the review workflow — the contract is fail-safe.

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `dso:code-reviewer-light` | Emitter | First-cycle: no relation field. Cycle N+1: emits relation + prior_finding_id. |
| `dso:code-reviewer-standard` | Emitter | Same as above. |
| `dso:code-reviewer-deep-correctness` | Emitter | Emits pre-synthesis relation fields; opus translates to synthesized indices. |
| `dso:code-reviewer-deep-verification` | Emitter | Same as above. |
| `dso:code-reviewer-deep-hygiene` | Emitter | Same as above. |
| `dso:code-reviewer-deep-arch` | Synthesizer | Opus agent; synthesizes parallel deep-tier findings; translates pre-synthesis relation fields to synthesized `finding_id` references. |
| REVIEW-WORKFLOW.md orchestrator | Parser | Applies auto-downgrade, validates prior_finding_id, runs completeness check, triggers arbiter dispatch on RESUSTAIN_OF of defended findings. |
| `prior_findings.json` | Reference store | Provides prior-cycle finding IDs and severity ratings for `prior_finding_id` validation and auto-downgrade exception logic. |

All implementors must read this contract before modifying any code-reviewer agent prompt or REVIEW-WORKFLOW.md orchestrator review-cycle logic. Changes to the signal format require updating all conforming emitters, parsers, and this document atomically in the same commit.

---

## Versioning

This contract is versioned. Breaking changes (field removal, enum value removal, type changes) require updating all emitters and parsers and this document atomically in the same commit. Additive changes that do not affect existing field definitions are backward-compatible.

### Change Log

- **2026-05-07**: Initial version — defines review-findings-schema relation taxonomy (NEW_INTRODUCED, NEW_PRE_EXISTING, RESUSTAIN_OF, REFRAME_OF), prior_finding_id rules, escape_rationale structural validation, auto-downgrade rule with severity_history, and Call 2 completeness check protocol. Emitted by cycle-N+1 reviewer agents; parsed by REVIEW-WORKFLOW.md orchestrator.
