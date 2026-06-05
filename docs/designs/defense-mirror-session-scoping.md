# Design: bound defense-mirror accumulation by diff-hunk overlap (rev.2)

- **Status:** Draft for convergence review (rev.2 — panel REJECTED Option A; this is the convergent design)
- **Date:** 2026-06-04
- **Problem owner:** epic 588e (hot path — affects every PR's defense flow)

## Problem (unchanged)

`defense_store_list --pr <N>` (the CI "Mirror Tracker Defenses to PR" producer, `review-defense-store.sh:623,675-693`) iterates EVERY `*-COMMENT.json` defense blob on the `tickets` orphan ref (657 blobs today, all PRs/all time) and emits any whose cited file path intersects the current PR's changed-FILE set. So for a frequently-edited file, historical defenses citing it accumulate **without bound** and re-post to every new PR touching that file. **Goal:** defenses a session records appear on that session's PR; defenses do NOT accumulate across unrelated PRs/sessions.

## Rejected approaches

- **`--pr-number`:** `pr_number` is the dormant sentinel `0`; wrong key in the two-tier flow (mirror fires on PR2, defenses recorded against PR1). Rejected (opus analysis).
- **Option A — SHA-range ancestry (rev.1, REJECTED by the panel):** (1) the SHA fields are dormant, so it needed a write-side injection that **contradicts a landed test invariant** (`test_defense_store_write_legacy_no_sha_injection`, f61f-7e0a SC6 — H1); (2) it would fork a second copy of `defense_store_load_for_region`'s ancestry logic (H2); (3) the squash-robustness premise was **factually false** — `_squash_rebase_recovery` (`merge-helpers.sh:783`) rewrites history on a live path and `--squash` is a documented finalize strategy, so `tip_sha` can be unreachable → drops the session's own defense (C1); (4) the mirror CI job is a **shallow clone**, so `--is-ancestor` is unreliable (C2); (5) it does **nothing** for the 657 existing SHA-less records (I2). More machinery, more fragile, same goal.

## Design (diff-hunk overlap — the convergent mechanism)

Tighten the mirror filter from **changed-FILE** overlap to **changed-LINE (diff-hunk)** overlap, using only data available at mirror time. No write-side change, no SHA fields, no ancestry, no squash/merge-method/rebase coupling, no legacy backfill.

### Part 1 — line-level filter in `defense_store_list`

Add a `--head-sha <sha>` + `--base-sha <sha>` input (CI: the PR head + `origin/<base_ref>`). Compute the PR's changed line ranges once: `git diff <base>...<head> --unified=0` → a map `{path -> set of changed line ranges}`. Then in `record_matches_pr`:
- A record matches IFF at least one of its `cited_lines` entries (`path:lineno:content`) has `normalize_path(path)` in the changed set AND `lineno` falls inside a changed hunk range for that path.
- **Records with only `file_paths` (no `cited_lines` line numbers)** cannot be line-scoped → fall back to today's file-overlap for those (most defenses cite specific lines; this is a narrow transitional set). [convergence Q: should file_paths-only records be excluded instead? — they are the residual pollution vector.]
- **When `--head-sha`/`--base-sha` are absent OR the diff cannot be computed:** emit a `::warning::` (observability — RC-A lesson) and fall back to file-overlap (strictly today's behavior — the change is additive, never a new silent no-op).

This bounds accumulation to "defenses about lines THIS PR actually changes" — which, by construction, is what a session's own defenses are (the session changed those lines), and which excludes unrelated PRs' defenses on untouched lines of a shared file. It bounds the **existing 657 records immediately** (no write-side change needed).

### Part 2 — mirror job prerequisite (required for ANY content/ancestry approach)

The `mirror-defenses-to-pr` job (`ci.yml:361-392`) currently uses bare `actions/checkout@v4` (shallow) and fetches only the `tickets` ref. Add `fetch-depth: 0` and ensure `origin/<base_ref>` + the PR head are fetched, mirroring the `fetch-depth: 0` + base-fetch pattern every other diff-sensitive job already uses (`ci.yml:86,243,338`). Pass `--head-sha ${{ github.event.pull_request.head.sha }}` and the base. Without this, no content/line approach can compute a correct diff.

### Part 3 — observability (RC-A countermeasure)

`defense_store_list` emits a single summary line to stderr: `defense-mirror: emitted M of N candidate records (line-scoped=X, file-fallback=Y, diff-unavailable=Z)`. A silent no-op (the RC-A failure class) becomes visible. The CI step does not gate on it (advisory), but it surfaces "emitted 0 of N".

### Part 4 — independent hygiene (orthogonal, low-risk)

Drop `pr_number` from `_defense_compute_fingerprint` (`review-defense-store.sh:29-30`): the fingerprint folds in `pr_number` but suppression (`runner.py`) never reads the fingerprint, and no caller passes `--pr-number`, so it is dead, divergent state. Removing it is a zero-behavior-change cleanup that closes the latent desync (panel M2 / accuracy claim 8).

## Why this satisfies BOTH halves of the goal
- **Faithful session reflection:** a session's defense cites a line it just changed; that line is in the PR's diff → emitted. Immune to squash/rebase/force-push/shallow-clone (it compares against the PR's NET diff — exactly what merges).
- **No accumulation:** an unrelated PR's defense cites a line THIS PR did not change → not in the diff → not emitted. Tighter than file-overlap; bounds the existing corpus now.

## Failure-mode posture
- Diff computable: line-scoped (the bound applies).
- Diff not computable (missing base/head, fetch gap): `::warning::` + fall back to file-overlap (today's behavior — additive, never worse, and visible).
- Fail-soft everywhere; one mechanism, one script (`defense_store_list`) + one CI-wiring change. No write-side change.

## Test plan (TDD)
- A defense citing a line IN the PR's changed hunks → emitted; citing a line in the same file but NOT changed → suppressed (the core bound).
- A `file_paths`-only record → file-overlap fallback (documented).
- `--head-sha` absent / diff fails → ::warning:: + file-overlap (today's behavior), asserted.
- Regression: existing mirror tests still pass.
- Hygiene: fingerprint no longer varies with pr_number; suppression unaffected (it ignores the fingerprint).
