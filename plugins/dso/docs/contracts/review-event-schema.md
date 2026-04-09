# Contract: Review Event JSONL Schema

- Signal Name: REVIEW_EVENT_SCHEMA
- Status: accepted
- Scope: review observability events (epic cb8a-6a7c)
- Date: 2026-04-05
- schema_version: 1

## Purpose

This document defines the versioned JSONL event schema for review observability events. Each event is a self-contained JSON record appended to an append-only JSONL log file. The schema covers four event types emitted during the review and commit workflow: tier selection, overlay triggers, review results, and commit workflow outcomes.

This contract must be agreed upon before any emitter or consumer is implemented to prevent implicit schema assumptions and ensure all producers and parsers stay in sync.

---

## Signal Name

`REVIEW_EVENT_SCHEMA`

---

## Event Types

All events share a common set of fields and carry per-type payload fields. The `event_type` field discriminates between event types.

| Event Type | Description |
|---|---|
| `review_result` | Emitted after a review completes. Captures tier, dimension scores, finding counts, and severities. |
| `commit_workflow` | Emitted when the commit workflow reaches a terminal state (commit succeeded or was blocked). |
| `tier_selection` | Emitted when the review-complexity classifier selects a tier for a review. |
| `overlay_trigger` | Emitted when a security or performance overlay is triggered (or explicitly not triggered). |

---

## Common Fields

Every event record contains the following fields. All are required.

| Field | Type | Description |
|---|---|---|
| `schema_version` | integer | Schema version number. Currently `1`. Consumers must check this field and handle unknown versions gracefully. |
| `event_type` | string | One of: `review_result`, `commit_workflow`, `tier_selection`, `overlay_trigger`. |
| `timestamp` | string | ISO 8601 timestamp with timezone (e.g., `2026-04-05T14:30:00Z`). Time the event was emitted. |
| `session_id` | string | Opaque identifier for the current session. Used to correlate events within a single review/commit cycle. |
| `epic_id` | string | Ticket ID of the epic being worked on, or empty string if no epic context is available. |

---

## Per-Type Field Definitions

### `review_result`

Emitted after a review cycle completes (by any tier reviewer or overlay agent).

| Field | Type | Required | Description |
|---|---|---|---|
| `tier` | string | required | Review tier that executed: `light`, `standard`, or `deep`. |
| `reviewer_agent` | string | required | Name of the reviewer agent that produced the result (e.g., `dso:code-reviewer-standard`). |
| `finding_count` | integer | required | Total number of findings produced by the reviewer. |
| `critical_count` | integer | required | Number of findings with critical severity. |
| `important_count` | integer | required | Number of findings with important severity. |
| `suggestion_count` | integer | required | Number of findings with suggestion severity. |
| `dimensions_scored` | array of strings | required | List of review dimensions that were scored (e.g., `["correctness", "verification", "hygiene", "design", "maintainability"]`). |
| `pass` | boolean | required | `true` if the review passed (no unresolved critical/important findings); `false` otherwise. |
| `resolution_attempts` | integer | required | Number of autonomous resolution attempts made before final result. `0` if no resolution was needed. |
| `diff_hash` | string | required | Hash of the diff that was reviewed. Used for integrity verification. |

### `commit_workflow`

Emitted when the commit workflow reaches a terminal state.

| Field | Type | Required | Description |
|---|---|---|---|
| `outcome` | string | required | Terminal state: `committed`, `blocked_by_review`, `blocked_by_test_gate`, `blocked_by_format`, `blocked_by_lint`. |
| `review_passed` | boolean | required | Whether the review gate passed for this commit attempt. |
| `test_gate_passed` | boolean | required | Whether the test gate passed for this commit attempt. |
| `files_committed` | integer | optional | Number of files in the commit. Present only when `outcome` is `committed`. |
| `commit_hash` | string | optional | Short hash of the resulting commit. Present only when `outcome` is `committed`. |

### `tier_selection`

Emitted when the review-complexity classifier selects a tier.

| Field | Type | Required | Description |
|---|---|---|---|
| `computed_total` | integer | required | Raw sum of all seven factor scores before floor rules. |
| `selected_tier` | string | required | Final tier after floor rules: `light`, `standard`, or `deep`. |
| `floor_rule_applied` | boolean | required | `true` if a floor rule overrode the threshold-derived tier. |
| `diff_lines` | integer | required | Count of added lines in non-test, non-generated source files. |
| `file_count` | integer | required | Number of staged source files included in the classification. |
| `size_action` | string | required | Size threshold result: `none`, `upgrade`, or `reject`. |

### `overlay_trigger`

Emitted when an overlay review is triggered or explicitly skipped.

