# Contract: MIGRATION_CLASS Marker

- Signal Name: MIGRATION_CLASS
- Status: accepted
- Scope: implementation-plan Step 1 (emitter) → task-decomposer story / sprint two-pass-ordering story / E2E fixture story (consumers)
- Date: 2026-06-02

## Purpose

This document is the **normative single source of truth** for the `MIGRATION_CLASS:` ticket-comment marker contract. It defines the marker JSON shape, the emitting site, the classification values, the threshold configuration, the append-only/last-wins idiom, and the `sg`-unavailable degradation path.

All emitters and consumers MUST conform to this document rather than redefining the shape independently.

---

## Marker JSON Shape

The marker is written as a **single-line JSON object** embedded in a ticket comment using the prefix `MIGRATION_CLASS:`.

```
MIGRATION_CLASS: {"migration-class":"sweep","detection_query":"$A($$$B)","threshold_used":3,"target_symbol":"my_old_helper"}
```

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `migration-class` | `string` | yes | Classification result. One of: `sweep`, `db`, `inconclusive`. |
| `detection_query` | `string` | yes | The exact ast-grep pattern string used to count call sites. |
| `threshold_used` | `integer` | yes | The effective threshold value applied during detection (after config lookup and floor enforcement). |
| `target_symbol` | `string` | yes | The symbol whose call sites were counted by the detection query. |

### `migration-class` Values

| Value | Meaning |
|---|---|
| `sweep` | Call site count is **at or above** `threshold_used`; a sweeping migration `automated-sweep` + `manual-verification` task duo is warranted. |
| `db` | Symbol is database-coupled; requires a coordinated three-task DB migration unit (forward-migration + rollback + rollback-verification) regardless of call site count. `db` short-circuits BEFORE the sweep call-site count, so it is single-valued and authoritative — a db symbol emits ONLY the three-task db unit, never an additional sweep duo. |
| `inconclusive` | ast-grep (`sg`) was unavailable; detection could not run. |

### Key Spelling Note

The key `migration-class` is **hyphenated** (not underscored). This is intentional — it mirrors the classification vocabulary used across the DSO skill system. Both the emitter and all consumers MUST use the exact spelling `migration-class` verbatim. A common mistake is to write `migration_class` (with underscore), which will cause silent mismatches in consumers that key on the hyphenated form.

---

## Emitter

**`/dso:implementation-plan` — Step 1 (migration-class detection step)**

Step 1 runs the ast-grep detection query against the target symbol's call sites, reads `migration.call_site_threshold` from config (see [Threshold](#threshold-configuration) below), and appends a ticket comment to the story ticket in the form:

```
MIGRATION_CLASS: {<json-object>}
```

This mirrors the `COMPLEXITY_CLASSIFICATION:` idiom used by the complexity-classifier step: a prefix keyword, a colon, a space, and a single-line JSON payload.

---

## Append-Only / Last-Wins Idiom

Step 1 **appends** a new `MIGRATION_CLASS:` comment each time it runs (re-runs are allowed for re-detection after config changes). It does **not** delete or update previous `MIGRATION_CLASS:` comments.

**Consumers MUST read the LAST matching `MIGRATION_CLASS:` comment** on the story ticket, ignoring any earlier ones. This is consistent with how `COMPLEXITY_CLASSIFICATION:` comments are consumed.

---

## sg-Unavailable Degradation

When the `sg` (ast-grep) binary is not present on `PATH`:

- `migration-class` MUST be set to the explicit string `"inconclusive"` — **never silently false, never omitted**.
- `detection_query` SHOULD be set to the query that would have been run (or an empty string if it cannot be determined).
- `threshold_used` MUST be set to the effective threshold value even though no comparison was performed.
- `target_symbol` MUST be set to the target symbol name.
- The emitter MUST NOT crash or exit non-zero solely because `sg` is absent.

