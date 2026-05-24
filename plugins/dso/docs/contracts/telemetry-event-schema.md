# Contract: Telemetry Event Schema

- Signal Name: TELEMETRY_EVENT_SCHEMA
- Status: accepted
- Scope: telemetry-emit.sh, Lambda handler, downstream consumers
- Date: 2026-05-22
- schema_version: 1

## Purpose

This document is the **canonical source of truth** for the telemetry event schema at `schema_version=1`. It defines every field emitted by `telemetry-emit.sh` and consumed by the central Lambda handler and any other downstream consumer.

**Audience**: Authors of telemetry emitters (including `telemetry-emit.sh`) and consumer authors (including the Lambda handler). Any code that produces or parses a `schema_version=1` telemetry event MUST comply with this document. All schema changes must be reflected here before implementation.

---

## Schema Version Policy

`schema_version=1` is load-bearing. The version integer appears as a numeric `1` (not a string) in every emitted event. Consumers MUST check `schema_version` and handle unknown versions gracefully.

**Version-bump policy**:

- Any **field removal**, **type change**, or **semantic change** to an existing field requires incrementing `schema_version` to a new value. All emitters and consumers must be updated atomically with the version bump.
- **Additive optional fields** (new fields added without removing or modifying existing ones) do NOT require a version bump. They must be documented here and consumers must ignore unknown fields.

When `schema_version` is incremented, a new contract document (or a new versioned section in this document) must be created before any emitter ships the new version.

---

## Common Fields

Every telemetry event, regardless of type, contains the following 11 fields. Fields marked **required** must be present on every event. Fields marked **optional** may be absent (omit the key, do not emit `null`) when the value is not available.

| Field | Type | Required/Optional | Format | Semantics |
|---|---|---|---|---|
| `schema_version` | integer | required | Numeric integer; currently `1` | Schema version this event conforms to; consumers gate on this value before parsing per-type fields. |
| `event_id` | string | required | UUID v4 (`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`) | Globally unique identifier for this event; used for deduplication at the Lambda handler. |
| `event_type` | string | required | One of five canonical values (see Event Types) | Discriminates between event types; consumers route on this field. |
| `client_id` | string | required | Opaque string; typically a UUID or repo-scoped hash | Identifies the client installation emitting the event; used for per-client aggregation. |
| `tool_id` | string | required | Kebab-case identifier (e.g., `dso`) | Identifies the DSO tool or plugin emitting the event. |
| `tool_version` | string | required | Semver string (e.g., `1.17.11`) | Version of the tool at emit time; enables per-version drift analysis. |
| `timestamp` | string | required | ISO 8601 with UTC offset (e.g., `2026-05-22T14:30:00Z`) | Wall-clock time the event was emitted. |
| `pr_number` | integer | optional | Positive integer; omit when not in a PR context | GitHub pull-request number associated with this event, if applicable. |
| `commit_sha` | string | optional | Full 40-character hex SHA-1; omit when not available | Git commit SHA associated with this event, if applicable. |
| `cycle` | integer | optional | Positive integer ≥ 1; omit on first cycle events | Review cycle number; 1 = first review, 2 = first re-review, etc. |
| `language` | string | optional | IETF BCP 47 language tag (e.g., `en`) or file-extension language identifier (e.g., `python`) | Primary language context of the event; used for language-specific aggregation. |

---

## Event Types

Five event types are defined for `schema_version=1`. Each event includes all 11 common fields and the per-type fields documented in its subsection below.

### review_finding

Emitted once per finding produced by a code-reviewer agent. Captures a single reviewer finding, its severity, category, and the source rule (if any).

**Per-type fields**:

