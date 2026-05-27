# Contract: verifier-verdict

- Signal Name: verifier-verdict
- Status: accepted
- Scope: completion-verifier P1 typed-enum verdict field (verifier → orchestrator)
- Date: 2026-05-18

## Purpose

This document defines the `P1` typed-enum verdict field added to completion-verifier output at `schema_version: 2`. The `P1` field provides a machine-readable, stable enum that orchestrators can parse without string-matching `overall_verdict` prose. The enum collapses legacy statuses (`PENDING`, `SKIPPED`) into typed values (`BLOCKED`, `INCONCLUSIVE`) that carry unambiguous semantics for routing and gating decisions.

---

## Signal Name

`verifier-verdict`

---

## Emitter

`dso:completion-verifier` agent — emits `P1` and `schema_version: 2` in its JSON output when reporting story or epic closure verification results.

---

## Parser

Sprint orchestrator and any machine-readable consumer that processes completion-verifier output. Consumers MUST check `schema_version` before reading `P1` (see Backward Compatibility below).

---

## P1 Enum

The `P1` field is a string typed to one of five values:

| Value | Semantics |
|---|---|
| `PASS` | All success criteria verified; story or epic may be closed. |
| `FAIL` | One or more success criteria not met; closure is blocked pending remediation. |
| `BLOCKED` | Verification could not proceed due to a dependency or external blocker (e.g., a required artifact is unavailable). |
| `INCONCLUSIVE` | Verification ran but produced insufficient evidence to render a PASS or FAIL verdict (e.g., test output missing, environment error, partial run). |
| `EVIDENCE_PENDING` | Execution traces are present but one or more DDs have TIMEOUT outcomes, missing Verify commands, or are absent from the trace manifest. The story cannot close. The orchestrator re-runs `pre-verifier-execute.sh` once; if still `EVIDENCE_PENDING`, escalates to user. Added by intent-fidelity-pipeline Phase 1. |

**Not valid in `P1`**: `PENDING`, `SKIPPED` — these are legacy `overall_verdict` values. They MUST NOT appear in the `P1` field.

---

## Legacy Mapping

When migrating from `schema_version: 1` (or absent) to `schema_version: 2`, apply this mapping:

| Legacy `overall_verdict` | `P1` value |
|---|---|
| `PASS` | `PASS` |
| `FAIL` | `FAIL` |
| `PENDING` | `BLOCKED` |
| `SKIPPED` | `INCONCLUSIVE` |

---

## Field Definitions

| Field | Type | Required | Description |
|---|---|---|---|
| `schema_version` | integer | Yes | `2` signals P1 is present and valid. Value `1` (or absent) means legacy format — fall back to `overall_verdict`. |
| `P1` | string | Yes (schema_version=2) | Typed enum: one of `PASS`, `FAIL`, `BLOCKED`, `INCONCLUSIVE`. Capital P, digit 1. |
| `overall_verdict` | string | Yes | Legacy field preserved for backward compat. One of `PASS`, `FAIL`, `PENDING`, `SKIPPED`. Consumers on schema_version < 2 read this field. |
| `narrative` | string | Conditional | Template string assembled from typed fields only — no LLM-generated prose. Format: `"P1={P1} criteria_met={criteria_met}/{criteria_total} blocked_by={blocked_count}"`. |

---

## Narrative Field

The `narrative` field is a deterministic template string sourced exclusively from typed fields in the verifier output. LLM-generated prose is prohibited in `narrative`.

**Template**:

```
P1={P1} criteria_met={criteria_met}/{criteria_total} blocked_by={blocked_count}
```

**Example**:

```
P1=PASS criteria_met=5/5 blocked_by=0
```

The `narrative` field is informational only. Parsers MUST NOT gate on `narrative` content — only `P1` carries routing authority.

---

## Backward Compatibility

Consumers MUST implement the following schema_version check before reading `P1`:

```
if schema_version >= 2:
    use P1 for routing
else:
    fall back to overall_verdict (apply legacy mapping if needed)
```

**Rule**: A consumer that reads `P1` without first verifying `schema_version >= 2` is non-conformant. Absent or `schema_version: 1` output must be handled via `overall_verdict`.

---

## Example JSON Output

### schema_version: 2 — PASS

```json
{
  "schema_version": 2,
  "overall_verdict": "PASS",
  "P1": "PASS",
  "narrative": "P1=PASS criteria_met=5/5 blocked_by=0",
  "criteria_met": 5,
  "criteria_total": 5,
  "blocked_count": 0
}
```

### schema_version: 2 — FAIL

