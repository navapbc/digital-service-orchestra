# Contract: gov-copy-artifact

- Status: accepted
- Scope: gov-copy-writer agent → deterministic post-processor → coordination-pass → dogfood harness
- Date: 2026-05-24

## Purpose

This document defines the YAML schema for the **gov-copy artifact** — the structured output produced by the `dso:gov-copy-writer` agent after it generates copy for a government digital service form or UI. All downstream consumers (deterministic post-processor, coordination-pass, dogfood harness) bind to this schema; without it they cannot interoperate.

The `checks` block is computed by **deterministic post-processing** after the LLM produces `values` and `rationale`. The LLM does not self-attest checks values.

Validator: `${CLAUDE_PLUGIN_ROOT}/scripts/check-gov-copy-artifact.sh`

---

## Top-level Structure

```yaml
schema_version: 1          # integer; reserved for breaking-change versioning
items:                     # list of copy items (may be empty)
  - ...
```

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | integer | yes | Schema version number. Currently `1`. Increment on breaking changes to field names, types, or required/optional status. |
| `items` | list | yes | Array of copy item objects. An empty list `[]` is valid (represents an artifact with no items yet). |

---

## Per-item Structure

Each entry in `items` must be a mapping with the following fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `id` | string | yes | Stable identifier for this copy item within the artifact (e.g., `"field-program-name"`). Must be unique within the artifact. |
| `values` | mapping | yes | The copy strings for this item. See [values block](#values-block). |
| `rationale` | mapping | yes | Provenance and rule linkage for the copy. See [rationale block](#rationale-block). |
| `checks` | mapping | yes | Deterministic quality metrics computed by the post-processor. See [checks block](#checks-block). |

---

## values Block

The `values` block contains the copy strings surfaced to the end user.

| Field | Type | Required | Description |
|---|---|---|---|
| `label` | string | yes | The visible field label (e.g., `"Program Name"`). |
| `hint` | string | yes | Helper text shown below or near the label (e.g., `"Enter the full program name."`). |
| `errors` | mapping | yes | A mapping of error key → error message string. Keys are free-form (e.g., `required`, `max_length`, `invalid_format`). An empty mapping `{}` is valid when no error messages are defined yet. |

---

## rationale Block

The `rationale` block captures provenance and linkage to plain-language or accessibility rules.

| Field | Type | Required | Description |
|---|---|---|---|
| `rule_ids` | list of string | yes | IDs of plain-language, accessibility, or agency rules that governed the copy (e.g., `"PLAIN-LANGUAGE-ACT-2010"`, `"OMB-M-17-06"`). An empty list `[]` is valid. |
| `conflicts` | list of string | yes | Human-readable descriptions of style or rule conflicts that were resolved during copy authoring. An empty list `[]` is valid. |
| `deviations` | list of mapping | yes | Documented deviations from a rule. Each deviation entry must include `rule_id` (string) and `reason` (string). An empty list `[]` is valid. |

### deviations entry

| Field | Type | Required | Description |
|---|---|---|---|
| `rule_id` | string | yes | The rule being deviated from. |
| `reason` | string | yes | Explanation for why the deviation is justified. |

---

## checks Block

The `checks` block is populated by the **deterministic post-processor** — not by the LLM author. These fields must never be self-attested by the LLM that wrote the copy.

| Field | Type | Required | Description |
|---|---|---|---|
| `fk_grade` | integer | yes | Flesch-Kincaid grade level computed from the `label` and `hint` text. Lower is more readable. |
| `banned_words_found` | list of string | yes | List of banned or discouraged words detected in `label` and `hint`. An empty list `[]` means none were found. |
| `active_voice` | boolean | yes | `true` if the copy passes active-voice heuristics; `false` otherwise. |
| `source` | string | yes | Identifier of the system that computed this checks block. Must be `"deterministic-post-processor"` for post-processor output. |

---

## Examples

### Passing Example

A conforming artifact with two items:

```yaml
schema_version: 1
items:
  - id: "field-program-name"
    values:
      label: "Program Name"
      hint: "Enter the full name of the program as it appears in the authorization."
      errors:
        required: "Program name is required."
        max_length: "Program name must be 100 characters or fewer."
    rationale:
      rule_ids:
        - "PLAIN-LANGUAGE-ACT-2010"
        - "OMB-M-17-06"
      conflicts: []
      deviations: []
    checks:
      fk_grade: 8
      banned_words_found: []
      active_voice: true
      source: "deterministic-post-processor"
  - id: "field-benefit-amount"
    values:
      label: "Monthly Benefit Amount"
      hint: "The dollar amount you receive each month from this program."
      errors:
        required: "Benefit amount is required."
        invalid_format: "Enter a number, like 500 or 1200.50."
    rationale:
      rule_ids:
        - "PLAIN-LANGUAGE-ACT-2010"
      conflicts:
        - "Internal style guide: prefer 'amount' over 'benefit amount' — overridden by program terminology requirement."
      deviations:
        - rule_id: "OMB-M-17-06"
          reason: "Dollar amounts are formatted per agency financial guidelines, not plain-language number style."
    checks:
      fk_grade: 7
      banned_words_found: []
      active_voice: true
      source: "deterministic-post-processor"
```

A minimal valid artifact with no items:

```yaml
schema_version: 1
items: []
```

### Failing Examples

**Missing `rationale` block** — rejection reason: `items[0]: missing required field 'rationale'.`

```yaml
schema_version: 1
items:
  - id: "field-program-name"
    values:
      label: "Program Name"
      hint: "Enter the full program name."
      errors:
        required: "Program name is required."
    checks:
      fk_grade: 8
      banned_words_found: []
      active_voice: true
      source: "deterministic-post-processor"
```

**Wrong type for `items`** — rejection reason: `'items' must be a list, got str.`

```yaml
schema_version: 1
items: "this should be a list, not a string"
```

**Missing `schema_version`** — rejection reason: `Missing top-level field: 'schema_version'.`

```yaml
items:
  - id: "field-name"
    values:
      label: "Name"
      hint: "Enter your name."
      errors: {}
    rationale:
      rule_ids: []
      conflicts: []
      deviations: []
    checks:
      fk_grade: 5
      banned_words_found: []
      active_voice: true
      source: "deterministic-post-processor"
```

---

## Versioning

This contract is versioned via `schema_version`. Breaking changes (field renames, type changes, required→optional promotions, enum additions) increment `schema_version`. Additive optional fields are backward-compatible and do not increment `schema_version`.

### Change Log

- **2026-05-24**: Initial version — defines gov-copy artifact schema for items, values, rationale, and checks blocks with full field definitions, type constraints, and passing/failing examples.

---

## Consumers

| Consumer | Role |
|---|---|
| `dso:gov-copy-writer` agent | Emitter: produces `id`, `values`, `rationale` per item |
| Deterministic post-processor | Emitter: computes and writes `checks` block |
| Coordination-pass | Consumer: reads full artifact, validates before handoff |
| Dogfood harness | Consumer: validates artifact conformance during testing |
| `check-gov-copy-artifact.sh` | Validator: exits 0 on conforming artifact, non-zero on violations |
