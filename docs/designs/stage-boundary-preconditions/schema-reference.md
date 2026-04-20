# Stage-Boundary PRECONDITIONS Schema Reference

## Overview

PRECONDITIONS events are append-only JSON files persisted in the ticket event directory
(`<ticket-dir>/<ts>-<uuid>-PRECONDITIONS.json`). They record upstream stage claims before
each stage boundary so downstream validators can verify assumptions.

Three depth tiers (`manifest_depth`) control schema richness: `minimal`, `standard`, `deep`.
The tier is selected by `dso:complexity-evaluator` based on ticket complexity.

---

## Event File Format

```
<ticket-dir>/<timestamp>-<uuid>-PRECONDITIONS.json
```

- Flat file, no subdirectories — mirrors the `.suggestions` hidden-dir exclusion precedent
- Brainstorm amend mode appends a new event (does not overwrite)
- Latest event per `(stage, session_id, worktree_id)` selected by highest timestamp

---

## Schema Fields

### Core Fields (all tiers)

| Field | Type | Description |
|-------|------|-------------|
| `event_type` | string | Always `"PRECONDITIONS"` |
| `gate_name` | string | Stage identifier: `brainstorm`, `preplanning`, `implementation-plan`, `sprint`, `commit`, `epic-closure` |
| `session_id` | string | Claude session identifier (UUID) |
| `worktree_id` | string | Worktree branch name, or `"main"` for non-worktree sessions |
| `tier` | string | Ticket complexity tier from classifier: `low`, `medium`, `high` |
| `timestamp` | integer | Unix nanoseconds (matches ticket event format) |
| `schema_version` | string | Schema version: `"v2"` |
| `manifest_depth` | string | Depth tier selected: `minimal`, `standard`, or `deep` |
| `data` | object | Depth-specific payload (see below) |

### `data` Field — Minimal Tier

| Field | Type | Description |
|-------|------|-------------|
| `spec_hash` | string | SHA-256 of the upstream spec at write time |
| `gate_verdicts` | object | Composite-keyed pass/fail verdicts (see Gate Verdicts below) |
| `workflow_completion_checklist` | array | `[{item, completed, evidence_ref, validator_verdict}]` |
| `completeness` | object | `{score: 0.0-1.0, method, rationale}` |

### `data` Field — Standard Tier (adds)

| Field | Type | Description |
|-------|------|-------------|
| `decisions_log` | array | `[{decision, rationale, affects_fields}]` |
| `unresolved_questions` | array | Open questions carried into the next stage |
| `execution_context` | object | Runtime info: model, tool versions, branch |
| `committed_diff_hash` | string | SHA-256 of git diff at write time (empty string if no commits yet) |
| `dispatch_profile` | object | Sub-agent dispatch summary: count, tiers, outcomes |

### `data` Field — Deep Tier (adds)

| Field | Type | Description |
|-------|------|-------------|
| `test_contract` | object | `{required_behaviors, coverage_evidence, gap_analysis}` |
| `parser_input_classes` | array | Input classes exercised in tests |
| `red_markers_active` | array | RED test markers currently active in `.test-index` for this ticket |

### Gate Verdicts (composite key)

```json
{
  "gate_verdicts": {
    "<gate_name>:<session_id>:<worktree_id>": {
      "verdict": "pass|fail|skip",
      "reason": "...",
      "checked_at": "<timestamp>"
    }
  }
}
```

Last-write-wins (LWW) on composite key conflict. Read-side resolves by highest timestamp.

### Evidence Reference (`evidence_ref`)

Each `workflow_completion_checklist` entry carries:

```json
{
  "source_type": "user|codebase|inference|default",
  "pointer": "path/to/file or ticket comment ID",
  "rationale": "why this evidence supports the claim"
}
```

- `user`: sourced from an existing ticket comment (no new prompt)
- `codebase`: sourced from a file or test in the repo
- `inference`: structurally accepted when `rationale` is non-empty
- `default`: field defaulted per schema spec

---

## `manifest_depth` Values

| Value | When Selected | Schema Coverage |
|-------|--------------|-----------------|
| `minimal` | Low-complexity tickets; FP auto-fallback active | Core fields only |
| `standard` | Medium-complexity tickets | Core + decisions, context, diff hash |
| `deep` | High-complexity tickets (e.g., epics) | Core + test contract, input classes, RED markers |

---

## `schema_version` Evolution Policy

1. Every PRECONDITIONS event carries `schema_version` (currently `"v2"`).
2. Unknown versions fall back to `minimal` interpretation with a one-time `[DSO WARN]` log.
3. New fields MUST be added to the appropriate tier section and documented in this file.
4. Removing or renaming an existing field requires a `schema_version` bump and a migration note.
5. Field additions within a tier are backward-compatible; field removals are not.

---

## Forward-Compat Contract

Validators MUST accept well-formed events at any unknown `schema_version` by:

1. Reading only the fields they know about (depth-agnostic read)
2. Logging `[DSO WARN] Unknown schema_version=<v>; falling back to minimal interpretation`
3. Proceeding without blocking the workflow

This ensures new event formats do not break validators deployed from older plugin versions.
