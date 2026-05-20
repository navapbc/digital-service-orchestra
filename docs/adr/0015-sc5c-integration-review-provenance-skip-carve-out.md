# SC5(c) Carve-Out: Integration-Review Provenance Skip Is a Contract-Preserving Behavior Change

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-05-19

Technical Story: 7462-6284-9dd3-4f2c (S3) — Integration review provenance skip + ci.yml filter rewrite
Epic: f691-681e-0db9-4260 — Restore per-sub-PR LLM review + provenance-narrowed integration review

## Context and Problem Statement

Epic f691-681e SC5(c) states a behavior-preservation additive constraint: modifications to existing CI/review workflows may NOT delete jobs or narrow pull_request branch filters — only additive changes are permitted (broadening base-ref coverage, adding provenance-aware skip paths inside existing gating). The intent is to prevent silent removal of review coverage.

S3 adds a provenance-aware skip path inside the `ci.yml:llm-review` job. Before S3, `llm-review` unconditionally dispatched the LLM reviewer on every session→main PR. After S3, `llm-review` calls `verify-session-provenance.sh` first; if all commits are provenanced via sub-PR reviews, it emits a `skipped` check-run conclusion instead of dispatching the LLM reviewer.

This raises the question: is the S3 skip path a violation of SC5(c)?

## Decision Drivers

- SC5(c)'s behavior-preservation rule is designed to prevent regressions — specifically, to prevent previously-reviewed code from flowing to main without review.
- Before S1 (per-sub-PR review workflow), the integration review at `ci.yml:llm-review` was the ONLY internal LLM review gate. Skipping it would have been a regression.
- After S1, every story PR (sub-PR) receives an internal LLM review via `.github/workflows/review-sub-pr.yml`. A commit that reaches the session→main PR has already been reviewed at sub-PR time.
- The cumulative-diff integration review (pre-S3) fails closed on session→main PRs above ~6000 LOC — the root cause of bug 1624-5fb9 and bugs 576b-a6c7 / b1a7-20bf. This failure mode blocks epics from merging and is the primary regression this epic is fixing.

## Decision

**The S3 provenance skip is classified as a CONTRACT-PRESERVING BEHAVIOR CHANGE, not a behavior regression, and is accepted under SC5(c) as a named carve-out.**

The carve-out applies because all four of the following conditions are satisfied:

1. **Review coverage is preserved.** A commit that passes the provenance check has been reviewed at sub-PR boundary by `review-sub-pr.yml`. Skipping the integration-level LLM dispatch does not remove review coverage — it avoids redundant re-review of already-reviewed commits.

2. **The skip path is liveness-asserted, not silent.** Exit 0 from `verify-session-provenance.sh` triggers a check-run conclusion of `skipped` with an explicit summary message: `"Covered by sub-PR reviews: PR#<num>:<sha>, ..."`. The coverage assertion is machine-readable, auditable in the GitHub Actions UI, and written to the CI artifact directory.

3. **The fallback is safe.** Any commit that cannot be confirmed as provenanced (exit 1 — unprovenanced; exit 2 — budget exhausted) routes to the full-diff LLM review path. The skip only fires when provenance is positively verified. There is no silent pass path.

4. **The alternative is the regression.** Unconditionally running integration review on the cumulative diff is the behavior that causes the 6000+ LOC failure closed. The pre-S3 behavior is itself a regression (bug 1624-5fb9); SC5(c) is not intended to protect regressive behavior from being fixed.

## Considered Options

### Option A — Do not skip; require the integration reviewer to handle large diffs

Rejects S3's skip path entirely. The integration review runs on every session→main PR. SC2's chunking fallback (S7) handles oversized diffs.

**Rejected.** SC2/S7 is a separate story that adds chunking for oversized diffs. S3 and S7 address orthogonal failure modes: S3 fixes redundant re-review; S7 fixes large-diff failure-closed. Blocking S3 on S7 land would delay the unblock of epics cf7b-86a9, f27a-3c6a, fb32-215c. Additionally, even with S7 chunking, running the integration reviewer on commits already covered by sub-PR reviews is wasteful and adds latency to every session→main merge.

