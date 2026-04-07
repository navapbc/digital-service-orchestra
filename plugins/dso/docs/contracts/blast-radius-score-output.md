# Contract: Blast-Radius Score Output Interface

- Signal Name: blast-radius-score
- Status: accepted
- Scope: complexity-routing (epic 5050-15fd)
- Date: 2026-03-25

## Purpose

This document defines the interface between `blast-radius-score.py` (emitter) and `complexity-evaluator.md` (parser). The emitter computes a cross-stack structural scope score from a list of changed file paths and prints a single JSON object to stdout. The parser (Step 2.5) consumes `complex_override` to determine whether COMPLEX classification is forced, and surfaces `score` and `signals` in its own output schema as `blast_radius_score` and `blast_radius_signals`.

---

## Signal Name

`blast-radius-score`

---

## Emitter

`plugins/dso/scripts/blast-radius-score.py` # shim-exempt: internal implementation path reference

The emitter reads file paths from stdin (one per line), scores each file against known high-impact patterns, path depth, and directory conventions, then prints a single JSON object to stdout and exits 0. It exits non-zero only on unhandled exceptions.

---

## Parser

`plugins/dso/agents/complexity-evaluator.md` (Step 2.5)

The parser pipes the file list discovered in Step 2 into the emitter and reads the JSON from stdout. It uses `complex_override` to apply the blast-radius COMPLEX promotion rule. It exposes `score` and `signals` to callers via the `blast_radius_score` and `blast_radius_signals` fields of its own output schema.

---

## Fields

The emitter outputs a single JSON object on stdout. All fields are required.

| Field | Type | Description |
|---|---|---|
| `score` | integer | Aggregate blast-radius score across all input files. Computed from per-file contributions: path depth (0–3), known pattern weight (1–3), high-impact directory bonus (+1), plus a cross-layer bonus when `layer_count >= 3`. |
| `signals` | array of string | Human-readable list of score contributions. Each entry follows the format `<signal_type>:<detail>(+<weight>)`. Signal types: `known_pattern` (basename matched a high-impact file), `dir_pattern` (path prefixed by a known directory-based pattern), `impact_dir` (a path component matched a high-impact directory), `cross_layer_bonus` (multi-layer spread bonus). Empty when the input file list is empty. |
| `complex_override` | boolean | `true` when `score` exceeds the threshold (default: 5). When `true`, the parser must force COMPLEX classification regardless of all other dimension scores. |
| `layer_count` | integer | Number of distinct top-level directories represented in the input file list. Root-level files each count as a single `<root>` layer. Drives the cross-layer bonus: when `layer_count >= 3`, `(layer_count - 2)` bonus points are added to `score`. |
| `change_type` | string | Heuristic classification of the change set. One of: `additive`, `subtractive`, `substitutive`, `mixed`. Inferred from file name patterns and directory spread; defaults to `mixed` for multi-directory sets when signals are ambiguous. |

### Score Threshold

The default threshold is **5**. `complex_override` is `true` when `score > 5`.

### `change_type` Enum Values

| Value | Meaning |
|---|---|
| `additive` | File names contain additive hints (`new_*`, `*_add*`, `*_create*`) and no subtractive hints |
| `subtractive` | File names contain subtractive hints (`delete_*`, `remove_*`, `*_del_*`, `*_rm_*`) and no additive hints |
| `substitutive` | Single file, or same-directory multi-file set with no config or test signals |
| `mixed` | Multiple top-level directories with config or test files present, or conflicting additive/subtractive hints |

### Canonical parsing prefix

The parser MUST match against:

- `blast-radius-score` — this contract defines a JSON stdout interface, not a line-based signal. The parser reads the full JSON object from the emitter's stdout. No line-prefix matching applies; the parser must deserialize the JSON object and inspect the `complex_override` field.

---

## Example

### Single-file input (below threshold)

Input:
```
src/main.py
```

Output:
```json
{
  "score": 5,
  "signals": ["known_pattern:main.py(+3)"],
  "complex_override": false,
  "layer_count": 1,
  "change_type": "substitutive"
}
```

### Multi-file cross-layer input (above threshold, complex_override true)

Input:
```
src/main.py
app/config.py
tests/test_main.py
.github/workflows/ci.yml
```

Output:
```json
{
  "score": 17,
  "signals": [
    "known_pattern:main.py(+3)",
    "known_pattern:config.py(+2)",
    "dir_pattern:.github/workflows(+3)",
    "cross_layer_bonus:+2"
  ],
  "complex_override": true,
  "layer_count": 4,
  "change_type": "mixed"
}
```

---

## Failure Contract

If the emitter:

- is absent (script file not found),
- exits non-zero,
- times out (exit code 144 from `test-batched.sh` or SIGURG),
- or outputs malformed JSON (not parseable or missing required fields),

then the parser **must** skip Step 2.5 entirely and continue to Step 3 without forcing COMPLEX. Blast radius is a routing heuristic — its absence or failure must never block the complexity evaluation workflow.

When the script is absent or exits non-zero, the parser sets `blast_radius_score: null` and `blast_radius_signals: []` in its own output schema.

---

## Routing Heuristic Note

The `complex_override` field is the **only** field the parser acts on for classification routing. A high numeric `score` with `complex_override=false` is informational only; it does not independently force COMPLEX.

The `change_type` and `layer_count` fields are emitted for diagnostic transparency. Callers may surface them in reasoning text but must not use them as independent routing signals.

---

## Disambiguation: Two Blast-Radius Measures

Two different blast-radius signals exist in this codebase. They measure different quantities and serve different purposes:

| Signal | Emitter | Measures | Used by |
|---|---|---|---|
| `blast-radius-score` (this contract) | `plugins/dso/scripts/blast-radius-score.py` # shim-exempt: internal implementation path | Cross-stack structural scope: how many layers, known high-impact files, and directory conventions are spanned by the changed file set. Input is a list of file paths from the ticket description. | `complexity-evaluator.md` Step 2.5 — to route tickets to COMPLEX when structural spread is high |
| `blast_radius` factor | `plugins/dso/scripts/review-complexity-classifier.sh` # shim-exempt: internal implementation path | Import fan-out: the number of other files that import the changed files, as a proxy for how widely a change propagates through the dependency graph. Input is the staged git diff. | `REVIEW-WORKFLOW.md` Step 3 — to select the review tier (light/standard/deep) |

These two measures are distinct quantities computed from different inputs for different consumers. A high `blast-radius-score` does not imply a high `blast_radius` review factor, and vice versa.

---

## Versioning

This contract is unversioned. Breaking changes (field removal, type changes, enum value removal) require updating both the emitter and this document atomically in the same commit. Additive changes (new optional fields) are backward-compatible and do not require a version bump.
