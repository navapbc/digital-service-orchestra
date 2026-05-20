# Version-Bump Design: Bump-Before-Final-Review + SC5(c) Carve-Out Cross-Reference

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-05-19

Technical Story: 0c55-1103-a14d-431e (S5) — Version-bump shift to source-branch commit (with provenance trailer + sequencing)
Epic: f691-681e-0db9-4260 — Restore per-sub-PR LLM review + provenance-narrowed integration review + chunked oversized-PR fallback + merge-pipeline guards

## Context and Problem Statement

Before epic f691-681e, the merge pipeline committed the version-bump directly to `main` after merging the session branch, outside any PR. This created two problems:

1. **Post-merge main mutation**: a commit landed on `main` that was never part of any PR, never reviewed, and never visible in the branch protection check log for that merge. Subsequent `git pull origin main` in other worktrees pulled an extra unreviewed commit.
2. **Trailer/provenance gap**: the version-bump commit carried no `DSO-Story-Merge:` trailer and no sub-PR provenance, causing `verify-session-provenance.sh` to treat it as unprovenanced on future sessions that branched from it.

Epic f691-681e SC4(b) requires that `merge-to-main-pr.sh` commit the version-bump on the **source branch's HEAD** before merge. This means the version-bump is visible in the final PR review, travels through the same CI checks as the rest of the branch, and lands on `main` as part of the merge commit rather than as a standalone direct-to-main push.

Two timing approaches were identified; this ADR documents the tradeoff analysis and the chosen decision.

## Decision Drivers

- The version-bump commit must be part of the PR so that it is visible to branch protection checks and the final human reviewer.
- The chosen timing must not undermine SC5(a): the manual `dso:code-reviewer-standard` (opus) review of S1's sub-PR must carry a meaningful signal — the review must fire on a stable diff, not on a diff that shifts immediately after review.
- Re-review dismissal via GitHub's "Changes requested" → "Dismissed on push" path is a valid fallback for Approach B but is considered a cost, not a feature.
- The version-bump diff is always one line in one file (`VERSION` or equivalent); reviewer-fatigue cost is bounded and predictable.

## Considered Options

### Approach A — Bump-BEFORE-final-review (chosen)

`merge-to-main-pr.sh` commits the version-bump on the source branch before requesting the final human review (or before the final CI run that gates auto-merge). The reviewer sees the complete diff including the version-bump line.

**Consequences (Approach A):**
- Reviewer always sees the full PR diff, including the version-bump, in one pass.
- No post-review push occurs after the reviewer approves; branch protection re-review-dismissal is not triggered.
- If CI re-runs occur after the version-bump commit (e.g., flaky test retry), the version-bump commit is already in place — no sequencing race.
- Every PR review includes a one-line version-bump diff at the tip. Reviewer-fatigue cost is minimal and predictable.

### Approach B — Bump-AFTER-final-review, accepting re-review-dismissal

`merge-to-main-pr.sh` requests the final review, waits for approval, commits the version-bump to the branch tip, then auto-merges. If branch protection requires re-review after a push, the existing approval is dismissed and a re-review is required.

**Rejected.** This approach undermines SC5(a) signal integrity in two ways: (1) the final approval covers a diff that does not match what will actually merge — the version-bump commit is appended after approval; (2) if branch protection's "dismiss stale reviews on push" is enabled, the pipeline stalls waiting for a re-approval on a one-line diff, adding latency to every session→main merge with no safety benefit. Accepting re-review-dismissal as a routine event normalizes the "approval is for a different diff" pattern, which is the failure mode SC5(a) is designed to prevent.

### Approach C — Two-PR pattern

Submit a first PR containing the session branch content, merge it, then submit a second PR containing only the version-bump commit. Both PRs receive independent review and CI runs.

**Rejected.** Over-engineering relative to the problem. The version-bump is a single deterministic line change; a dedicated PR imposes the full PR lifecycle (CI queuing, review request, branch protection) on a change that carries no semantic risk. This conflicts with the single-trailer model (DSO-Story-Merge trailers are written by `merge-story-branch.sh` at sub-PR merge time; a separate version-bump PR has no story it belongs to). The two-PR pattern also increases the wall-clock time for every session→main merge, blocking dependent worktrees longer.

## Decision

**Chosen: Approach A — bump-before-final-review.**

`merge-to-main-pr.sh` runs the version-bump step before the final CI trigger that gates merge. The resulting diff visible to the final reviewer and to branch protection checks includes the version-bump commit at the tip of the source branch.

