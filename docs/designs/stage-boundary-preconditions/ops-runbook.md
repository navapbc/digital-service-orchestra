# Stage-Boundary PRECONDITIONS Operations Runbook

## Overview

This runbook covers monitoring, troubleshooting, and operational procedures for the
PRECONDITIONS system. It is the authoritative reference for operators and developers
dealing with validator failures, FP fallback events, and coverage gate outcomes.

---

## FP Auto-Fallback

### What It Is

When the false-positive rate for a ticket exceeds 10% of validation attempts, the system
automatically downgrades that ticket's `manifest_depth` from `standard`/`deep` to `minimal`
for future writes. Existing events are not modified.

### Monitoring `FALLBACK_ENGAGED`

FP fallback emits a structured log line:

```
[PRECONDITIONS] FALLBACK_ENGAGED ticket_id=<id> reason=fp_rate_exceeded threshold=0.10 observed_rate=<x>
```

To monitor for fallback events across all tickets:

```bash
grep "FALLBACK_ENGAGED" ~/.claude/logs/dso-hook-errors.jsonl | \
  jq -r '.message' | sort | uniq -c | sort -rn
```

### Fallback Scope

- Per-ticket, per-write (not global or per-session)
- Only new writes are affected; existing standard/deep events remain honored
- Validators remain depth-agnostic — fallback does not change validation logic
- Fallback resets when the ticket's FP rate drops below 10% over a 30-event window

---

## SC9 Coverage Gate

### What It Is

The 818-bug dry-run coverage harness demonstrates that PRECONDITIONS validators would have
caught ≥100 of the 818 historical bugs in the closed-bug corpus.

### Monitoring `COVERAGE_RESULT`

The harness emits:

```
[COVERAGE] COVERAGE_RESULT total_checked=818 would_have_prevented=<N> rate=<x>%
```

A `COVERAGE_RESULT` below the 100-bug threshold is a gate failure. To re-run manually:

```bash
"$REPO_ROOT/.claude/scripts/dso" coverage-harness.sh --corpus tests/fixtures/bug-corpus-818.json
```

### Expected Output Fields

| Field | Description |
|-------|-------------|
| `total_checked` | Number of bugs in the corpus |
| `would_have_prevented` | Bugs where a PRECONDITIONS check would have caught the issue |
| `rate` | `would_have_prevented / total_checked` as a percentage |
| `gate_passed` | `true` when `would_have_prevented >= 100` |

---

## SC13 Restart Analysis

### Methodology

Workflow-restart rate is measured using Wilson confidence interval (CI) to handle small
sample sizes. The baseline is captured before Story 1 lands (before any PRECONDITIONS
events exist). Post-deployment measurement runs after 30+ workflow restarts are observed.

**Target**: ≥30% reduction in restart rate relative to baseline.

### Running the Analysis

```bash
"$REPO_ROOT/.claude/scripts/dso" analyze-restart-rate.sh \
  --baseline-file tests/fixtures/restart-baseline.json \
  --current-window 30d
```

Output includes Wilson CI bounds and whether the 30% threshold is met.

---

## Troubleshooting

### Stale RED Markers

**Symptom**: `record-test-status.sh` reports `INFO: RED marker '...' set but parser found no matching function names; tolerating as RED-zone failure.`

**Cause**: The test function named in the RED marker doesn't match any function in the test file (case-sensitive, exact match required).

**Fix**: Either update the RED marker in `.test-index` to match the exact function name, or run `--restart` to clear the stale entry:
```bash
DSO_COMMIT_WORKFLOW=1 "$REPO_ROOT/.claude/scripts/dso" record-test-status.sh \
  --source-file <test-file> --restart
```

### Hash Mismatch at Commit

**Symptom**: Review gate reports `diff hash mismatch`.

**Cause**: Files were modified after `compute-diff-hash.sh` was run.

**Fix**: Restore tracked files to HEAD before recomputing:
```bash
git restore --staged -- <modified-files>
git add <files-to-stage>
"$REPO_ROOT/.claude/scripts/dso" compute-diff-hash.sh
```

### Validator Exit Code 3 (Malformed Event)

**Symptom**: `[DSO WARN] malformed PRECONDITIONS event` in logs.

**Cause**: A PRECONDITIONS event file has invalid JSON or missing required fields.

**Fix**: Inspect the event file:
```bash
jq '.' "$TICKET_DIR"/*-PRECONDITIONS.json | head -50
```

Required fields for all tiers: `event_type`, `gate_name`, `session_id`, `worktree_id`, `tier`, `timestamp`, `schema_version`, `manifest_depth`, `data`.

### No PRECONDITIONS Events for Ticket (Exit Code 2)

**Symptom**: Validator exits `2` with empty output.

**Cause**: Either a legacy ticket (expected) or the upstream stage did not write an event (bug).

**Fix**: For legacy tickets, `2` is expected behavior — no action needed. For new tickets:
1. Check if the upstream stage ran successfully
2. Verify the ticket directory exists: `ls "$TICKETS_DIR/$TICKET_ID/"*-PRECONDITIONS.json`
3. If missing, re-run the upstream stage to write the event

---

## Performance Budgets (p95 Latency)

Committed p95 latency targets measured on a standard dev machine (10-sample run via
`plugins/dso/scripts/preconditions-benchmark.sh`):

| Stage | p95 Budget | Script entry point |
|-------|-----------|-------------------|
| `write_preconditions` | ≤ 500ms | `_write_preconditions()` in ticket-lib.sh |
| `read_latest_preconditions` | ≤ 300ms | `_read_latest_preconditions()` in ticket-lib.sh |
| `validate_preconditions` | ≤ 300ms | `preconditions-validator-lib.sh` |
| `compact_preconditions` | ≤ 250ms | `_compact_preconditions()` in ticket-lib.sh |
| `classify_depth` | ≤ 200ms | complexity-evaluator → `manifest_depth` mapping |

Baseline measurements (2026-04-20, 10-sample):
- write_preconditions: p95=225ms
- read_latest_preconditions: p95=144ms
- validate_preconditions: p95=132ms
- compact_preconditions: p95=113ms
- classify_depth: p95=80ms

**To re-measure**: `bash plugins/dso/scripts/preconditions-benchmark.sh --iterations=50 --output=json`

If any stage exceeds its budget in CI, investigate: slow filesystem, large ticket event directories
(>1000 files → compact), or Python startup overhead (use `python3 -m` warm-start pattern).

---

## Review Adjacency — Validator Cost in /dso:review Flow

The PRECONDITIONS validator runs **before** the review gate, not adjacent to it. The cost model:

```
Stage-boundary write (upstream) → commit → pre-commit hook runs validators
                                         → review gate (if validator passes, review proceeds)
```

The validator (`preconditions-validator-lib.sh`) adds ≤300ms p95 to the pre-commit hook chain.
This is **not** in the hot path of `/dso:review` itself — review dispatches sub-agents which have
their own timeout budget. The validator's exit code is checked before review sub-agents are
dispatched; a failed validator blocks review dispatch (fail-fast to preserve sub-agent budget).

**Review flow with PRECONDITIONS**:
1. Pre-commit hook runs `preconditions-validator-lib.sh` (≤300ms)
2. If exit 0: proceed to review gate and `/dso:review` dispatch
3. If exit 2 (pre-manifest, no events): proceed with warning logged to stderr
4. If exit 1 (validation failure): block commit; reviewer sub-agents are not dispatched

This design ensures reviewer sub-agent budget is not wasted on commits that will fail
preconditions checks downstream.
