# Contract: inference-recall-result

- Signal Name: RECALL_RESULT
- Status: accepted
- Scope: inference-recall replay harness — output signals for recall/precision measurement and corpus quality gate
- Date: 2026-05-06

## Purpose

Defines the `RECALL_RESULT` and `CORPUS_INSUFFICIENT` signals emitted by `${CLAUDE_PLUGIN_ROOT}/scripts/inference-recall-replay.sh`. The harness validates that the inference-challenge system would have surfaced historical inference failures at required recall and precision thresholds. `RECALL_RESULT` is the primary success signal emitted after successful evaluation; `CORPUS_INSUFFICIENT` is the escalation signal emitted when the corpus is too small (< 10 incidents) to run a meaningful evaluation.

## Signal Name

`RECALL_RESULT` (primary success signal), `CORPUS_INSUFFICIENT` (escalation signal when corpus too small)

## Status

accepted

## Emitter

`${CLAUDE_PLUGIN_ROOT}/scripts/inference-recall-replay.sh`

## Output Schema

**RECALL_RESULT** (emitted on successful evaluation):

```json
{
  "signal": "RECALL_RESULT",
  "recall_all": <float>,
  "recall_holdout": <float>,
  "precision": <float>,
  "corpus_size": <int>,
  "holdout_size": <int>,
  "all_passed": <bool>,
  "thresholds": {"recall_all": 0.5, "recall_holdout": 0.7, "precision": 0.5}
}
```

**CORPUS_INSUFFICIENT** (emitted when corpus < 10 incidents):

```json
{"signal": "CORPUS_INSUFFICIENT", "corpus_size": <int>, "minimum_required": 10}
```

### Fields — RECALL_RESULT

| Field | Type | Description |
|-------|------|-------------|
| `signal` | string | Always `"RECALL_RESULT"` |
| `recall_all` | float | Fraction of all corpus incidents that the harness would have surfaced (0.0–1.0) |
| `recall_holdout` | float | Fraction of holdout-set incidents that the harness would have surfaced (0.0–1.0) |
| `precision` | float | Fraction of harness-surfaced incidents that are true positives (0.0–1.0) |
| `corpus_size` | int | Total number of incidents in the input corpus after quality check |
| `holdout_size` | int | Number of incidents in the holdout set |
| `all_passed` | bool | `true` when all three threshold conditions are satisfied |
| `thresholds` | object | Fixed threshold values used for pass/fail evaluation |

### Fields — CORPUS_INSUFFICIENT

| Field | Type | Description |
|-------|------|-------------|
| `signal` | string | Always `"CORPUS_INSUFFICIENT"` |
| `corpus_size` | int | Number of incidents found after quality check |
| `minimum_required` | int | Always `10`; minimum corpus size for evaluation |

## SC4 Gate Semantics

- Pass condition: `recall_all >= 0.5` AND `recall_holdout >= 0.7` AND `precision >= 0.5`
- Fail path: `all_passed=false` in RECALL_RESULT; harness exits 2
- CORPUS_INSUFFICIENT path: emitted when corpus size < 10 after quality check; harness exits 1

## Parser

The completion-verifier reads `RECALL_RESULT` from stdout, parses the JSON object on the line beginning with `{"signal": "RECALL_RESULT"`, and checks `all_passed == true` as the SC4 gate signal.

### Canonical parsing prefix

The parser matches lines beginning with `{"signal": "RECALL_RESULT"` or `{"signal": "CORPUS_INSUFFICIENT"}`.

## Invocation example

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/inference-recall-replay.sh" \
  --corpus=tests/fixtures/inference-incidents/incidents.jsonl \
  --holdout=tests/fixtures/inference-incidents/holdout.txt \
  --dry-run
```

## Consumers

| Consumer | Role |
|----------|------|
| `${CLAUDE_PLUGIN_ROOT}/agents/completion-verifier.md` | SC4 gate — checks `all_passed == true` before closing the inference-challenge epic |
| CI harness (`.github/workflows/`) | Runs harness on pull requests; fails the job when exit code is non-zero |