| Field | Type | Required/Optional | Default | Semantics |
|---|---|---|---|---|
| `finding_id` | string | required | — | Stable identifier for this finding within the review cycle. Format: `f-<hex8>` (e.g., `f-a1b2c3d4`). |
| `severity` | string | required | — | Finding severity. One of: `critical`, `important`, `minor`, `suggestion`. |
| `category` | string | required | — | Review dimension. One of: `correctness`, `design`, `hygiene`, `maintainability`, `verification`. |
| `description` | string | required | — | One-sentence description of the finding. |
| `file` | string | required | — | Repo-relative path to the file cited by this finding. |
| `cited_lines` | array of string | required | — | List of `<path>:<line>` references supporting the finding. |
| `cited_excerpt` | string | optional | absent | Verbatim code excerpt from the cited file. Present only when `telemetry.emit_excerpts=true` (see Privacy Disclosure). |
| `rule_id` | string | optional | absent | Stable rule identifier for cross-tool attribution. When present, format follows the namespaced identifier convention defined in `${CLAUDE_PLUGIN_ROOT}/docs/workflows/prompts/reviewer-base.md` (e.g., `hygiene-pyupgrade-needs-iso`). Absent when no named rule applies. |
| `relation` | string | optional | `NEW_INTRODUCED` | Finding relation to prior cycle (see `review-findings-schema.md`). One of: `NEW_INTRODUCED`, `NEW_PRE_EXISTING`, `RESUSTAIN_OF`, `REFRAME_OF`. Absent on first-cycle events. |

**Worked example**:

```json
{
  "schema_version": 1,
  "event_id": "a1b2c3d4-e5f6-4789-abcd-ef0123456789",
  "event_type": "review_finding",
  "client_id": "c8f2e1a0-4b3d-4c9e-8f1a-2b3c4d5e6f70",
  "tool_id": "dso",
  "tool_version": "1.17.11",
  "timestamp": "2026-05-22T14:30:00Z",
  "pr_number": 279,
  "commit_sha": "69b5b59240abc123def456abc123def456abc123",
  "cycle": 1,
  "language": "python",
  "finding_id": "f-a1b2c3d4",
  "severity": "important",
  "category": "correctness",
  "description": "Off-by-one in loop bounds at line 42 allows out-of-range index access.",
  "file": "src/processor.py",
  "cited_lines": ["src/processor.py:42"],
  "rule_id": "correctness-off-by-one"
}
```

---

### resolver_outcome

Emitted once per autonomous resolution attempt after a reviewer finding is addressed. Captures the action taken and whether the resolution was accepted.

**Per-type fields**:

| Field | Type | Required/Optional | Default | Semantics |
|---|---|---|---|---|
| `finding_id` | string | required | — | The `finding_id` from the `review_finding` event being resolved. |
| `resolution_action` | string | required | — | Action taken. One of: `code_fix` (code was changed to address the finding), `defense` (finding was defended as a false positive or out-of-scope), `escalated` (resolution exhausted autonomous attempts and was escalated to user). |
| `resolution_cycle` | integer | required | — | The resolution attempt number (1-indexed) within the current review cycle. |
| `accepted` | boolean | required | — | `true` if the resolution was accepted by the subsequent review pass; `false` if the finding persisted. |
| `resolution_summary` | string | optional | absent | One-sentence summary of the resolution action taken. |

**Worked example**:

```json
{
  "schema_version": 1,
  "event_id": "b2c3d4e5-f6a7-4890-bcde-f01234567890",
  "event_type": "resolver_outcome",
  "client_id": "c8f2e1a0-4b3d-4c9e-8f1a-2b3c4d5e6f70",
  "tool_id": "dso",
  "tool_version": "1.17.11",
  "timestamp": "2026-05-22T14:31:00Z",
  "pr_number": 279,
  "commit_sha": "69b5b59240abc123def456abc123def456abc123",
  "cycle": 1,
  "language": "python",
  "finding_id": "f-a1b2c3d4",
  "resolution_action": "code_fix",
  "resolution_cycle": 1,
  "accepted": true,
  "resolution_summary": "Replaced i < len(items) with i < len(items) - 1 to prevent out-of-range access."
}
```

---

### arbiter_ruling

Emitted when the arbiter agent issues a ruling on a disputed finding (typically a `RESUSTAIN_OF` finding that was previously defended).

**Per-type fields**:

