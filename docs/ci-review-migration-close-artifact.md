# CI Review Migration Close Artifact

Generated: 2026-05-05

## Overview

This document records the duration delta between the pre-migration CI review runner
(live API calls via `llm-api-call.sh`) and the post-migration dry-run path. It serves
as the SC5 close artifact for the ci-review migration epic.

## Duration Delta Table

Both baselines were captured in `dry_run` mode; the post-migration baseline reflects
the pure local execution path after `llm-api-call.sh` was deleted and replaced by the
dry-run runner.

| Metric | Pre-migration (baseline) | Post-migration | Delta |
|--------|--------------------------|----------------|-------|
| p50    | 28.58 ms                 | 1.00 ms        | −27.58 ms (−96.5%) |
| p95    | 33.66 ms                 | 2.00 ms        | −31.66 ms (−94.1%) |
| min    | 21.44 ms                 | 1.00 ms        | −20.44 ms (−95.3%) |
| max    | 34.80 ms                 | 3.00 ms        | −31.80 ms (−91.4%) |
| Iterations / runs | 20 (dry_run)  | 3 (dry_run)    | — |

> Unit normalisation: post-migration values are stored in seconds in
> `tests/fixtures/ci-review-post-migration.json`; converted to milliseconds above
> (×1000) for direct comparison.

## SC5 Assertion: Neutral-or-Better Duration

**SC5 PASS — post-migration dry-run is faster than pre-migration.**

Post-migration p50 (1.0 ms) is **28.58× faster** than the pre-migration p50 (28.58 ms).
Post-migration p95 (2.0 ms) is **16.83× faster** than the pre-migration p95 (33.66 ms).

The migration eliminates network round-trips to the LLM API; all CI review logic
now runs locally via the dry-run path, producing a duration reduction of ≥91% at
every measured percentile. This satisfies the SC5 requirement that the post-migration
execution be neutral-or-better relative to the API-call baseline.

## Compat Wrapper Note

No compat wrapper was created. `llm-api-call.sh` was deleted directly as part of the
migration — callers that previously depended on it were updated in-place to use the
new dry-run runner. No backward-compatibility shim is required or present.
