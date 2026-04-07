# Contract: Classifier Telemetry Output Interface

- Signal Name: CLASSIFIER_TELEMETRY
- Status: accepted
- Scope: review-tier-classifier (epic w21-0kt1)
- Date: 2026-03-22

## Purpose

This document defines the schema for `classifier-telemetry.jsonl` — the append-only JSONL log emitted by `plugins/dso/scripts/review-complexity-classifier.sh` on each invocation. # shim-exempt: internal implementation path reference Each line is a self-contained JSON record capturing the full classification decision (tier scores, size fields, and the list of staged files) for post-deployment calibration and drift analysis.

This contract must be agreed upon before any calibration tooling consumes the log to prevent implicit schema assumptions.

---

## Signal Name

`CLASSIFIER_TELEMETRY`

---

## Emitter

`plugins/dso/scripts/review-complexity-classifier.sh` # shim-exempt: internal implementation path reference

On each successful classification, the emitter appends one JSON record (no trailing newline added between records — standard JSONL) to `$ARTIFACTS_DIR/classifier-telemetry.jsonl`. The emitter exits 0 on success or non-zero on failure; telemetry write failures must not affect the classifier's stdout output or exit code.

---

## Parser

Currently no automated consumer exists. The intended future consumer is post-deployment calibration tooling that reads `classifier-telemetry.jsonl` to detect scoring drift, validate tier threshold tuning, and audit classification decisions.

---

## Fields

Each JSONL record is a JSON object. All fields are required.

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
| `files` | array of strings | List of staged source file paths included in the classification (paths relative to repo root; test and generated files excluded) |
| `diff_size_lines` | integer | Count of added lines in non-test, non-generated source files in the staged diff (see `classifier-size-output.md`) |
| `size_action` | string | Threshold determination result; one of: `none`, `upgrade`, `reject` (see `classifier-size-output.md`) |
| `is_merge_commit` | boolean | `true` when `MERGE_HEAD` is present and resolves to a valid commit object; `false` otherwise |

### Field Relationships

- `blast_radius`, `critical_path`, `anti_shortcut`, `staleness`, `cross_cutting`, `diff_lines`, `change_volume` are the seven per-factor scores that sum to `computed_total`.
- `selected_tier` reflects the final decision after all floor rules; `computed_total` reflects raw arithmetic before floors.
- `diff_size_lines`, `size_action`, and `is_merge_commit` mirror the fields defined in `classifier-size-output.md` and are included in telemetry for complete per-decision audit trail.
- `files` captures the exact staged file set used for scoring, enabling calibration tooling to reproduce or re-score historical decisions.

---

## Example JSONL Entry

```json
{"blast_radius":2,"critical_path":0,"anti_shortcut":0,"staleness":1,"cross_cutting":1,"diff_lines":1,"change_volume":0,"computed_total":5,"selected_tier":"standard","files":["plugins/dso/scripts/review-complexity-classifier.sh","plugins/dso/docs/contracts/classifier-tier-output.md"],"diff_size_lines":87,"size_action":"none","is_merge_commit":false} # shim-exempt: JSON example data showing actual file paths in telemetry output
```

Each line in `classifier-telemetry.jsonl` is a complete, independent JSON record. Consumers must parse line-by-line; they must not attempt to parse the file as a single JSON document.

### Canonical parsing prefix

The parser MUST match against:

- `CLASSIFIER_TELEMETRY` — this contract defines a JSONL append-only log format. Consumers parse the file line-by-line; each line is a complete JSON object. No line-prefix string matching applies — consumers must deserialize each JSON record and inspect its fields independently.

---

## Independence from review-gate-telemetry.jsonl

`classifier-telemetry.jsonl` and `review-gate-telemetry.jsonl` are **independent files tracking different concerns**:

| File | Concern | Writer | Consumer |
|---|---|---|---|
| `classifier-telemetry.jsonl` | Classification decisions — what tier and size routing was selected | `review-complexity-classifier.sh` | Future calibration tooling |
| `review-gate-telemetry.jsonl` | Gate enforcement outcomes — whether a commit was allowed or blocked | `pre-commit-review-gate.sh` | Gate audit and compliance tooling |

No shared correlation key is required between the two files. They serve independent consumers with independent retention and analysis needs. A single commit event may produce one record in each file, but the two records are not linked by any identifier — calibration tooling consuming `classifier-telemetry.jsonl` does not need to join against `review-gate-telemetry.jsonl`, and vice versa.

---

## Failure Contract

If the telemetry write fails (permissions error, disk full, `ARTIFACTS_DIR` not set, etc.), the emitter must:

- Silently skip the telemetry write.
- Continue normally — the classification result on stdout and the exit code must be unaffected.

Telemetry write failures must not propagate to the caller or block the commit workflow.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal) require updating both the emitter and this document atomically in the same commit. Additive changes (new optional fields) are backward-compatible and do not require a version bump.
