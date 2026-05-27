# Contract: execution-trace

- Signal Name: execution-trace
- Status: accepted
- Scope: Pre-verifier execution traces (pre-verifier-execute.sh → completion-verifier)
- Date: 2026-05-26

## Purpose

Shared schema for pre-verifier execution traces. Referenced by `pre-verifier-execute.sh` (producer)
and `completion-verifier.md` Step 2.7 (consumer).

## Schema (v1)

```yaml
schema_version: 1
trace:
  story_id: string
  generated_at: ISO8601
  manifest:                          # ALL DDs — executed or not
    - dd_id: string                  # e.g., "dd-1"
      dd_text: string                # verbatim DD text
      verify_command: string | null  # null = no command found
      executed: boolean
      skip_reason: string | null     # e.g., "no verify command", "parse error"
  results:                           # only executed DDs
    - dd_id: string
      verify_command: string
      exit_code: integer
      stdout_tail: string            # last 20 lines
      stderr_tail: string            # last 20 lines
      duration_ms: integer
      attempt: integer               # 1 or 2 (retry on first failure)
      outcome: PASS | FAIL | TIMEOUT | SKIP
      confidence: high | normal      # high = known test runner; normal = other
  summary:
    total_dds: integer
    executed: integer
    passed: integer
    failed: integer
    timeout: integer
    skipped: integer
    no_command: integer
```

## Manifest Independence

The manifest is built from the ticket's DD list independently of the `verify_commands` structured field.
A DD with a malformed or missing Verify command appears as `verify_command: null, executed: false,
skip_reason: "no verify command"`. The verifier detects coverage gaps even when extraction fails.

## Confidence Classification

Commands invoking a known test runner get `confidence: high`:
- `pytest`
- `make test` / `make test-*`
- `npm test`
- `bash` on a `test-*.sh` file
- `curl` / `httpie`
- `./validate.sh`

All other commands get `confidence: normal`. The verifier applies extra scrutiny to `normal`-confidence
traces — checking that the test file actually tests the DD's subject (Phase 3 fidelity check).

Additionally, if a command's `confidence` is `high` but the DD text's subject nouns are absent from
the command (Phase 3 subject-noun fidelity check), confidence is downgraded to `normal`.

Confidence does not block execution or change the verifier's pass/fail verdict — it is an advisory
signal for the verifier to allocate more inspection effort.

## Timeout and Retry

- Default timeout: 60s (configurable via `dso-config.conf` key `verify.timeout_seconds`, or `DSO_VERIFY_TIMEOUT` env var for testing)
- On first failure (exit code != 0) or timeout: retry once (flake tolerance for both transient failures and transient slowness)
- After retry: if the command still fails, record `outcome: FAIL`; if it still times out, record `outcome: TIMEOUT`
- Timeout and retry metadata are included in the trace results

## Consumer Contract

### Sprint Orchestrator (producer)
Runs `pre-verifier-execute.sh <story-id>`, receives the trace file path on stdout,
and passes `VERIFY_TRACE_PATH=<path>` in the completion-verifier prompt.

### Completion Verifier (consumer)
Reads the trace file at `VERIFY_TRACE_PATH`. Evaluation rules per outcome:
- PASS → primary evidence for PASS verdict
- FAIL → definitive FAIL (no code-inspection override)
- TIMEOUT → EVIDENCE_PENDING (code inspection supplementary, cannot produce PASS alone)
- SKIP → existing code-inspection behavior
- DD in manifest with no command → EVIDENCE_PENDING
- DD missing from manifest → EVIDENCE_PENDING
- No trace file → full backward compatibility
