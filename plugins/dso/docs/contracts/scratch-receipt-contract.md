# Contract: Scratch Handoff Receipt

- Signal Name: RECEIPT
- Status: accepted
- Scope: sub-agent → orchestrator handoff for scratch-stored payloads
- Date: 2026-05-25

## Purpose

This document defines the receipt-only return contract that sub-agents emit after writing a payload to the ticket-scratch store. The receipt tells the orchestrator where the payload lives (ticket_id and key) but does NOT embed the payload itself — keeping orchestrator context lean. The orchestrator-side `receipt-parse.sh` validates each receipt and halts the workflow with `RECEIPT_PARSE_ERROR` on any malformed shape.

## Overview

When a sub-agent completes a scratch-handoff task, it must return a **receipt-only** block.
The receipt tells the orchestrator where it stored the payload (ticket_id and key), but does NOT
embed the payload itself. This keeps orchestrator context lean.

The receipt is a JSON object with **exactly 3 fields**. No more, no less.

## Schema

```json
{
  "ticket_id": "<string>",
  "key":       "<string>",
  "byte_count": <integer>
}
```

| Field        | Type    | Description                                                    |
|--------------|---------|----------------------------------------------------------------|
| `ticket_id`  | string  | Ticket-scoped namespace key (from the scratch CLI)            |
| `key`        | string  | Scratch key name within the ticket namespace                  |
| `byte_count` | integer | Byte length of the written payload (for observability/audit)  |

The schema is strict: **exactly 3 keys are required**. Any deviation is a contract violation.

## Valid Payload Example

```json
{"ticket_id":"abcd-1234-efgh-5678","key":"impl-plan-output","byte_count":4096}
```

## Invalid Payload Examples

### Missing required field

```json
{"key":"impl-plan-output","byte_count":4096}
```

**Violation**: `ticket_id` is missing. Produces `RECEIPT_PARSE_ERROR reason=missing_field:ticket_id`.

### Extra field (sub-agent leaked draft)

```json
{
  "ticket_id": "abcd-1234-efgh-5678",
  "key": "impl-plan-output",
  "byte_count": 4096,
  "draft_body": "<large artifact payload — should not appear here>"
}
```

**Violation**: `draft_body` is an extra field beyond the 3-field contract. This indicates the
sub-agent embedded its full output in the return block rather than writing it to scratch.
Produces `RECEIPT_PARSE_ERROR reason=wrong_field_count:expected=3:actual=4`.

### Non-JSON input

```
This is not JSON at all.
```

**Violation**: Input is not parseable JSON. Produces `RECEIPT_PARSE_ERROR reason=not_valid_json`.

## Enforcement: receipt-parse.sh

The parser is implemented in `${CLAUDE_PLUGIN_ROOT}/scripts/receipt-parse.sh`.

**Usage:**

```bash
<sub_agent_output> | receipt-parse.sh <site_id> <subagent_name>
```

**Arguments:**

| Argument       | Description                                                      |
|----------------|------------------------------------------------------------------|
| `site_id`      | Call-site identifier (e.g., `impl-plan:511`) for error tracing  |
| `subagent_name`| Name of the sub-agent whose return block is being validated      |

**On success (exit 0):**

Prints `<ticket_id> <key>` (space-separated) to stdout. The orchestrator uses these values to
retrieve the payload from the scratch store.

**On failure (exit 2):**

Emits a structured log line to stderr:

```
RECEIPT_PARSE_ERROR site=<site_id> sub_agent=<subagent_name> reason=<reason_code> byte_count=<N>
```

## RECEIPT_PARSE_ERROR Escalation Semantics

When `receipt-parse.sh` exits non-zero, the **orchestrator MUST halt the workflow**:

1. **Do not silently retry**: The receipt contract violation indicates a sub-agent implementation
   problem. Retrying without fixing the sub-agent will reproduce the same violation.

2. **Do not forward a suspect key**: The `ticket_id` or `key` from a malformed receipt may be
   incorrect. Using them risks reading stale or wrong scratch data.

3. **Surface to the human session**: The structured log line (with `site`, `sub_agent`, `reason`,
   and `byte_count`) must be surfaced to the human session so the error is visible and actionable.

4. **Observable by validate.sh / CI**: `RECEIPT_PARSE_ERROR` log lines on stderr are captured by
   `validate.sh --ci` and visible in CI output.

### Error reason codes

| Reason code                          | Meaning                                               |
|--------------------------------------|-------------------------------------------------------|
| `not_valid_json`                     | Payload is not parseable as JSON                      |
| `not_a_json_object:type=<t>`         | Payload is JSON but not an object (e.g., array)       |
| `wrong_field_count:expected=3:actual=N` | Object does not have exactly 3 fields              |
| `missing_field:<name>`               | A required field is absent (after count check fails)  |
| `empty_or_null_field:<name>`         | A required string field is empty or JSON null         |
| `jq_not_found`                       | `jq` binary is not on PATH (dependency missing)       |

## Receipt-Only Contract Rationale

Sub-agents are explicitly prohibited from embedding payload content in their return blocks.
The payload must be written to the scratch store via `dso ticket scratch set`, and only a
receipt returned. This constraint:

- Keeps orchestrator context windows lean (large payloads stay in the scratch store, not in memory)
- Makes payload lifecycle explicit and auditable (scratch keys can be inspected and cleaned up)
- Enables observability: `byte_count` allows monitoring of payload sizes across runs

Violations are surfaced immediately as `RECEIPT_PARSE_ERROR` rather than silently passed through,
so payload-leakage bugs are caught at the contract boundary.

## See Also

- `${CLAUDE_PLUGIN_ROOT}/scripts/receipt-parse.sh` — parser implementation
- `${CLAUDE_PLUGIN_ROOT}/scripts/ticket-scratch-set.sh` — write payload to scratch store
- `${CLAUDE_PLUGIN_ROOT}/scripts/ticket-scratch-get.sh` — read payload from scratch store
- `tests/scratch/test-receipt-parse.sh` — behavioral test suite
