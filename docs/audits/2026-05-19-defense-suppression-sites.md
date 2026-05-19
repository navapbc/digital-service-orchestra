# Defense-Suppression Invocation Site Audit

**Date**: 2026-05-19
**Task**: S2.T13 (2ffc-932e-1964-4694)
**Story**: 0aed-4d7a-991d-4f7f (PR/review workflow remediation epic f691-681e-0db9-4260)

## Scope

This audit enumerates every site in the codebase that produces, consumes, or passes through
the `DSO_SUPPRESS_PRIOR_DEFENSES` signal. The canonical producer is the "Suppress prior defenses
for integration review" step in `.github/workflows/ci.yml` (originally labeled ci.yml:523 in the
DD4 gap analysis; lines shifted to 569-582 after T10 consumer comment was added).

The (pr_number, commit_sha) v1.2.0 contract (landed in S2.T2) governs the fingerprint key shape
used by `_defense_compute_fingerprint` and `defense_store_write`. This audit cross-checks whether
any invocation site is inconsistent with that contract.

---

## Invocation Sites

### Site 1: `.github/workflows/ci.yml` lines 569-582 — PRODUCER

**Role**: Producer (setter)
**Signal direction**: Outbound via `$GITHUB_ENV`
**Key-shape relevance**: None — this site sets a boolean env var (`DSO_SUPPRESS_PRIOR_DEFENSES=true`),
not a fingerprint. No (pr_number, commit_sha) tuple is involved.

**Detail**: The "Suppress prior defenses for integration review" step runs unconditionally
(gated by `needs.changes.outputs.code_changed == 'true'`) and appends
`DSO_SUPPRESS_PRIOR_DEFENSES=true` to `$GITHUB_ENV`, making it available to all subsequent steps.
The inline comment explicitly documents the consumer (T10 / runner.py) per the T10 landing.

**Status**: **verified** — consistent with v1.2.0 contract; boolean flag only, no fingerprint shape
involved. No rekeying needed.

---

### Site 2: `.github/workflows/ci.yml` line 603 — PASS-THROUGH

**Role**: Consumer (env pass-through to Python subprocess)
**Signal direction**: Inbound from `$GITHUB_ENV`, forwarded to runner.py environment
**Key-shape relevance**: None — this is a pure pass-through (`DSO_SUPPRESS_PRIOR_DEFENSES: ${{ env.DSO_SUPPRESS_PRIOR_DEFENSES }}`).
No fingerprint computation occurs here.

**Detail**: The "Run LLM review" step's `env:` block forwards the env var set by Site 1 into the
`python3 -m dso_ci_review.runner` subprocess. This is the bridge between the setter (ci.yml:581)
and the terminal consumer (runner.py).

**Status**: **verified** — consistent with v1.2.0 contract; no fingerprint shape involved.
No rekeying needed.

---

### Site 3: `plugins/dso/scripts/dso_ci_review/runner.py` lines 1771-1793 — CONSUMER

**Role**: Consumer (terminal reader and gate)
**Signal direction**: Inbound from environment
**Key-shape relevance**: Relevant — this site gates the v1.2.0-keyed prior-defense loading path.

**Detail**:
```python
_suppress_prior_defenses = (
    os.environ.get("DSO_SUPPRESS_PRIOR_DEFENSES", "").lower() == "true"
)
prior_defenses: list[dict] = []
if cycle_number >= 2 and not _suppress_prior_defenses:
    if pr_number:
        prior_defenses = _fetch_pr_defenses(pr_number)
        ...
elif cycle_number >= 2 and _suppress_prior_defenses:
    print(f"INFO: cycle {cycle_number} — DSO_SUPPRESS_PRIOR_DEFENSES=true: "
          "prior defenses suppressed for integration review pass", ...)
```

When `DSO_SUPPRESS_PRIOR_DEFENSES=true`, the prior-defense loading path (which uses the
(pr_number, commit_sha) v1.2.0 fingerprint shape via `_fetch_pr_defenses`) is bypassed entirely:
`prior_defenses=[]`. The v1.2.0 contract is correctly honored: when suppress=true, no fingerprint
lookup occurs, and the integration reviewer sees an unfiltered finding set.

**Status**: **verified** — correctly gates the v1.2.0 fingerprint-keyed loading path. The
consumer was wired in T10. No rekeying needed.

---

## Fingerprint Key-Shape Sanity (AC3)

The AC3 sanity grep checks for any remaining v1.1.0-shape `_defense_compute_fingerprint` calls
(calls that omit `pr_number` in production code paths):

```
! grep -rE '_defense_compute_fingerprint.*\$path.*\$lineno[^pr_]' plugins/dso/scripts/ \
  | grep -v -E 'pr_number|test|\.md'
```

Result: **PASS** — no v1.1.0-shape fingerprints found in `plugins/dso/scripts/`. The single
call site in `review-defense-store.sh:139` passes `"$_write_pr_number"` as the 4th argument,
satisfying the v1.2.0 contract (sentinel 0 is used only for backward-compatible legacy reads,
never written by v1.2.0 writers).

---

## Conclusion

**There are exactly 3 invocation sites** for `DSO_SUPPRESS_PRIOR_DEFENSES`:

| # | File | Lines | Role | Key-shape status |
|---|------|-------|------|-----------------|
| 1 | `.github/workflows/ci.yml` | 569-582 | Producer (setter via `$GITHUB_ENV`) | verified |
| 2 | `.github/workflows/ci.yml` | 603 | Pass-through (env to subprocess) | verified |
| 3 | `plugins/dso/scripts/dso_ci_review/runner.py` | 1771-1793 | Consumer (gate on prior-defense load) | verified |

**No additional sites exist** beyond the ci.yml producer/pass-through pair and the runner.py consumer
that landed in T10. The DD4 open audit question ("is ci.yml:523 the ONLY suppression site, or are
there others?") is answered: ci.yml is the sole producer/broker; runner.py is the sole consumer.
No rekeying was required.

---

## Related Files Checked (Not Invocation Sites)

- `plugins/dso/scripts/review-defense-store.sh` — contains `_defense_compute_fingerprint` and
  `defense_store_write` (the v1.2.0 fingerprint store), but does NOT reference
  `DSO_SUPPRESS_PRIOR_DEFENSES`. Unrelated. **Status: unrelated**.
- `plugins/dso/scripts/review-github-defense-store.sh` — contains `github_defense_store_list`
  (defense record fetcher via gh API), does NOT reference `DSO_SUPPRESS_PRIOR_DEFENSES`. **Status: unrelated**.
- `plugins/dso/scripts/dso_ci_review/local_workflow.py` — contains `prior_defenses` parameter
  threading for local review workflow; does NOT reference `DSO_SUPPRESS_PRIOR_DEFENSES` (local
  workflow does not have an integration-review suppression path — the flag is CI-only). **Status: unrelated**.
- `plugins/dso/scripts/dso_ci_review/region_split.py` — contains `prior_defenses` parameter
  threading for region-split review; does NOT reference `DSO_SUPPRESS_PRIOR_DEFENSES`. **Status: unrelated**.
- All other `.github/workflows/` files — no references to `DSO_SUPPRESS_PRIOR_DEFENSES`. **Status: unrelated**.
- `plugins/dso/skills/` (all files) — no references to `DSO_SUPPRESS_PRIOR_DEFENSES`. **Status: unrelated**.
