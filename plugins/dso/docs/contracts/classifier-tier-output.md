# Contract: Classifier Tier Output Interface

- Signal Name: CLASSIFIER_TIER_OUTPUT
- Status: accepted
- Scope: review-tier-classifier (epic w21-jtkr)
- Date: 2026-03-22

## Purpose

This document defines the interface between the classifier script and the review workflow parser. The classifier emits a JSON object that REVIEW-WORKFLOW.md Step 3 consumes to select the named review agent tier.

This contract must be agreed upon before either side is implemented to prevent implicit assumptions and ensure both emitter and parser stay in sync.

---

## Signal Name

`CLASSIFIER_TIER_OUTPUT`

---

## Emitter

`plugins/dso/scripts/review-complexity-classifier.sh` # shim-exempt: internal implementation path reference

The emitter computes a tier score from seven factors and prints a single JSON object to stdout, then exits 0 on success or non-zero on failure.

---

## Parser

`plugins/dso/docs/workflows/REVIEW-WORKFLOW.md` (Step 3)

The parser invokes the emitter, reads its stdout, and uses `selected_tier` to dispatch the appropriate named review agent.

---

## Schema

The emitter outputs a single JSON object on stdout. All fields are required.

| Field | Type | Description |
|---|---|---|
| `blast_radius` | integer | Score for blast-radius factor (0–3) |
| `critical_path` | integer | Score for critical-path factor (0–3) |
| `anti_shortcut` | integer | Score for anti-shortcut factor (0–3) |
| `staleness` | integer | Score for staleness factor (0–3) |
| `cross_cutting` | integer | Score for cross-cutting factor (0–3) |
| `diff_lines` | integer | Score for diff-lines factor (0–3) |
| `change_volume` | integer | Score for change-volume factor (0–3) |
| `computed_total` | integer | Sum of all seven factor scores before floor rules are applied |
| `selected_tier` | string | Final tier selection after floor rules; one of: `light`, `standard`, `deep` |
| `security_overlay` | boolean | `true` if the diff touches security-sensitive paths or contains security-related imports/keywords; `false` otherwise. Used by overlay dispatch to trigger the security review overlay. |
| `performance_overlay` | boolean | `true` if the diff touches performance-sensitive paths or contains performance-related keywords (SQL, async, pooling); `false` otherwise. Used by overlay dispatch to trigger the performance review overlay. |
| `test_quality_overlay` | boolean | `true` if the diff touches test files (paths matching `tests/**`, `test/**`, `**/test_*`, `**/tests/**`, `*_test.*`, `*.test.*`); `false` otherwise. Used by overlay dispatch to trigger the test quality review overlay. |

### per_factor_scores

The seven individual factor fields (`blast_radius`, `critical_path`, `anti_shortcut`, `staleness`, `cross_cutting`, `diff_lines`, `change_volume`) collectively constitute the `per_factor_scores` group. Each is an independent integer score contributed by the classifier's scoring logic.

### Tier Thresholds

| `computed_total` range | `selected_tier` |
|---|---|
| 0–2 | `light` |
| 3–6 | `standard` |
| 7+  | `deep` |

Floor rules applied by the classifier may raise `selected_tier` above the threshold-derived value (e.g., detection of behavioral file changes forces `deep` regardless of `computed_total`). `selected_tier` reflects the final decision after all floor rules; `computed_total` reflects the raw arithmetic sum before floors.

---

## Example

```json
{
  "blast_radius": 2,
  "critical_path": 0,
  "anti_shortcut": 0,
  "staleness": 1,
  "cross_cutting": 1,
  "diff_lines": 1,
  "change_volume": 0,
  "computed_total": 5,
  "selected_tier": "standard",
  "security_overlay": false,
  "performance_overlay": false,
  "test_quality_overlay": false
}
```

### Canonical parsing prefix

The parser MUST match against:

- `CLASSIFIER_TIER_OUTPUT` — this contract defines a JSON stdout interface. The parser reads the full JSON object from the emitter's stdout and inspects the `selected_tier`, `security_overlay`, `performance_overlay`, and `test_quality_overlay` fields. No line-prefix matching applies; the parser must deserialize the JSON object to access these fields.

---

## Exit Code Semantics

| Exit code | Meaning |
|---|---|
| `0` | Success — stdout contains valid JSON conforming to this schema |
| non-zero | Failure — stdout may be absent, partial, or malformed |

---

## Failure Contract

If the classifier:

- exits non-zero,
- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs malformed JSON (not parseable or missing required fields),

then the parser **must** default to `standard` tier. The parser must not propagate the failure or block the commit workflow.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal) require updating both the emitter and this document atomically in the same commit. Additive changes (new required fields that do not alter existing fields) are backward-compatible for parsers that ignore unknown keys, and do not require a version bump.

### Change Log

- **2026-04-06**: Added `test_quality_overlay` boolean field (story 9ebb-43ea, task c450-f4f6). Required field (always present in output). Backward-compatible: existing parsers that do not read this field are unaffected.
- **2026-03-28**: Added `security_overlay` and `performance_overlay` boolean fields (epic dso-5ooy). These are required fields (always present in output). Backward-compatible: existing parsers that do not read these fields are unaffected since they add new keys rather than modifying existing ones.
