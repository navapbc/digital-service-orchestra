# Contract: FIGMA_MERGE_OUTPUT Signal

- Signal Name: FIGMA_MERGE_OUTPUT
- Status: accepted
- Scope: figma-merge.py → figma-resync.py (story 5250-e85b, epic 6863-7b38)
- Date: 2026-04-10

## Purpose

This document defines the stdout JSON output contract for the `figma-merge.py` CLI script. The script emits a `FIGMA_MERGE_OUTPUT` JSON payload on both success and error. The `figma-resync.py` orchestrator consumes this output to populate the change summary, user confirmation prompt, and sync metadata ticket comment.

This contract must be agreed upon before implementation to prevent implicit assumptions and keep the emitter and parser in sync.

---

## Signal Name

`FIGMA_MERGE_OUTPUT`

---

## Emitter

`figma-merge.py` (script in the `scripts/` directory under the plugin root directory) — emitted to **stdout** on both success and error, immediately after all artifact files are written (or on the first error before files are written).

---

## Parser

`figma-resync.py` (script in the `scripts/` directory under the plugin root directory) — reads stdout from the `figma-merge.py` subprocess invocation to populate the change summary, metadata comment, and user confirmation prompt.

---

### Canonical parsing prefix

The parser MUST match against:

```json
{"status": "success", ...}
```

or

```json
{"status": "error", ...}
```

The JSON object is emitted as a single line to stdout. The parser reads the subprocess stdout and parses it with `json.loads()`.

---

## Fields

JSON object (single line) to stdout:

| Field | Type | Description |
|-------|------|-------------|
| `status` | `"success" \| "error"` | Required. Outcome of the merge operation. |
| `components_added` | integer | Count of components new in Figma not present in the original manifest (designer-added). |
| `components_modified` | integer | Count of components updated (spatial_hint, fills, strokes, text, or props changed). |
| `components_removed` | integer | Count of components removed from Figma (a warning is emitted for each that had COMPLETE behavioral specs). |
| `behavioral_specs_preserved` | integer | Count of components with `behavioral_spec_status=COMPLETE` that were matched and preserved unchanged. |
| `warnings` | array of strings | Non-fatal issues, e.g. `"component 'comp-footer' removed from Figma but had behavioral_spec_status=COMPLETE"`. Empty array on no warnings. |
| `error_message` | string | Present only when `status="error"`. Human-readable description of the failure. |

## Schema

```json
{
  "status": "success",
  "components_added": 0,
  "components_modified": 0,
  "components_removed": 0,
  "behavioral_specs_preserved": 0,
  "warnings": []
}
```

Error variant:

```json
{
  "status": "error",
  "components_added": 0,
  "components_modified": 0,
  "components_removed": 0,
  "behavioral_specs_preserved": 0,
  "warnings": [],
  "error_message": "Input ID-linkage violation detected — see stderr for details"
}
```

## Example

Successful merge with designer-added and removed components:

```json
{
  "status": "success",
  "components_added": 1,
  "components_modified": 3,
  "components_removed": 1,
  "behavioral_specs_preserved": 4,
  "warnings": [
    "component 'comp-footer' removed from Figma but had behavioral_spec_status=COMPLETE — behavioral specifications may be lost"
  ]
}
```

## Notes

- `components_modified` counts components where at least one visual field (spatial_hint, fills, strokes, text) changed relative to the original manifest.
- When `status="error"`, all integer fields are 0 and `warnings` is empty.
- Emitted to **stdout only**. Diagnostic messages go to **stderr**.
