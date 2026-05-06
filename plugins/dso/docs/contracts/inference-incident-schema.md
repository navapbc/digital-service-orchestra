# Contract: inference-incident-schema

- Signal Name: inference-incident-schema
- Status: accepted
- Scope: inference incident corpus — JSONL record schema for stored inference incidents
- Date: 2026-05-05

## Purpose

Documents the JSONL record schema used to store inference incidents in the corpus. Each line in the corpus `incidents.jsonl` file is a JSON object conforming to this schema. The schema enables the inference incident curator agent to validate, deduplicate, and query records. This contract must be agreed upon before any emitter or parser is implemented.

## Signal Name

`inference-incident-schema`

---

## Status

accepted

---

## Schema

Each record is a single-line JSON object with the following fields:

| Field | Type | Description |
|-------|------|-------------|
| `ticket_id` | string | The ticket ID associated with the inference incident (e.g., `abcd-1234`) |
| `inferred_decision_text` | string | The full text of the inference decision that was made without sufficient evidence |
| `affects_fields` | enum | The ticket field(s) affected by the inference: `title`, `description`, `acceptance_criteria`, `done_definitions`, or `tags` |
| `outcome` | string | The outcome of the inference incident — what happened as a result of the inference (e.g., `ticket_reopened`, `scope_changed`, `user_corrected`) |
| `source_decision_text` | string | The original text from the source that triggered the inference decision |

### Field constraints

- `ticket_id`: non-empty string; must match the ticket ID format used in the ticket system
- `inferred_decision_text`: non-empty string; must contain the verbatim inference claim
- `affects_fields`: enum value — one of `title`, `description`, `acceptance_criteria`, `done_definitions`, `tags`
- `outcome`: non-empty string; free-text description of what occurred after the inference was made
- `source_decision_text`: non-empty string; the verbatim source text that led to the inference

---

## Format

Records are stored as JSONL (one JSON object per line, no trailing comma, UTF-8 encoded). Each record must be a valid JSON object on a single line.

### Example record

```json
{"ticket_id": "abcd-1234", "inferred_decision_text": "The feature should handle offline mode", "affects_fields": "acceptance_criteria", "outcome": "ticket_reopened", "source_decision_text": "User said 'it should work anywhere'"}
```

### File layout

```
incidents.jsonl  — one record per line, JSONL format
holdout.txt      — reserved lines for evaluation; plain text, one entry per line
```

---

## Emitter

The inference incident curator agent writes records to `incidents.jsonl` when an inference incident is confirmed (either by user correction or automatic detection). Each write appends a new line to the corpus file.

---

## Parser

The inference incident curator agent and corpus validation harness parse records by reading `incidents.jsonl` line by line and JSON-decoding each line. The parser validates that all required fields are present and that `affects_fields` is a valid enum value.

### Canonical parsing prefix

The parser reads the corpus file line by line. Each non-empty line is parsed as a JSON object. Lines beginning with `#` are treated as comments and skipped. Empty lines are skipped. The parser MUST validate the presence of all 5 required fields (`ticket_id`, `inferred_decision_text`, `affects_fields`, `outcome`, `source_decision_text`) and MUST reject records missing any required field.

---

## Consumers

| Component | Role |
|-----------|------|
| Inference incident curator agent | Emitter — appends records to corpus on incident confirmation |
| Corpus validation harness | Parser — validates schema compliance of all records |
| Holdout evaluator | Reader — reads `holdout.txt` for evaluation set management |
