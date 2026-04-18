# Contract: Classifier Size Output Interface

- Signal Name: CLASSIFIER_SIZE_OUTPUT
- Status: accepted
- Scope: review-size-gating (epic w21-nv42)
- Date: 2026-03-22

## Purpose

This document defines the interface between `review-complexity-classifier.sh` (emitter) and `REVIEW-WORKFLOW.md` (parser) for diff size threshold fields. The classifier computes the scorable line count of the staged diff and determines whether the review should proceed normally, be escalated to opus, or receive a SIZE_WARNING and continue through the review. The parser uses these fields to apply size-based routing before dispatching any review agent.

This contract must be agreed upon before either side is implemented to prevent implicit assumptions and ensure emitter and parser stay in sync.

---

## Signal Name

`CLASSIFIER_SIZE_OUTPUT`

---

## Emitter

`scripts/review-complexity-classifier.sh` # shim-exempt: internal implementation path reference

The emitter counts added lines in non-test, non-generated source files from the staged diff, compares the count against threshold bands, and includes the resulting fields in the same JSON object it already emits for tier selection (see `classifier-tier-output.md`). The size fields are appended to that object; the emitter exits 0 on success or non-zero on failure.

---

## Parser

`docs/workflows/REVIEW-WORKFLOW.md` (Step 3)

The parser reads the JSON object from the emitter's stdout and checks `is_merge_commit` first. If `is_merge_commit` is `true`, size-based routing is skipped entirely. Otherwise, the parser inspects `size_action` and applies the corresponding action before dispatching the review agent.

---

## Fields

The size fields are emitted as part of the existing classifier JSON object alongside the tier fields. All size fields are required.

| Field | Type | Required | Description |
|---|---|---|---|
| `diff_size_lines` | integer | required | Count of added lines in non-test, non-generated source files in the staged diff. Test files (matching `tests/`, `*_test.*`, `test_*.py` patterns) and generated files (matching the review-gate allowlist) are excluded from this count. |
| `size_action` | string | required | Threshold determination result. One of: none, upgrade, warn. See **Size Action Values** below. |
| `is_merge_commit` | boolean | required | `true` when `MERGE_HEAD` is present and resolves to a valid commit object; `false` otherwise. When `true`, the parser must skip all size-based routing for this review pass. |

### Size Action Values

| `size_action` | `diff_size_lines` range | Parser behavior |
|---|---|---|
| `none` | < 300 | Proceed normally — no size-based routing change |
| `upgrade` | 300–599 | Upgrade the review model to opus at the current tier's scope (light → light-opus, standard → standard-opus, deep → deep-opus) |
| `warn` | ≥ 600 | Emit SIZE_WARNING:<count> to stderr; continue processing |

---

## Example JSON Payload

The size fields are included in the same JSON object as the tier fields:

```json
{
  "blast_radius": 1,
  "critical_path": 0,
  "anti_shortcut": 0,
  "staleness": 1,
  "cross_cutting": 2,
  "diff_lines": 2,
  "change_volume": 1,
  "computed_total": 7,
  "selected_tier": "deep",
  "diff_size_lines": 412,
  "size_action": "upgrade",
  "is_merge_commit": false
}
```

### Canonical parsing prefix

The parser MUST match against:

- `CLASSIFIER_SIZE_OUTPUT` — this contract defines a JSON stdout interface. The parser reads the full JSON object from the emitter's stdout and inspects the `size_action` and `is_merge_commit` fields. No line-prefix matching applies; the parser must deserialize the JSON object to access these fields.

---

## Re-Review Exemption Rule

Size limits apply **only to initial review dispatch** (the first call to the review agent in a review session). Re-review passes triggered by the autonomous resolution loop (REVIEW-WORKFLOW.md R3–R5) are exempt from size-based routing. When the parser is operating in a re-review or resolution context, it must skip the `size_action` check and dispatch the agent regardless of `diff_size_lines`. The `is_merge_commit` check is unaffected by this exemption — it always applies.

---

## Failure Contract

If the classifier:

- exits non-zero,
- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs malformed JSON (not parseable or missing required fields),

then the parser must default to `size_action: none` and `is_merge_commit: false`. The parser must not propagate the failure or block the commit workflow.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal) require updating both the emitter and this document atomically in the same commit. Additive changes (new optional fields) are backward-compatible and do not require a version bump.
