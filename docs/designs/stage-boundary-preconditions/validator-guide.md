# Stage-Boundary Validator Developer Guide

## Overview

The stage-boundary validator system verifies upstream PRECONDITIONS claims before each
workflow stage proceeds. This guide explains how to use the validator scripts and integrate
them into new stage entry/exit points.

---

## `preconditions-validator.sh` — CLI Usage

The standalone validator script reads the latest PRECONDITIONS event for a ticket and checks
whether its claims are still valid.

### Flags

```
preconditions-validator.sh --ticket-id <id> --stage <gate_name> [--strict]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--ticket-id` | yes | Ticket ID to validate |
| `--stage` | yes | Stage being entered: `preplanning`, `implementation-plan`, `sprint`, `commit`, `epic-closure` |
| `--strict` | no | Fail hard on any invalid claim (default: warn and continue) |

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Validation passed — all claims verified |
| 1 | Validation failed (hard failure in `--strict` mode) |
| 2 | No PRECONDITIONS event found — validator skips (non-blocking) |
| 3 | Malformed event — validator skips with `[DSO WARN]` |

### Example

```bash
"$REPO_ROOT/.claude/scripts/dso" preconditions-validator.sh \
  --ticket-id 736d-b957 \
  --stage sprint
```

---

## `preconditions-validator-lib.sh` — Entry/Exit Hook Integration

The library provides two functions for embedding validators in skill/agent files:

### Entry Check

Call at the **start** of a stage to verify upstream PRECONDITIONS:

```bash
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/preconditions-validator-lib.sh"
_preconditions_entry_check --ticket-id "$TICKET_ID" --stage "sprint"
```

Behavior:
- Reads the latest PRECONDITIONS event for the ticket
- Logs `[PRECONDITIONS] entry check passed` on success
- Logs `[PRECONDITIONS] WARN: <reason>` and continues on failure (fail-open)
- Never prompts the user; never blocks the workflow

### Exit Write

Call at the **end** of a stage to write a PRECONDITIONS event for downstream validators:

```bash
_preconditions_exit_write \
  --ticket-id "$TICKET_ID" \
  --stage "sprint" \
  --manifest-depth "$MANIFEST_DEPTH"
```

Behavior:
- Writes a new `<ts>-<uuid>-PRECONDITIONS.json` to the ticket directory
- Selects depth tier from `manifest_depth` (or auto-detects from ticket if absent)
- Appends — never overwrites existing events

---

## Depth-Agnostic Contract

All validators are depth-agnostic: they read only `minimal`-tier fields regardless of
`manifest_depth`. This ensures:

1. A validator written against `minimal` continues to work on `standard`/`deep` events
2. Unknown fields are silently ignored (not rejected)
3. No validator depends on `manifest_depth` for its pass/fail logic

**Rule**: if a validator requires a `standard` or `deep` field to function, that field must
be promoted to `minimal` in the schema.

---

## Stage Boundary Map

Each stage entry validates upstream claims; each stage exit writes claims for downstream:

```
brainstorm (exit write)
    ↓
preplanning (entry check + exit write)
    ↓
implementation-plan (entry check + exit write)
    ↓
sprint (entry check + exit write)
    ↓
commit (entry check)
    ↓
epic-closure (entry check via completion-verifier)
```

---

## Zero User-Interaction Invariant

Validators MUST NOT prompt the user. Specifically:

- `source_type: user` claims are validated against **existing** ticket comments only (no new prompts)
- `source_type: inference` is accepted when `rationale` is non-empty (structural acceptance)
- Validation failures produce `[PRECONDITIONS] WARN` log lines, not blocking errors
- The `--strict` flag is for CI/test contexts only; production workflows use default (fail-open)

---

## Self-Verification

Validators run against their own PRECONDITIONS events at each stage boundary (dogfooding).
The chain-of-trust is rooted at the brainstorm writer's schema check. See
`contracts-index.md` for the `self_verification_semantics` pinned contract.
