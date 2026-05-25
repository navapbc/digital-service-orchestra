# Contract: ref-query-json-output

**Version**: 1.0  
**Source**: `${CLAUDE_PLUGIN_ROOT}/scripts/ref-query.py` (`--format=json`)  
**Produced by**: task fcc0-6650-eedf-4f98 (story cce1-bfd8-a134-4f18)

## Purpose

This document defines the JSON output schema produced by `ref-query.sh` / `ref-query.py`
when invoked with `--format=json`. Downstream consumers (e.g. the gov-copy-writer agent)
parse this schema to retrieve domain-scoped corpus entries with relevance scores.

## Overview

When invoked with `--format=json`, `ref-query.sh` / `ref-query.py` emits a JSON
array of result objects to stdout instead of the default human-readable YAML-like
text format.  Each element represents one matched corpus entry.

## Schema

```json
[
  {
    "rule_id":    "<string>",
    "tags":       { "domain": "<string|array>", ... },
    "score":      <number>,
    "body":       "<string>",
    "source_file":"<string>"
  }
]
```

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `rule_id` | string | yes | Corpus entry `id` value. Unique within the corpus. |
| `tags` | object | yes | Tag metadata dict. Always contains `domain` key. May also include `component`, `compliance`, `action`, `keywords`, `tags` when present in the source entry. |
| `score` | number | yes | BM25 relevance score (float, rounded to 4 decimal places). Higher is more relevant. Always > 0 in returned results. |
| `body` | string | yes | Primary human-readable content. Taken from `summary` > `description` > `detail` > `title` in priority order. |
| `source_file` | string | yes | Filesystem path to the YAML file containing this entry. Absolute path on the local filesystem. |

### `tags` object

The `tags` object carries structured tag metadata from the corpus entry:

| Key | Type | Description |
|---|---|---|
| `domain` | string or array | Domain namespace(s) of this entry (e.g. `"canon"`, `["components"]`). |
| `component` | string or array | Component tag(s), when present. |
| `compliance` | array | Compliance standards, when present. |
| `action` | array | Action tags, when present. |
| `keywords` | array | Keyword tags, when present. |

## Example

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ref-query.sh" --namespace=canon --format=json "error message required field"
```

```json
[
  {
    "rule_id": "govuk-errors-forms",
    "tags": {
      "domain": "canon",
      "component": ["form", "input", "feedback"],
      "compliance": ["WCAG-2.1-AA", "WCAG-3.3", "plain-language"],
      "action": ["design", "apply", "verify"]
    },
    "score": 3.2941,
    "body": "GOV.UK error patterns: use an error summary at the top of the page...",
    "source_file": "/path/to/data/ui-reference/canon/govuk-errors-forms.yaml"
  }
]
```

## Stability

- `rule_id`, `tags`, `score`, `body`, `source_file` are stable fields guaranteed by this contract.
- Additional fields may be added in future versions; consumers must ignore unknown fields.
- The `tags` object may contain additional keys beyond those listed above.
- Score values are not comparable across different queries or corpus versions.

## Backward Compatibility

Without `--format=json`, `ref-query.sh` continues to emit the original
human-readable YAML-like text format (unchanged behaviour).

Without `--namespace`, results span all corpus domains regardless of format.