```json
{
  "schema_version": 2,
  "overall_verdict": "FAIL",
  "P1": "FAIL",
  "narrative": "P1=FAIL criteria_met=3/5 blocked_by=0",
  "criteria_met": 3,
  "criteria_total": 5,
  "blocked_count": 0
}
```

### schema_version: 2 — BLOCKED (legacy PENDING)

```json
{
  "schema_version": 2,
  "overall_verdict": "PENDING",
  "P1": "BLOCKED",
  "narrative": "P1=BLOCKED criteria_met=2/5 blocked_by=2",
  "criteria_met": 2,
  "criteria_total": 5,
  "blocked_count": 2
}
```

### schema_version: 2 — INCONCLUSIVE (legacy SKIPPED)

```json
{
  "schema_version": 2,
  "overall_verdict": "SKIPPED",
  "P1": "INCONCLUSIVE",
  "narrative": "P1=INCONCLUSIVE criteria_met=0/5 blocked_by=0",
  "criteria_met": 0,
  "criteria_total": 5,
  "blocked_count": 0
}
```

### schema_version: 1 (legacy — no P1 field)

```json
{
  "schema_version": 1,
  "overall_verdict": "PASS"
}
```

---

### Canonical parsing prefix

`verifier-verdict` output is a JSON object. Parsers identify the `P1` field by reading the `P1` key at the top level of the JSON object.

**Parsing rules**:

1. Read the verifier output as a JSON object.
2. Check `schema_version`: if absent or less than `2`, fall back to `overall_verdict` (see Backward Compatibility above).
3. When `schema_version >= 2`, read `P1` from the top-level object:
   - `PASS` → gate opens (story/epic may close).
   - `FAIL` → gate blocks (success criteria not met).
   - `BLOCKED` → gate defers (dependency or external blocker prevents verification).
   - `INCONCLUSIVE` → gate defers (insufficient evidence; re-verify when conditions allow).
   - Any other (unrecognized) value → treat as `BLOCKED` (safe-default gate-block) and emit a warning to stderr.
   - `P1` absent on a schema_version=2 payload → treat as a malformed-payload error (exit 2). The producer claimed schema_version=2 but failed to emit the required `P1` field; this is a producer bug, not a verdict-class deferral.
4. Parsers MUST NOT gate on `narrative` content — only `P1` is authoritative.

There is no line-based prefix for this signal. The JSON object is the record; parsers operate on the parsed object, not on raw text.

---

## Exit Code Semantics (check-verifier-verdict.sh)

The script `check-verifier-verdict.sh` reads a verifier JSON payload and exits with:

| Exit code | Condition |
|---|---|
| `0` | `P1 == "PASS"` |
| `1` | `P1 == "FAIL"`, `"BLOCKED"`, `"INCONCLUSIVE"`, `"EVIDENCE_PENDING"`, or any other (unrecognized) `P1` value (per safe-default gate-block; emits a warning to stderr) |
| `2` | `P1` field absent on a `schema_version=2` payload, JSON malformed, or no input provided |

Usage: `echo '{"P1":"PASS"}' | check-verifier-verdict.sh` or `check-verifier-verdict.sh path/to/output.json`

---

## Consumers

| Component | Role | Notes |
|---|---|---|
| `dso:completion-verifier` | Emitter | Writes `P1` + `schema_version: 2` in story/epic closure output. |
| Sprint orchestrator | Parser | Reads `P1` to gate story/epic closure; falls back to `overall_verdict` when `schema_version < 2`. |
| `check-verifier-verdict.sh` | Parser | CLI wrapper; exits 0/1/2 based on `P1` value for use in shell pipelines. |

---

## Versioning

### Change Log

- **2026-05-18**: Initial version — defines P1 enum `{PASS, FAIL, BLOCKED, INCONCLUSIVE}`, schema_version=2 signal, PENDING→BLOCKED / SKIPPED→INCONCLUSIVE legacy mapping, narrative template constraint, backward-compat schema_version check rule, and check-verifier-verdict.sh exit code semantics.
- **2026-05-19**: Split the "unrecognized P1" case from the "P1 absent" case in `check-verifier-verdict.sh` exit semantics (R6 of project-audit-2026-05-19). Unrecognized P1 values now exit 1 with a `WARNING: unrecognized P1 verdict` to stderr (safe-default gate-block, matching the BLOCKED policy in the P1 narrative). P1 absent on a `schema_version=2` payload continues to exit 2 (malformed-payload — producer claimed schema_version=2 but did not emit the required field). Updated narrative under "Signal Routing" and the exit-code table accordingly.
