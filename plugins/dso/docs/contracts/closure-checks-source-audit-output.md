# Contract: closure-checks-source-audit-output

- Signal Name: closure-checks-source-audit-output
- Status: accepted
- contract_version: 1
- Scope: source-consumer audit artifact (`audit-closure-checks-source-consumers.sh` → `apply-bucket-recipes.sh`)
- Date: 2026-05-19

## Purpose

This document defines the frozen JSON envelope produced by `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-source-consumers.sh` (T2 of story 7e2c-2f4c-cd95-4e60) and consumed by `${CLAUDE_PLUGIN_ROOT}/scripts/apply-bucket-recipes.sh` (T3). The audit script enumerates every `.md`/`.sh`/`.py`/`.yaml`/`.yml` file under `plugins/`, `tests/`, and `docs/` that references the `## Closure Checks` schema, classifies each match into one of six precedence-ordered buckets, and writes a single JSON artifact per run.

Freezing this schema decouples emitter and consumer: T3 can implement against this contract without reading T2's internals, and any future T2 schema change requires a formal v2 bump documented here (see Versioning Policy) rather than a silent break.

---

## Signal Name

`closure-checks-source-audit-output` — a per-run JSON artifact written to:

```text
<target>/<plugin-git-path>/.audit-output/closure-checks-migration-<UTC-timestamp>-<nano-or-pid>.json
```

where `<plugin-git-path>` is the repo-relative path to this plugin (resolved at runtime — `${CLAUDE_PLUGIN_ROOT#"$REPO_ROOT"/}` — never embedded as a literal in source). The filename's timestamp + nano-suffix combination guarantees uniqueness even for back-to-back invocations.

---

## Emitter

`${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-source-consumers.sh` — runs the file enumeration, pattern sweep, six-bucket classification, and reconciliation loop (max 5 iterations). Writes exactly one JSON envelope per invocation to the path above. Exit codes:

- `0` — Audit complete, reconciliation converged.
- `1` — Audit complete, reconciliation did not converge within 5 iterations (`reconciliation_status = "incomplete"`).
- `2` — Runtime error (no target, target not a directory, etc.).

---

## Parser

`${CLAUDE_PLUGIN_ROOT}/scripts/apply-bucket-recipes.sh` (T3) — reads the most-recent envelope from `.audit-output/`, dispatches the per-bucket recipe handler for each populated bucket array, and updates source files accordingly. Parsers MUST check `schema_version` before relying on field semantics.

Secondary parsers — any audit visualizer, dashboard renderer, or future bucket-recipe migration script — MUST also gate on `schema_version`.

---

### Canonical parsing prefix

The artifact is identified by **file extension + envelope shape**, not a stdout marker prefix. Parsers MUST:

1. Verify the file resides under `<target>/<plugin-git-path>/.audit-output/` and matches the filename pattern `closure-checks-migration-*.json`.
2. Parse the file as JSON; non-parseable contents MUST be treated as a hard error (not silently skipped).
3. Verify the top-level object contains the field `schema_version` and that its value is a string starting with `"1."`. If the major version differs, the parser MUST refuse to consume the file and surface a "schema mismatch" error rather than degrading silently.
4. Verify every required envelope field (see Output Schema below) is present with the documented type. Missing required fields are a hard error.

Stdout from the audit script (newline-separated file paths plus optional `RECONCILIATION_INCOMPLETE` block) is a human-readable convenience only — it is NOT part of this contract and parsers MUST NOT depend on it.

---

## Output Schema

### Top-level envelope

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | string | Yes | Exactly `"1.0"` at this contract version. Parsers MUST gate on the major version (the substring before the first `.`). |
| `audit_run_id` | string | Yes | RFC-4122 UUID (string form, lowercase, hyphenated) identifying this audit run. Stable for the lifetime of one envelope; never reused across runs. |
| `started_at` | string | Yes | ISO-8601 timestamp (UTC, with timezone offset, sub-second precision) marking the start of the reconciliation loop. |
| `completed_at` | string | Yes | ISO-8601 timestamp (UTC, with timezone offset, sub-second precision) marking when the envelope was finalized. Always `>= started_at`. |
| `file_count_scanned` | integer | Yes | Count of in-scope files present at the end of the FINAL reconciliation pass. This is the post-reconciliation file count, NOT a cumulative sum across passes. |
| `buckets` | object | Yes | Map of bucket name → array of bucket items. All six bucket keys are ALWAYS present, even when empty (`[]`). See "Buckets" below. |
| `dynamic_load_count` | integer | Yes | Total count of items (across all buckets AND unbucketed matches) where `dynamic_load == true`. A summary tally that consumers can use for fast triage without re-scanning. |
| `unbucketed_matches` | array of objects | Yes | Matches that did not satisfy any bucket's precedence rules. Array is `[]` when none. See "Unbucketed match item" below. |
| `removed_files` | array of strings | Yes | Repo-relative paths of files that existed at the start of a reconciliation pass but were gone by the next pass (i.e., deleted between passes). Array is `[]` when none. |
| `reconciliation_status` | string (enum) | Yes | Either `"complete"` (loop converged within 5 iterations) or `"incomplete"` (loop hit the 5-iteration cap without converging). |
| `reconciliation_iterations` | integer | Yes | Number of passes the reconciliation loop actually executed. Range: `1..5`. |