| Field | Type | Required/Optional | Default | Semantics |
|---|---|---|---|---|
| `finding_id` | string | required | — | The `finding_id` of the finding under arbiter review. |
| `prior_finding_id` | string | required | — | The `finding_id` of the prior-cycle finding being resustained. |
| `arbiter_decision` | string | required | — | Arbiter ruling. One of: `uphold` (finding stands; resolver must address it), `dismiss` (finding dismissed; prior defense accepted), `downgrade` (severity lowered; resolver must address at new severity). |
| `arbiter_rationale` | string | required | — | One-sentence rationale for the arbiter decision. |
| `downgraded_severity` | string | optional | absent | Present only when `arbiter_decision` is `downgrade`. New severity value. One of: `minor`, `suggestion`. |

**Worked example**:

```json
{
  "schema_version": 1,
  "event_id": "c3d4e5f6-a7b8-4901-cdef-012345678901",
  "event_type": "arbiter_ruling",
  "client_id": "c8f2e1a0-4b3d-4c9e-8f1a-2b3c4d5e6f70",
  "tool_id": "dso",
  "tool_version": "1.17.11",
  "timestamp": "2026-05-22T14:32:00Z",
  "pr_number": 279,
  "commit_sha": "69b5b59240abc123def456abc123def456abc123",
  "cycle": 2,
  "language": "python",
  "finding_id": "f-m3n4o5p6",
  "prior_finding_id": "f-a1b2c3d4",
  "arbiter_decision": "uphold",
  "arbiter_rationale": "Prior defense did not address the root cause; the off-by-one remains exploitable via the /batch endpoint."
}
```

---

### tool_finding

Emitted when a static analysis tool, linter, or automated gate produces a finding that is surfaced through the DSO telemetry pipeline.

**Per-type fields**:

| Field | Type | Required/Optional | Default | Semantics |
|---|---|---|---|---|
| `tool_name` | string | required | — | Name of the tool that produced the finding (e.g., `ruff`, `shellcheck`, `pytest`). |
| `tool_rule` | string | required | — | Tool-specific rule or check identifier (e.g., `E501`, `SC2086`). |
| `tool_severity` | string | required | — | Severity as reported by the tool. One of: `error`, `warning`, `info`. |
| `file` | string | required | — | Repo-relative path to the file cited by this finding. |
| `line` | integer | optional | absent | Line number in the file where the finding was detected. |
| `message` | string | required | — | Verbatim message from the tool. |

**Worked example**:

```json
{
  "schema_version": 1,
  "event_id": "d4e5f6a7-b8c9-4012-defa-123456789012",
  "event_type": "tool_finding",
  "client_id": "c8f2e1a0-4b3d-4c9e-8f1a-2b3c4d5e6f70",
  "tool_id": "dso",
  "tool_version": "1.17.11",
  "timestamp": "2026-05-22T14:33:00Z",
  "pr_number": 279,
  "commit_sha": "69b5b59240abc123def456abc123def456abc123",
  "cycle": 1,
  "language": "python",
  "tool_name": "ruff",
  "tool_rule": "E501",
  "tool_severity": "error",
  "file": "src/processor.py",
  "line": 88,
  "message": "Line too long (92 > 88 characters)"
}
```

---

### review_cycle

Emitted once per review cycle to summarize the aggregate outcome of that cycle. Provides roll-up counts for dashboards and trend analysis.

**Per-type fields**:

| Field | Type | Required/Optional | Default | Semantics |
|---|---|---|---|---|
| `cycle_number` | integer | required | — | The review cycle number (1 = first review, 2 = first re-review, etc.). Matches `cycle` in common fields. |
| `tier` | string | required | — | Review tier used in this cycle. One of: `light`, `standard`, `deep`. |
| `finding_count` | integer | required | — | Total number of findings produced in this cycle. |
| `critical_count` | integer | required | — | Number of `critical` severity findings in this cycle. |
| `important_count` | integer | required | — | Number of `important` severity findings in this cycle. |
| `minor_count` | integer | required | — | Number of `minor` severity findings in this cycle. |
| `pass` | boolean | required | — | `true` if the cycle ended with no unresolved `critical` or `important` findings; `false` otherwise. |
| `resolution_attempts` | integer | required | `0` | Number of autonomous resolution attempts made during this cycle. |
| `diff_hash` | string | required | — | SHA-256 hash of the diff reviewed in this cycle; used for integrity correlation. |