### Option B — Require the skip to be opt-in via config flag

Adds a `review.provenance_skip_enabled` boolean config key. When false (default), integration review always runs. When true, the skip path is active.

**Rejected.** A config gate introduces a second source of truth for whether the skip is active, creates a misconfiguration failure mode (S1 deploys, S3 ships, but the config key is never toggled), and undermines SC5(c)'s intent of a deterministic behavior-preservation audit trail. The skip should be unconditionally active once sub-PR review (S1) is deployed — there is no valid scenario where a project has S1 active but wants to redundantly re-review already-covered commits at integration time.

### Option C (chosen) — Accept as contract-preserving carve-out with explicit liveness assertion and safe fallback

The skip is unconditional when provenance is verified. Liveness is asserted via a machine-readable check-run conclusion. The fallback to full-diff is automatic on any provenance uncertainty. Document the carve-out in this ADR and cross-reference from CI-INTEGRATION.md.

## Consequences

### Positive

- Session→main PRs where all commits are provenanced complete without LLM dispatch, eliminating the 6000+ LOC failure-closed class.
- Review coverage is maintained: sub-PR reviews cover each story's changes; the integration review covers cross-story interaction surfaces (files modified by ≥ 2 sub-branches) when provenance cannot be confirmed.
- The liveness assertion is auditable: the check-run summary lists every covered sub-PR by number and SHA, giving human reviewers a trace of what was covered.
- Downstream epics (cf7b-86a9, f27a-3c6a, fb32-215c) are unblocked once this epic merges.

### Negative

- If `verify-session-provenance.sh`'s exit-code contract drifts (e.g., future code changes alter exit semantics), the skip may fire incorrectly. This risk is mitigated by `tests/scripts/test-verify-session-provenance-contract.sh`, which locks the 0/1/2 exit-code semantics and must pass in CI.
- Commits added directly to the session branch (e.g., merge commits, version-bump commits) must carry a `DSO-Story-Merge:` trailer to be treated as provenanced. Commits without trailers fall through to exit 1 → full-diff review. This is intentional and documents the provenance requirement for all non-PR commits.
- The OVER_BOUND path (exit 3) routes to admin/FP-recovery rather than LLM review. This is a separate escalation path introduced by SC2/S7 and is not part of the SC5(c) carve-out; it is documented here for completeness.

### Neutral

- The `ci.yml:llm-review` job structure is unchanged: same step name, same position, same trigger conditions (base_ref == main). Only the step's `run:` command changes from a direct `ci-llm-review-runner.sh` invocation to `llm-review-dispatch-or-skip.sh`. The required-check name is stable.
- `verify-session-provenance.sh` itself is not modified by S3 (consumed only, not changed).

## References

- SC5(c) carve-out announcement: f691-681e-0db9-4260 epic comment (timestamp 2026-05-19)
- Integration-review provenance skip documentation: `${CLAUDE_PLUGIN_ROOT}/docs/CI-INTEGRATION.md` — "llm-review-dispatch-or-skip.sh — provenance-aware dispatch wrapper" section
- Verifier exit-code contract test: `tests/scripts/test-verify-session-provenance-contract.sh`
- Dispatch wrapper: `${CLAUDE_PLUGIN_ROOT}/scripts/llm-review-dispatch-or-skip.sh`
- Provenance verifier: `${CLAUDE_PLUGIN_ROOT}/scripts/verify-session-provenance.sh`
- Bug 1624-5fb9: integration scope short-circuit (regression being fixed)
- Bugs 576b-a6c7, b1a7-20bf: scope regression from story 20d7 (covered by SC1 + this carve-out)
- ADR 0013 (`docs/adr/0013-verifier-severity-authority.md`) — verifier severity authority; not affected by this decision