### Buckets

`buckets` is a map keyed by bucket name. All six keys are ALWAYS present, even when the bucket's array is empty:

| Bucket key | Precedence | Definition |
|---|---|---|
| `migration-in-progress` | 1 (highest) | File-level marker: filename contains `migrate` (case-insensitive) OR file contents match `MIGRATION-IN-PROGRESS` / `MIGRATION_IN_PROGRESS`. Matches in such files are quarantined here regardless of other signals. |
| `test-asserting-on-structure` | 2 | Match line resides under `tests/` AND contains an assertion-style token (`assert*`, `grep`, `expect`, `self.assert*`, `check`, `shouldBe`, `toEqual`, `toContain`). |
| `semantic-consumer` | 3 | Match line contains a parser/generator/walker token (e.g., `re.search`, `parses`, `extracts`, `generate`, `walks`, `scans`, `tokenize`, `items from`, `section content`, `render`). |
| `user-facing-copy` | 4 | Match line is inside an explicit user-facing output call (`print`, `echo`, `printf`, `logger.*`, `logging.*`, `sys.stdout/stderr.write`, `console.log/info/warn/error`, `raise`) OR is a non-heading markdown line with explicit user-prose markers (e.g., `Error:`, `Warning:`, `Note:`, `please <verb>`, `you must`). |
| `section-name-reference` | 5 | Match is a literal `## Closure Checks` heading line (`match_kind == "section"` and the line begins with `##`). |
| `file-path-reference` | 6 (lowest) | Match references a known schema-consumer filename (e.g., `migrate-closure-checks.sh`, `coherence-walk.sh`, `end-state-item-validator.md`, `apply-bucket-recipes.sh`) or its `known-file-mention` kind fires. |

Precedence is exclusive: each match is assigned to the highest-precedence bucket whose predicate fires. A match that satisfies no predicate flows into `unbucketed_matches`.

### Bucket item

Each element of a bucket's array is an object with these fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `file` | string | Yes | Repo-relative path to the source file containing the match. |
| `line` | integer | Yes | 1-based line number of the match within `file`. |
| `match_text` | string | Yes | The substring of the source line that triggered the match (e.g., `"## Closure Checks"`, `"closure-chk"`, an import path, or a source path). |
| `dynamic_load` | boolean | Yes | `true` when the match involves a dynamic load (e.g., `importlib.import_module(<non-literal>)` or a shell `source` path with ≥ 2 `$VAR` segments); `false` for static / non-load matches. |

### Unbucketed match item

Each element of `unbucketed_matches` is an object with these fields:

| Field | Type | Required | Description |
|---|---|---|---|
| `file` | string | Yes | Repo-relative path to the source file containing the match. |
| `line` | integer | Yes | 1-based line number of the match within `file`. |
| `match_text` | string | Yes | The substring of the source line that triggered the match. |
| `reason` | string | Yes | Why the match did not enter any bucket. At schema_version 1.0 the only emitted value is `"no-bucket-matched"`; consumers SHOULD treat the field as an open enum and fall back to "unknown reason" on unfamiliar values. |
| `dynamic_load` | boolean | Yes | Same semantics as the bucket-item `dynamic_load` field. Present so the global `dynamic_load_count` is reconstructable from envelope contents alone. |

---

## Worked Example

A representative payload showing every field populated. (In the example below `<host-plugin>` is a placeholder for the actual plugin git-path the host project uses — e.g., `plugins/<name-of-this-plugin>`. The audit script emits the resolved, repo-relative path, not the placeholder.)