**Worked example**:

```json
{
  "schema_version": 1,
  "event_id": "e5f6a7b8-c9d0-4123-efab-234567890123",
  "event_type": "review_cycle",
  "client_id": "c8f2e1a0-4b3d-4c9e-8f1a-2b3c4d5e6f70",
  "tool_id": "dso",
  "tool_version": "1.17.11",
  "timestamp": "2026-05-22T14:34:00Z",
  "pr_number": 279,
  "commit_sha": "69b5b59240abc123def456abc123def456abc123",
  "cycle": 1,
  "language": "python",
  "cycle_number": 1,
  "tier": "standard",
  "finding_count": 3,
  "critical_count": 0,
  "important_count": 1,
  "minor_count": 2,
  "pass": false,
  "resolution_attempts": 0,
  "diff_hash": "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
}
```

---

## Two-Layer Privacy Policy

Telemetry events are structured around a two-layer privacy model that separates structural metadata from content-carrying fields.

**Layer 1: Structural/Identifying Fields**

Layer 1 fields are always emitted regardless of configuration. These fields identify the event, the tool, the client, and the workflow context without including any verbatim source code or finding text. All 11 common fields and all per-type fields except `cited_excerpt` are Layer 1 fields. Layer 1 data is safe to emit unconditionally because it contains no user-authored content.

**Layer 2: Excerpt Content**

Layer 2 is the `cited_excerpt` field present in `review_finding` events. This field contains verbatim source code copied from the repository under review. Because `cited_excerpt` may contain sensitive logic, credentials, or proprietary algorithms, it is controlled by the `telemetry.emit_excerpts` configuration flag. When `telemetry.emit_excerpts` is `false` (the default), `cited_excerpt` is omitted entirely from all emitted events. When `telemetry.emit_excerpts` is `true`, `cited_excerpt` is populated with the verbatim code excerpt and transmitted to the central endpoint. Users must explicitly opt in to Layer 2 emission.

---

## Privacy Disclosure

Setting `telemetry.emit_excerpts=true` causes the `cited_excerpt` field to be populated with verbatim code from the repository under review and transmitted as part of every `review_finding` telemetry event. This verbatim code is readable by the central-endpoint maintainer as part of normal event ingestion and log retention. The central-endpoint maintainer has access to all data stored in the telemetry pipeline, including any `cited_excerpt` content.

When `telemetry.emit_excerpts` is `false` (the default), no source code excerpts are transmitted. The `cited_excerpt` field is omitted from all events, and the central-endpoint maintainer cannot observe repository source code through the telemetry pipeline.

**Users should review this disclosure before enabling `telemetry.emit_excerpts=true`.** Enabling this setting may cause proprietary, confidential, or security-sensitive source code to be transmitted to and stored by the central endpoint. Consult your organization's data governance policy before enabling excerpt emission.

---

## Cross-References

The following artifacts are produced by sibling stories and consume this contract. This section establishes bidirectional discoverability between the schema contract and its implementations.

- **`telemetry-emit.sh`** (sibling story): The telemetry emit utility that reads `dso-config.conf` for `telemetry.*` settings and emits events conforming to this schema. Every emitted event must validate against the field definitions in this document.
- **Lambda handler** (sibling story 6db5): The central Lambda function that receives, validates, and persists telemetry events. The handler gates on `schema_version` and routes event processing by `event_type` as defined in this document.
- **`${CLAUDE_PLUGIN_ROOT}/docs/workflows/prompts/reviewer-base.md`**: Defines the `rule_id` field format used in `review_finding` events. The `rule_id` namespacing convention documented there is the authoritative format for `review_finding.rule_id` values in this schema.
- **`${CLAUDE_PLUGIN_ROOT}/docs/contracts/review-findings-schema.md`**: Defines the full reviewer-finding record shape. The `review_finding` event type's per-type fields are derived from the finding record shape defined there.