The `inconclusive` value is a first-class classification result. Consumers that need a concrete migration-class decision must prompt the planner to re-run Step 1 after installing `sg`, or accept the `inconclusive` path explicitly.

---

## Threshold Configuration

The detection threshold is read from the DSO config key:

```
migration.call_site_threshold
```

- **Default**: `3` (when the key is absent or empty)
- **Floor**: `1` (minimum accepted value; the helper rejects values below 1 with a non-zero exit and a clear error message — it never silently clamps)
- **Helper**: `get_call_site_threshold()` in `${CLAUDE_PLUGIN_ROOT}/hooks/lib/planning-config.sh`

These exact values (`default=3`, `floor=1`) are the canonical reference. The `get_call_site_threshold()` helper is the single source for threshold resolution; emitters must call it rather than inlining the default.

---

## Consumers

Three consumers read the `MIGRATION_CLASS:` marker:

1. **Task-decomposer story** — an **ACTIVE consumer** for both `sweep` and `db`: on `sweep` it co-authors an `automated-sweep` + `manual-verification` duo; on `db` it co-authors a three-task unit (forward-migration + rollback + rollback-verification co-authored as one unit in the same plan). It does **not** self-fetch the marker (the `dso:task-decomposer` agent is read-only with respect to the tracker and has no tracker access). The marker is delivered to it as the `{migration-marker}` dispatch argument constructed by `implementation-plan` Step 3, which sources the **LAST** `MIGRATION_CLASS:` comment (last-wins) and passes the verbatim JSON payload. The `db` branch classifies the rollback (`safe-revert` for additive changes, `compensating-forward` for destructive ones, ambiguous → `compensating-forward` with a `DATA LOSS RISK` note inferred from the change description, since the marker carries only the literal `db` value), and the rollback-verification task asserts post-rollback schema state. `db` short-circuits before the sweep count, so a `db` marker emits ONLY the three-task db unit (never an additional sweep duo); `flag-tag` is **reserved** to sibling story `c5fa` (an independent, composable axis — not a mutually-exclusive switch). For `inconclusive`: emits no migration tasks and surfaces a `decomposition_notes` entry that detection was unavailable.
2. **Sprint two-pass-ordering story** — reads the marker to determine ordering of migration tasks within the sprint batch. Does **not** recompute the classification; it is a read-only consumer of the last `MIGRATION_CLASS:` comment.
3. **E2E fixture story** — asserts that a `MIGRATION_CLASS:` comment exists on the story ticket after Step 1 runs, and that the JSON payload has the correct shape (all four fields present, `migration-class` is one of the three valid values, `threshold_used` is an integer ≥ 1).

---

## Worked Example

After Step 1 runs for a story targeting `get_legacy_user` with a threshold of `3` and `5` detected call sites:

```
MIGRATION_CLASS: {"migration-class":"sweep","detection_query":"$A.get_legacy_user($$$B)","threshold_used":3,"target_symbol":"get_legacy_user"}
```

If the target symbol is database-coupled, the marker carries the literal `db` value (the marker does NOT carry destructiveness — the task-decomposer infers `safe-revert` vs `compensating-forward` from the change description) and the task-decomposer co-authors the three-task db unit (forward-migration + rollback + rollback-verification):

```
MIGRATION_CLASS: {"migration-class":"db","detection_query":"$A.get_legacy_user($$$B)","threshold_used":3,"target_symbol":"get_legacy_user"}
```

If `sg` is unavailable:

```
MIGRATION_CLASS: {"migration-class":"inconclusive","detection_query":"$A.get_legacy_user($$$B)","threshold_used":3,"target_symbol":"get_legacy_user"}
```

---

## Test Exemption

This task is exempt from automated unit testing under unit exemption criterion 3, cited verbatim: "modifies only static assets (Markdown documentation) — no executable behavior to test". The artifact is a contract Markdown document; it introduces no executable code path and therefore has no deterministically-testable behavior or runtime failure mode.
