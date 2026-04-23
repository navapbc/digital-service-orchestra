# Contract: Coverage Harness Output

## Purpose

Defines the `COVERAGE_RESULT` signal emitted by `${CLAUDE_PLUGIN_ROOT}/scripts/preconditions-coverage-harness.sh` when it replays the 818-bug corpus through the preconditions manifest system. The signal is consumed by the epic-closure SC9 gate in `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md` to verify that the coverage threshold (≥100 preventions) is met before closing an epic.

## Signal Name

`COVERAGE_RESULT`

## Emitter

`${CLAUDE_PLUGIN_ROOT}/scripts/preconditions-coverage-harness.sh`

## Parser

Epic-closure SC9 gate in `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md` (Step N.5).

## Output Schema

```json
{
  "signal": "COVERAGE_RESULT",
  "preventions_count": <int>,
  "corpus_size": <int>,
  "prevention_rate": <float>,
  "threshold": 100
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `signal` | string | Always `"COVERAGE_RESULT"` |
| `preventions_count` | int | Number of corpus bugs for which at least one PRECONDITIONS validator gate would have triggered |
| `corpus_size` | int | Total number of bug records in the input corpus |
| `prevention_rate` | float | `preventions_count / corpus_size` (0.0–1.0) |
| `threshold` | int | Minimum `preventions_count` required to pass the SC9 gate (always `100`) |

## SC9 Gate Semantics

The epic-closure SC9 gate passes when `preventions_count >= threshold` (i.e., `>= 100`).

When `preventions_count < 100`, the completion-verifier emits `SC9_GATE_FAIL` and the overall epic verdict is `FAIL`.

## Example

```json
{
  "signal": "COVERAGE_RESULT",
  "preventions_count": 112,
  "corpus_size": 150,
  "prevention_rate": 0.747,
  "threshold": 100
}
```

### Canonical parsing prefix

`COVERAGE_RESULT`

Parsers identify this signal by scanning stdout for a line beginning with `{"signal":"COVERAGE_RESULT"`.

## Invocation

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/preconditions-coverage-harness.sh \
  --corpus tests/fixtures/818-corpus/sample-bugs.json \
  --dry-run \
  --output json
```

Default flags: `--dry-run`, `--output json`, `--corpus tests/fixtures/818-corpus/sample-bugs.json`.
