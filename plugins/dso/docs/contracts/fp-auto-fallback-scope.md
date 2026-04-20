# Contract: FP Auto-Fallback Scope

## Purpose

Defines the scope constraints and signal format for the automatic false-positive (FP) rate fallback mechanism in the preconditions manifest system. When a rolling FP rate exceeds the threshold (10%), `fp-rate-tracker.sh` engages fallback to limit further precision loss by downgrading new PRECONDITIONS writes to minimal tier for the affected ticket. This contract pins what fallback can and cannot do, protecting the core depth-agnostic invariant from Story 2.

## Signal Name

`FALLBACK_ENGAGED`

### Canonical parsing prefix

`FALLBACK_ENGAGED`

Parsers identify this signal by scanning stdout for a line containing `{"signal":"FALLBACK_ENGAGED"`.

## Signal Format

```json
{
  "signal": "FALLBACK_ENGAGED",
  "ticket_id": "<ticket-id>",
  "fp_rate": <float>,
  "threshold": 0.10
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `signal` | string | Always `"FALLBACK_ENGAGED"` |
| `ticket_id` | string | The ticket for which fallback was engaged |
| `fp_rate` | float | The measured rolling FP rate that crossed the threshold |
| `threshold` | float | The threshold that was exceeded (always `0.10`) |

## Scope Constraints

### 1. Per-write scope — not retroactive

Fallback applies to **new writes only**. Already-written PRECONDITIONS events at standard or deep tier remain valid and are not truncated, re-written, or re-interpreted. The preconditions validator honors all previously-written events at their original `manifest_depth`, regardless of fallback state.

### 2. New events only

Once fallback is engaged for a ticket, the classifier's next emission for that ticket degrades to minimal tier. Events written before fallback engagement continue to be processed at their original depth.

### 3. Per-ticket scope

Fallback is scoped to a single ticket. It is not global and not per-epic. A high FP rate on ticket A does not affect ticket B's depth tier.

### 4. Validators stay depth-agnostic

Validators MUST NOT inspect `manifest_depth` to gate their evaluation. Depth-agnosticism (established in Story 2) is the invariant that makes fallback safe — validators accept all depth tiers without special-casing. The `fallback_engaged` field in event data is informational only and MUST NOT change validator behavior.

## FP Threshold

`> 10%` rolling window triggers fallback. Exactly `0.10` (10%) does NOT trigger fallback — the comparison is strictly greater-than (`fp_rate > threshold`).

## Implementation Notes

- `fp-rate-tracker.sh` reads PRECONDITIONS events for the ticket and counts events where `data.fp_flagged=true`.
- Rate = `fp_flagged_count / total_event_count`.
- When `rate > 0.10`, the script emits `FALLBACK_ENGAGED` to stdout and writes a new minimal-tier PRECONDITIONS event with `data.fallback_engaged=true`.
- The script exits 0 always — fallback is advisory and non-blocking.
- The `fallback_engaged` field in the new event data allows operators to trace the transition.