The version-bump commit carries a `DSO-Version-Bump:` trailer (written by `merge-to-main-pr.sh`) to distinguish it from story-content commits in provenance verification. `verify-session-provenance.sh` recognizes the `DSO-Version-Bump:` trailer as a provenanced mechanical commit (no sub-PR required).

## Consequences

### Positive

- The PR diff is stable before final review: no post-approval mutation occurs, preserving SC5(a) signal integrity.
- Branch protection re-review-dismissal is never triggered by the merge pipeline as a routine event.
- The version-bump commit lands on `main` as part of the merge commit, not as a direct push; `git pull origin main` in other worktrees fetches it with the rest of the merge.
- `verify-session-provenance.sh` treats the version-bump commit as provenanced via the `DSO-Version-Bump:` trailer, preventing spurious exit-1 (unprovenanced) on the first session that branches from the newly bumped `main`.

### Negative

- Every PR review includes a one-line version-bump diff at the tip. A reviewer who approves a PR and then sees it merge with a different tip SHA (due to CI re-runs rebasing the branch) may be confused — mitigated by using merge commits (not rebase) as the merge strategy, preserving the version-bump commit's position.
- `merge-to-main-pr.sh` must sequence the version-bump step correctly: it must occur after any sub-PR story-content commits are merged into the session branch but before the final CI trigger. An incorrect sequencing (bump before all sub-PR merges are complete) would require a re-bump.

### Neutral

- The version-bump commit appears in `git log` on the source branch before the merge commit. Downstream tooling (e.g., changelog generators) that read `main` history will see the bump commit as a source-branch commit rather than a post-merge commit; this is semantically correct and no different from how any other pre-merge commit appears.
- `verify-session-provenance.sh`'s exit-code semantics (0/1/2 + exit 3 from SC2/S7) are unchanged by this decision. The `DSO-Version-Bump:` trailer recognition is an additive pattern in the provenance checker, not a new exit code.

## SC5(c) Carve-Out Cross-Reference

S3 (7462-6284-9dd3-4f2c) modifies `ci.yml:llm-review` to conditionally skip LLM dispatch when all commits on the session branch are provenanced. This is a companion contract-preserving change to S5's version-bump design:

- After S5, the version-bump commit carries a `DSO-Version-Bump:` trailer that `verify-session-provenance.sh` accepts as provenanced. Without this trailer, the version-bump commit — which has no sub-PR review — would cause `verify-session-provenance.sh` to exit 1 on every session→main PR, forcing the full-diff LLM review path.
- S3's provenance skip fires on exit 0 from `verify-session-provenance.sh`. S5's trailer ensures the version-bump commit does not prevent exit 0 for otherwise-provenanced sessions.

These two decisions (S5's bump-before-review + `DSO-Version-Bump:` trailer; S3's provenance skip) are designed as a unit. Neither is complete without the other.

The SC5(c) carve-out that authorizes S3's behavior change is fully documented in `docs/adr/0015-sc5c-integration-review-provenance-skip-carve-out.md`. This ADR cross-references it rather than repeating the reasoning:

- S3's skip is a **contract-preserving behavior change** (not a regression) because sub-PR reviews (S1) cover all story-content commits before the session→main PR is opened.
- S5's version-bump trailer closes the only gap in that coverage: the one mechanical commit on the session branch that has no sub-PR review.

## References

- S5 (0c55-1103-a14d-431e) — version-bump implementation on source branch
- S3 (7462-6284-9dd3-4f2c) — integration review provenance skip
- S7 (1608-4d8c-da53-47bc) — runner large-diff fallback; adds exit code 3 (OVER_BOUND) to `verify-session-provenance.sh`'s exit-code contract
- ADR 0015 (`docs/adr/0015-sc5c-integration-review-provenance-skip-carve-out.md`) — SC5(c) carve-out for S3's contract-preserving behavior change
- ADR 0012 (`docs/adr/0012-merge-to-main-dispatcher-pattern.md`) — merge-to-main dispatcher pattern; `merge-to-main-pr.sh` is the dispatcher modified by S5
- Epic f691-681e-0db9-4260 SC4(b) definition: `merge-to-main-pr.sh` commits the version-bump on the source branch's HEAD before merge
- Epic f691-681e-0db9-4260 SC5(c): modifications to existing CI/review workflows are additive in the behavior-preservation sense
- SC5(c) carve-out epic comment: f691-681e-0db9-4260 comment (timestamp 2026-05-19): "S3's integration-review skip on provenance is classified as a CONTRACT-PRESERVING BEHAVIOR CHANGE, not a pure additive change"