| Field | Type | Required | Description |
|---|---|---|---|
| `overlay_type` | string | required | Type of overlay: `security` or `performance`. |
| `triggered` | boolean | required | `true` if the overlay was dispatched; `false` if it was evaluated but not triggered. |
| `trigger_source` | string | required | How the overlay was triggered: `classifier` (classifier flagged it), `reviewer` (tier reviewer flagged it during review), or `skipped` (evaluated but not triggered). |
| `finding_count` | integer | optional | Number of findings from the overlay review. Present only when `triggered` is `true` and the overlay has completed. |

### Canonical parsing prefix

The parser MUST match against:

- `REVIEW_EVENT_SCHEMA` — this contract defines a JSONL append-only log format. Consumers parse the file line-by-line; each line is a complete JSON object. The `event_type` field discriminates between event types (`review_result`, `commit_workflow`, `tier_selection`, `overlay_trigger`). No line-prefix string matching applies — consumers must deserialize each JSON record and inspect `event_type` to route processing.

---

## Security Constraint

**Events contain counts and severities only — no finding text or code snippets.** Review event records must never include the textual content of review findings, code excerpts, file contents, or any other material that could leak sensitive source code or security-relevant details into telemetry logs. The `finding_count`, `critical_count`, `important_count`, and `suggestion_count` fields provide aggregate metrics sufficient for observability without exposing finding details.

This constraint applies to all event types. If a future event type requires richer content, it must be defined in a separate contract with explicit access controls.

---

## Example Records

### `tier_selection` event

```json
{"schema_version":1,"event_type":"tier_selection","timestamp":"2026-04-05T14:30:00Z","session_id":"sess-abc123","epic_id":"cb8a-6a7c","computed_total":5,"selected_tier":"standard","floor_rule_applied":false,"diff_lines":87,"file_count":3,"size_action":"none"}
```

### `review_result` event

```json
{"schema_version":1,"event_type":"review_result","timestamp":"2026-04-05T14:31:00Z","session_id":"sess-abc123","epic_id":"cb8a-6a7c","tier":"standard","reviewer_agent":"dso:code-reviewer-standard","finding_count":2,"critical_count":0,"important_count":1,"suggestion_count":1,"dimensions_scored":["correctness","verification","hygiene","design","maintainability"],"pass":true,"resolution_attempts":1,"diff_hash":"a1b2c3d4"}
```

### `overlay_trigger` event

```json
{"schema_version":1,"event_type":"overlay_trigger","timestamp":"2026-04-05T14:30:05Z","session_id":"sess-abc123","epic_id":"cb8a-6a7c","overlay_type":"security","triggered":true,"trigger_source":"classifier","finding_count":0}
```

### `commit_workflow` event

```json
{"schema_version":1,"event_type":"commit_workflow","timestamp":"2026-04-05T14:32:00Z","session_id":"sess-abc123","epic_id":"cb8a-6a7c","outcome":"committed","review_passed":true,"test_gate_passed":true,"files_committed":3,"commit_hash":"e5f6g7h8"}
```

---

## Forward Compatibility

New fields may be added to any event type in future schema versions. **Consumers must ignore unknown fields.** Parsers that encounter a field not defined in this contract must silently skip it — they must not fail, warn, or discard the record.

When `schema_version` is incremented, the new version's contract will document all changes. Consumers that do not recognize a `schema_version` value should parse best-effort using the highest version they understand, ignoring unknown fields.

Breaking changes (field removal, type changes, enum value removal, semantic changes to existing fields) require incrementing `schema_version`. Additive changes (new optional fields within an existing schema version) do not require a version bump but should be documented in the Change Log.

---

## Failure Contract

If an event cannot be written (permissions error, disk full, `ARTIFACTS_DIR` not set, etc.), the emitter must:

- Silently skip the event write.
- Continue normally — the review or commit workflow must not be affected.

Event write failures must not propagate to the caller or block the review/commit workflow. Telemetry is best-effort; workflow correctness takes priority.

---

## Consumers

The following components emit or consume these events:

| Component | Role | Notes |
|---|---|---|
| Review workflow (REVIEW-WORKFLOW.md) | Emitter | Emits `review_result` and `overlay_trigger` events |
| Commit workflow (COMMIT-WORKFLOW.md) | Emitter | Emits `commit_workflow` events |
| Review-complexity classifier | Emitter | Emits `tier_selection` events |
| Future observability dashboard | Consumer | Planned consumer for aggregation and visualization |

All implementors must read this contract before emitting or parsing review events. Changes to the event schema require updating all conforming emitters and parsers and this document atomically in the same commit.

---

## Versioning

This contract is versioned via the `schema_version` field in each event record. The current version is **1**.

### Change Log

- **2026-04-05**: Initial version (schema_version: 1) — defines four event types (`review_result`, `commit_workflow`, `tier_selection`, `overlay_trigger`), common fields, per-type field definitions, security constraint (counts only, no finding text), and forward compatibility clause.
