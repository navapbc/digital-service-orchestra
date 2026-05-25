# Contract: ui-reference-corpus-schema

## Purpose

This document defines the authoritative field semantics for the DSO UI/UX reference corpus
(`data/ui-reference/` within the plugin). The schema is enforced by `check-corpus-schema.py`
against `_schema.yaml`.

## Fields

### Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the corpus entry |
| `title` | string | Human-readable title |
| `domain` | string | Domain tag (must be in `tag_vocabulary.domain`) |

### Optional Fields

| Field | Type | Description |
|-------|------|-------------|
| `source` | string | Attribution source for the entry |
| `summary` | string | Short summary of the entry |
| `detail` | string | Detailed description |
| `rule_id` | string | Reference to a rule ID in an external system |
| `prior_art` | string | Link to prior art or reference material |
| `precedence` | integer | Ordering/priority precedence value |
| `hard_constraint` | boolean | Immutability flag (see semantic below) |

### `hard_constraint` Immutability Semantic

**Verbatim semantic**: hard_constraint=true means the entry governs errors/validation/legal disclosures; any rule_ids citation referencing such an entry makes the owning item immutable to coordination-pass mutation.

When `hard_constraint` is `false` or absent, the entry may be adjusted by coordination
passes (e.g., style harmonization, copy optimization). When `hard_constraint` is `true`,
the entry is locked: no coordination pass may alter the owning item's meaning, phrasing,
or associated rule references.

## Domain Values

The `domain` field must be one of the values declared in `_schema.yaml`
under `tag_vocabulary.domain`. As of this contract version, valid domains include:

- `gov-benefit-flows` — government benefit application flows
- `accessibility` — accessibility patterns and requirements
- `patterns` — reusable design patterns
- `anti-patterns` — patterns to avoid
- `principles` — design principles
- `components` — UI component specifications
- `gov-copy` — government copy and content guidelines
- `auth` — authentication and authorization patterns
- `forms` — form design and validation
- `navigation` — navigation patterns
- `visual` — visual design tokens and guidelines
- `canon` — canonical, authoritative rules (may carry `hard_constraint`)

## Skip Files

The following files in the corpus directory tree are skipped by both
`check-corpus-schema.py` and `ref-query.py` (not validated as corpus entries
and not indexed for BM25 retrieval):

- `_schema.yaml` — vocabulary schema definition
- `_schema-anti-patterns.yaml` — anti-pattern schema definition
- `_index.yaml` — corpus index
- `_overview.yaml` — per-namespace human-readable overview files

## Maintenance

When adding new fields or domain values, update both `_schema.yaml` and this
contract document. The `check-corpus-schema.sh` pre-commit hook enforces
`_schema.yaml` vocabulary constraints on every commit touching corpus files.
