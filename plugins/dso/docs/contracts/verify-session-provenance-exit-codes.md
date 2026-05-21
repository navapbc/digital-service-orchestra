# Contract: verify-session-provenance.sh Exit Codes

Source: `${CLAUDE_PLUGIN_ROOT}/scripts/verify-session-provenance.sh`
Bug: 8a77-eda4-e03d-4371 (v2 unified fix)

## Purpose

Locks the exit-code semantics of `verify-session-provenance.sh` and the
artifact files it writes alongside each exit. Consumers — most importantly
`llm-review-dispatch-or-skip.sh` and ci.yml's `Verify session provenance`
step — route on these codes and artifacts. Changes to this contract must
update both consumers and the corresponding contract tests in
`tests/scripts/test-verify-session-provenance-contract.sh`.

## Exit Codes

| Code | Meaning | Marker written? | Artifacts written |
|-----:|:--------|:---------------:|:------------------|
| 0 | All commits in `BASE_SHA..SESSION_HEAD` are provenanced (trailer, cache, or merged-PR coverage). | Yes | `provenance-complete.marker`, `covered-shas.txt` |
| 1 | One or more commits lack provenance. | Yes | `provenance-complete.marker`, `covered-shas.txt`, `unprovenanced-shas.txt` |
| 2 | `GH_BUDGET` API call cap exhausted before all commits were checked. | Yes | `provenance-complete.marker`, `covered-shas.txt`, `unprovenanced-shas.txt` (partial) |
| 3 | One or more commits carry the `DSO-Over-Bound:` marker (acknowledged non-provenanced; routed to admin/FP-recovery). | Yes | `provenance-complete.marker`, `covered-shas.txt`, `over-bound-shas.txt` |
| 4 | `BASE_SHA` or `SESSION_HEAD` is not reachable in the working tree. **Configuration error** — typical under `actions/checkout@v4` default `fetch-depth: 1` when only `refs/pull/N/merge` was fetched. | **No** | None |

## Why exit 4 writes NO marker

The presence of `provenance-complete.marker` is the load-bearing signal that
the verifier ran to completion without an early-exit error. Downstream
consumers (notably `llm-review-dispatch-or-skip.sh`) require this marker
before trusting "no unprovenanced file" as equivalent to "all provenanced".

If exit 4 wrote a marker, a configuration error would be indistinguishable
from a clean walk that found no unprovenanced commits — recreating the
original silent-skip bug class (8a77 root cause).

## Artifact directory

`ARTIFACT_DIR="${DSO_ARTIFACT_DIR:-/tmp}"` — set by ci.yml's
`Verify session provenance` step to `${{ runner.temp }}/dso-review`.

All artifact paths are relative to `ARTIFACT_DIR`:
- `provenance-complete.marker` — UTC ISO-8601 timestamp of clean completion
- `covered-shas.txt` — newline-delimited SHAs classified as provenanced
- `unprovenanced-shas.txt` — newline-delimited SHAs lacking provenance
- `over-bound-shas.txt` — newline-delimited SHAs carrying `DSO-Over-Bound:` marker

## Consumer routing (dispatcher)

`llm-review-dispatch-or-skip.sh` derives its routing from the artifacts
above, not from the verifier's exit code directly:

```
marker absent                  → ERROR exit 1 ("verifier never ran cleanly")
unprovenanced-shas.txt size>0  → exit-1 path (invoke ci-llm-review-runner.sh)
over-bound-shas.txt size>0     → exit-3 path (skip + OVER_BOUND summary)
otherwise (marker present, both files empty/absent) → exit-0 path (skip + liveness)
```

Precedence matches the verifier's own exit-code precedence (lines 432-444):
unprovenanced > over-bound > all-provenanced. The defensive ordering ensures
that if both artifacts were non-empty (verifier writes them as mutually
exclusive states), the runner dispatches review of the actually-unreviewed
commits rather than emitting an OVER_BOUND skip that would lose coverage.

## CI step routing (ci.yml `Verify session provenance`)

The CI step captures the verifier's exit code and routes:

```
0 | 1 | 2 | 3  → proceed (documented codes)
4              → fail step loud with ::error:: annotation
*              → fail step loud as unexpected code
```

This ensures exit 4 is surfaced to CI logs instead of being swallowed by
`2>/dev/null || true` (the pre-fix behavior that buried the underlying bug).