```json
{
  "schema_version": "1.0",
  "audit_run_id": "5892b53d-c8bc-49d1-90b9-91cf4a34a6e0",
  "started_at": "2026-05-20T01:33:29.181482+00:00",
  "completed_at": "2026-05-20T01:33:29.182326+00:00",
  "file_count_scanned": 184,
  "buckets": {
    "migration-in-progress": [
      {
        "file": "plugins/<host-plugin>/scripts/migrate-closure-checks.sh",
        "line": 12,
        "match_text": "## Closure Checks",
        "dynamic_load": false
      }
    ],
    "test-asserting-on-structure": [
      {
        "file": "tests/scripts/test-coherence-walk.sh",
        "line": 88,
        "match_text": "## Closure Checks",
        "dynamic_load": false
      }
    ],
    "semantic-consumer": [
      {
        "file": "plugins/<host-plugin>/scripts/coherence-walk.sh",
        "line": 142,
        "match_text": "## Closure Checks",
        "dynamic_load": false
      }
    ],
    "user-facing-copy": [
      {
        "file": "plugins/<host-plugin>/agents/completion-verifier.md",
        "line": 57,
        "match_text": "Closure Checks",
        "dynamic_load": false
      }
    ],
    "section-name-reference": [
      {
        "file": "plugins/<host-plugin>/docs/contracts/end-state-item-validator.md",
        "line": 89,
        "match_text": "## Closure Checks",
        "dynamic_load": false
      }
    ],
    "file-path-reference": [
      {
        "file": "docs/orphan-task-convention.md",
        "line": 33,
        "match_text": "migrate-closure-checks.sh",
        "dynamic_load": false
      }
    ]
  },
  "dynamic_load_count": 2,
  "unbucketed_matches": [
    {
      "file": "plugins/foo/b.py",
      "line": 1,
      "match_text": "closure_checks",
      "reason": "no-bucket-matched",
      "dynamic_load": false
    },
    {
      "file": "plugins/foo/dyn.py",
      "line": 5,
      "match_text": "importlib.import_module(name)",
      "reason": "no-bucket-matched",
      "dynamic_load": true
    }
  ],
  "removed_files": [
    "plugins/old/stale-reference.md"
  ],
  "reconciliation_status": "complete",
  "reconciliation_iterations": 2
}
```

Notes on the example:

- `dynamic_load_count == 2` reflects one dynamic match in some bucket (e.g., a shell `source "$ROOT/$LIB"` line classified into `semantic-consumer`) plus the one `unbucketed_matches` entry with `dynamic_load: true`. Consumers can recompute this tally by walking buckets + unbucketed and summing items with `dynamic_load == true`.
- All six bucket keys are present even when a bucket array would otherwise be `[]`. T3 MUST tolerate empty bucket arrays without failing.

---

## Versioning Policy

### contract_version 1 (current)

`schema_version` value: `"1.0"`. This is the initial, frozen schema produced by T2 and consumed by T3.

### Compatibility rules

- **Additive minor changes** (e.g., a new OPTIONAL field with a default) MAY bump `schema_version` to `"1.1"`, `"1.2"`, etc. Parsers SHOULD ignore unknown fields and continue parsing.
- **Breaking changes** — removing a field, changing a field's type, changing the precedence semantics, adding a required field, or changing the bucket key set — MUST bump to `schema_version: "2.0"` and require a new contract document (`closure-checks-source-audit-output-v2.md`) with a documented migration plan.
- **RETIRE policy for v1**: `schema_version` major version 1 may only be retired via a formal v2 migration with a documented migration plan. v1 persists for backward compatibility until all consumers (`apply-bucket-recipes.sh` plus any future readers) have migrated. The RETIRE owner MUST document the migration path in the v2 contract before decommissioning v1.

### Consumer obligations

All parsers MUST:

1. Check `schema_version` is present and a string.
2. Refuse to consume the envelope if the major version differs from the version they were written against — never best-effort parse a future major version.
3. Surface `schema_version` in any error messages relating to schema problems so debugging is unambiguous.

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `${CLAUDE_PLUGIN_ROOT}/scripts/audit-closure-checks-source-consumers.sh` | Emitter | Writes exactly one envelope per invocation; never amends an existing file. |
| `${CLAUDE_PLUGIN_ROOT}/scripts/apply-bucket-recipes.sh` | Parser (T3) | Reads the most-recent envelope from `.audit-output/`; dispatches per-bucket recipes; gates on `schema_version` major version. |
| Future audit visualizers / dashboards | Parser | Same gating obligations. |

---

## Change Log

- **2026-05-19**: Initial version — defines the JSON envelope produced by `audit-closure-checks-source-consumers.sh`, the six-bucket classification, the `unbucketed_matches` shape (including `dynamic_load`), the reconciliation status enum, and the v1→v2 retirement policy. Frozen at `schema_version: "1.0"` per T2.5 GREEN contract freeze.
