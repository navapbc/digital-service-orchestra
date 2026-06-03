# GitHub Merge Queue for the staged→main Promotion

> **⛔ SUPERSEDED (2026-06-03) — NOT ADOPTED. See [ADR-0020](0020-two-tier-hardening-over-merge-queue.md).**
> Pre-cutover live validation proved GitHub Merge Queue cannot ruleset-enforce a content-aware LLM review: MQ evaluates required checks on the `merge_group` candidate, and `llm-review` (event-guarded to `pull_request`) never reports there → the queue entry times out and is evicted; you cannot configure a separate required-checks list for the queue vs the PR. MQ-1…MQ-5 were implemented (all flag-gated OFF) and have been **rolled back** (code preserved in git history); the project adopts the named fallback — harden the two-tier flow (ADR-0020). This document is retained as the historical decision record.

- Status: **superseded by ADR-0020** (was: accepted)
- Deciders: @joeoakhart
- Date: 2026-06-02
- Recommendation: **GO (scoped)** — ratified 2026-06-02 after a 4-stream due-diligence pass (MQ spike, scenario stress-test, historical re-baseline, prior-art convergence) and a live `merge_group` empirical test (PRs #544/#545, torn down). — adopt GitHub Merge Queue for the `staged-* → main` promotion, keep the LLM review on the sub-PR, make the deterministic Goal-1 backstops required on `merge_group`, and retire the bespoke staged-branch/PR1/PR2/resume machinery.

Technical Story: CI/PR-process review (this session). See `docs/designs/ci-pr-process-remediation-proposal.md` (v2) §3 P3.
Supersedes-the-implicit-choice-in: `docs/handoff/workflow-stability-plan-v4-handoff.md` §5 ("Diverge: mature merge queues re-validate the combined state … we review the delta").

## Context and Problem Statement

The pipeline promotes work to `main` through a bespoke **two-tier flow**: a per-story sub-PR (LLM-reviewed via `review-sub-pr`) merges into a per-session `staged-*` branch, which is then promoted to `main` via a second PR (`llm-review` + `check-staged-head` + the Goal-1 backstops). The orchestrator (`merge-to-main-pr.sh`, ~3,214 lines) creates the staged ref, opens PR1 and PR2, queues auto-merge, waits via `wait-for-pr.sh`, and carries an intricate resume/state machine.

A two-reviewer audit (convergent findings, blue-team verified) surfaced that the staged→main review is **delta-only**: when every commit is provenanced (each sub-PR passed review), the integration `llm-review` SKIPs, and `verify-session-provenance.sh` subtracts covered files. Consequently:

- **CF-2 / CF-9** — a cross-sub-PR *combination* conflict (sub-PR A renames `foo`; sub-PR B calls `foo`; each passes in isolation) can reach `main` with **zero combined-state review**. The industry term is **merge skew / semantic conflict**.
- **CF-5** — concurrent sessions create independent staged refs from `origin/main` HEAD with no serialization; the second to promote carries a stale base.
- **CF-3 / CF-4** — the orchestrator's resume/state complexity (mid-run `BRANCH` mutation shifting the state-file path; ~10 incident-tagged resume patches) is the pipeline's largest maintainability and reliability liability.

**Every mature gating system re-validates the *combined* candidate before trunk** — this is the "Not Rocket Science Rule" (bors), and is implemented by Zuul, Prow/Tide, Mergify/Aviator, and **GitHub Merge Queue (MQ)**. Our delta-review is the deliberate *divergence* (the v4 handoff §5 concedes it and routes the gap to the W6 dangling-reference check). **GitHub Merge Queue was researched as prior art in the v3/v4 handoffs but never formally evaluated as an option for this pipeline** (a full ticket-corpus scan found no proposal to adopt it; no ADR weighs it). This ADR closes that gap.

## Primary goal (the invariant any design must preserve)

**All code passes LLM review before it merges to `main` — but the LLM reviews the smaller per-story sub-PR diffs, never the larger feature/session-level diff that actually merges to `main`.** The provenance machinery exists to realize exactly this: review each small diff once at sub-PR time, and skip re-reviewing the large combined diff at promotion time (cost + "lost-in-the-middle" recall both scale badly with diff size). Any proposed change must keep this property.

## Current workflow — which checks run when

The review split is driven by `base_ref` conditions in `.github/workflows/ci.yml`:
- **`review-sub-pr`** (the small-diff LLM review) runs iff `pull_request && base_ref != 'main'`.
- **`llm-review`** (the provenance-aware review/skip) runs iff `pull_request && base_ref == 'main'`.
- **`check-staged-head`**, **`review-coverage-invariant`**, **`dangling-references`** are separate workflows triggered `on: pull_request: branches: [main]` — i.e., only on PRs *targeting* `main`.
- **Deterministic gates** — `Detect Changed Paths`, `Actionlint`, `ShellCheck`, `Lint Python (ruff)`, `Hook Tests`, `Script Tests`, `Validate required-checks`, `Ticket tests` (×3 platforms), `Portability Smoke`, `CI Python Skills`, `ruleset-design-invariants`, CodeQL/Analyze — run on every PR.
- **`merge-pipeline-checks`** runs on `base==main` or `session*/bug-batch/worktree-*` (not `staged-*`); **`mirror-defenses-to-pr`** runs on `base==main` only.

**Stage 1 — Sub-PR (PR1: `worktree/feature → staged-*`), gated by the sub-PR ruleset (16961402, requires `review-sub-pr`):**
Runs the deterministic gates **+ `review-sub-pr`** — the LLM reviews the *small sub-PR diff*. Does **not** run `llm-review`, `check-staged-head`, `review-coverage-invariant`, `dangling-references`, `mirror-defenses`, or `merge-pipeline-checks` (base is `staged-*`).
**Merge gate:** `review-sub-pr` + deterministic required checks pass → PR1 auto-merges into `staged-*`.

**Stage 2 — Promotion PR (PR2: `staged-* → main`), gated by the MAIN ruleset (15629023, 12 required checks):**
Runs the deterministic gates **+ `llm-review`** (provenance-aware → **SKIPs**, because every commit was already reviewed at sub-PR time → emits `skipped`/pass) **+ `check-staged-head` + `review-coverage-invariant` (warn) + `dangling-references` (warn) + `mirror-defenses` + `merge-pipeline-checks`**.
**Merge gate:** the 12 required checks (incl. `llm-review` [skip→pass], `check-staged-head`, deterministic) → PR2 auto-merges to `main`.

**Primary-goal realization (current):** ✅ achieved — the LLM reviews each small sub-PR diff (Stage 1); the large combined `staged→main` diff is **never** LLM-reviewed (provenance SKIP at Stage 2). **The gap:** Stage 2 therefore reviews nothing new, so a cross-sub-PR *combination* conflict has no combined-state review (CF-2/CF-9), and the deterministic combined-state checks that could catch it (`review-coverage-invariant`, `dangling-references`) are **warn-mode** (CF-1).

## Proposed workflow (Merge Queue) — which checks run when

**Stage 1 — Sub-PR (UNCHANGED):** per-story sub-PRs target the **session branch** (`STORY_PR_BASE=$SESSION_BRANCH`, base `!= main`), where the sprint's **cumulative** work accumulates in-tree (story N is built on story N-1's already-merged commits) — exactly as today. **`review-sub-pr`** LLM-reviews each *small diff*; deterministic gates. The primary-goal LLM review is untouched. **This is the load-bearing fact for the cumulative sprint model** (verified by the sprint-skill walkthrough): individual stories never PR to `main`; only the fully-accumulated session branch enters the queue. There are therefore **no stacked-PRs-to-main** and no queue-ordering of dependent stories — the MQ change is orthogonal to the per-story accumulation machinery (Phases E/F unchanged).

**Stage 2 — Promotion to `main` via Merge Queue (replaces the staged-*/PR1/PR2 dance):**
- The session branch opens **one** PR to `main` (possible only after `check-staged-head` is retired — see migration step 4; today `check-staged-head` requires the head to be a `staged-*` branch). On that PR (`pull_request`, `base==main`): the deterministic gates **+ `llm-review`** (provenance-aware → **SKIPs**, all commits provenanced at sub-PR). The LLM does **not** review the large combined diff.
- The PR is added to the **merge queue**. GitHub builds the `merge_group` candidate (current `main` + this PR; at **`max-PRs-per-merge=1`** the candidate = this PR on current `main`).
- On **`merge_group`**: the **deterministic required checks re-run on the combined candidate** — `Actionlint`, `ShellCheck`, `Lint Python`, `Hook Tests`, `Script Tests`, `Ticket tests`, **`review-coverage-invariant` (enforce)**, **`dangling-references` (enforce)**. The **LLM review does NOT run on `merge_group`** — it stays on the sub-PR.
- MQ fast-forwards to `main` only when the `merge_group` checks pass.

**Primary-goal realization (proposed):** ✅ **preserved identically** — the LLM reviews small sub-PR diffs (Stage 1); the large combined diff is **never** LLM-reviewed (provenance SKIP on the PR; LLM not wired to `merge_group`). What changes: the **combined-state guarantee now comes from the *deterministic* checks re-run on the true merge candidate** (`merge_group`), which is strictly stronger than today's warn-mode/skip — closing CF-2/CF-9 for the deterministic class **without** adding any LLM cost to the promotion path.

| | Current | Proposed (MQ) |
|---|---|---|
| LLM review of small sub-PR diff | `review-sub-pr` on Stage-1 PR | `review-sub-pr` on Stage-1 PR (unchanged) |
| LLM review of large combined diff | SKIP (provenance) | SKIP (provenance); not on `merge_group` |
| Combined-state validation | warn-mode invariants on PR2; LLM skips | **deterministic required checks on the true `merge_group` candidate** |
| Serialization of promotions | bespoke per-session `staged-*` + orchestrator | GitHub-managed queue |
| Promotion mechanism | PR1→staged + PR2→main + resume machinery | one PR → queue → fast-forward |

## Decision Drivers

- **Combined-state guarantee (Goal-3).** Close the merge-skew hole structurally rather than approximating it with a bespoke, warn-mode, textually-imprecise symbol grep.
- **LLM cost.** LLM review cost scales with diff size; we must not re-review the full combined diff on every promotion. The delta-review cost win (review each small sub-PR once) must survive.
- **Autonomous, multi-session operation.** No human reviews every PR; the machine checks *are* the gate. Parallel worktree sessions race on promotion. Serialization must be reliable without a bespoke lock.
- **Maintainability.** A 3,214-line bespoke serialization orchestrator reimplements infrastructure that MQ/bors/Tide provide off-the-shelf (serialization, speculative combined-state testing, eviction/regroup).
- **Identity-based containment (Goal-4).** The agent runs as a non-bypass identity; only a named human may override. Any change must preserve this.
- **Conformance.** Prefer convergent industry practice where our constraints allow.
- **Interaction with the in-flight Goal-1 enforce go-live.** The enforce flip (`32819d767f`, committed-but-unmerged) and its hardening (proposal P0) decide *which* checks are required and in *what mode*; MQ decides *where* they run (`merge_group`). Deciding MQ first avoids wiring the enforce gates twice.

## Decision

**Adopt GitHub Merge Queue for the `staged-* → main` promotion (recommended GO), scoped as follows:**

1. **Enable MQ on `main`** via the existing MAIN ruleset (ruleset support for MQ is GA). **`max-PRs-per-merge = 1`** initially — this sidesteps the 2026-04 multi-PR-squash-revert incident and makes the combined candidate trivially equal to "this PR on current `main`."
2. **Keep the LLM review as a required check on the sub-PR** (the `pull_request`, `base != main` path). The paid, non-deterministic LLM call stays off the queue's eviction-amplified hot path. **Do not** require LLM review on `merge_group`.
3. **Make the deterministic Goal-1 backstops (`review-coverage-invariant`, `dangling-references`) — plus the existing deterministic gates (Shellcheck, Actionlint, ruff, Hook/Script Tests) — required on `merge_group`.** MQ runs them on the *true* combined candidate, strictly stronger than today's staged-head approximation. This is the natural home for the proposal's P0 enforce flip.
4. **Preserve identity-based containment unchanged** — adding to the queue needs only write access (the agent qualifies); the only queue-skip is the admin web-UI "merge without waiting," already reserved to the named human bypass actor.
5. **Retire the bespoke promotion machinery:** the `staged-*` intermediate, PR1/PR2, `_phase_staged_intermediate`, `_create_staged_ref`, `_resume_should_advance_to_staged`, most of the resume/state logic, `check-staged-head`, and the staged-* ruleset. The session branch is added to the queue directly; `wait-for-pr.sh` simplifies to "wait until MERGED or evicted."

**This decision does NOT eliminate the proposal's P0 hardening** — MQ only relocates *where* the Goal-1 checks run. P0.a (ledger/API + budget-convergence), P0.b (`sg` dangling matcher + reference breadth), and **P0.d (the admin-exemption ledger, S-11)** remain prerequisites: MQ does not make a warn-mode/imprecise/wedge-prone check trustworthy.

## Considered Options

### Option A — Keep the bespoke two-tier; harden only (proposal P0–P2, no MQ)

**Rejected as the primary path (acceptable as the fallback if the spike's verification items fail).** Hardening + enforcing `dangling-references` + W6(c) closes the *symbol-rename* subset of merge skew, but — per the prior-art research — combined-state *testing* catches a broader class (any behavioral/semantic interaction, not just symbol references). Keeping delta-only means **accepting a named residual exposure to non-symbol semantic conflicts** that no comparator accepts. It also retains the full CF-3/CF-4/CF-5 maintenance and reliability surface (the 3,214-line orchestrator + the concurrency race). This is more total code, weaker guarantee, and divergent from universal practice.

### Option B — Keep the staged flow but run the full LLM review on the combined staged state every promotion

**Rejected.** This is the "re-validate combined state" guarantee bought at the worst price: a paid, non-deterministic LLM call on the promotion hot path, multiplied by MQ-style eviction/regroup if ever queued. It defeats the delta-review cost win that is the whole rationale for the provenance machinery, and contradicts the proposal's explicit YAGNI guard. The combined-state guarantee should come from *deterministic* checks, not a re-run of the LLM.

### Option C (chosen) — GitHub Merge Queue for staged→main, LLM review on the sub-PR, deterministic backstops on `merge_group`

**Chosen.** Inherits the combined-state re-test of *deterministic* required checks from GitHub-managed infrastructure (closing CF-2/CF-9 for the deterministic class), serializes promotions (CF-5), and retires the bespoke staged/PR1/PR2/resume machinery (CF-3/CF-4) — while preserving the LLM delta-review cost win (sub-PR only) and identity containment (Goal-4). It is the industry-convergent shape (every gating system re-tests the combined candidate) adapted to our LLM-cost and autonomy constraints. The deterministic `dangling-references`-on-`merge_group` is the proportionate substitute for "LLM on the combined state" — the same conclusion the proposal reached independently.

### Option D — Third-party merge automation (Mergify / Aviator / bors-ng)

**Rejected for now (revisit only at scale).** Mergify/Aviator add batching, bisect-on-failure, and richer policies, but introduce a third-party dependency, cost, and a new trust/identity surface. Our promotion volume (a few sessions/day, far under MQ's ~48-PR/day serial ceiling) does not justify them. GitHub-native MQ keeps the containment model and tooling surface minimal. Reconsider if throughput outgrows serial MQ.

## Consequences

### Positive
- **Closes CF-2/CF-9 structurally** for deterministic checks: the required checks (including the hardened `dangling-references`) run on the true combined candidate before fast-forward. The named non-symbol-semantic-conflict residual shrinks to "behaviors not covered by any deterministic check," which is the same residual any test-gated merge queue accepts.
- **Resolves CF-5** (serialization is GitHub-managed; the bespoke lock is moot) and **CF-3/CF-4** (retires staged-ref creation, PR1/PR2, the `BRANCH`-mutation root cause, and most resume conditionals — making P3.b's orchestrator refactor largely unnecessary).
- **Conformance:** aligns the promotion gate with universal practice (bors/Zuul/Tide/MQ) while preserving the two constraint-driven bespoke wins (LLM delta-review for cost; identity containment for autonomy).
- **Smaller drift surface (post-migration):** deleting the staged-* ruleset + `check-staged-head` removes `ruleset-design-invariants` moving parts — **but only after** the invariant test (I1/I2/I6) and `required-checks.txt` are rewritten in lockstep (migration step 4). Done out of order it deadlocks promotion on a permanently-red required check, so this is a net simplification *only* if sequenced correctly.

### Negative / Risks
- **Does NOT fix CF-1 hardening.** P0.a/P0.b/P0.d remain prerequisites; MQ relocates the checks to `merge_group` but does not make them trustworthy. The admin-exemption ledger (S-11) is still required before enforce.
- **`merge_group` trigger migration is all-or-nothing:** every required workflow must add the `merge_group` trigger simultaneously, or the queue silently rejects PRs (checks never report). This is the most common MQ adoption failure.
- **Third ref context:** the LLM-review trigger is keyed `base_ref == main` vs `!= main` (v4 CS-8). `merge_group` is a third context; the trigger and provenance logic must be verified to behave correctly (the LLM review should fire on the sub-PR, *not* the merge group).
- **Version bump:** must remain a pre-queue feature-branch commit (proposal P1.b / `6c65a4f80c`); batching >1 PR/merge would require moving the bump to post-merge reconciliation (deferred — we run `max-PRs-per-merge = 1`).
- **Migration blast radius:** retiring `merge-to-main-pr.sh`'s promotion phases is a large change to the most load-bearing script; must be guarded by the existing gh-stub integration tests plus new `merge_group` scenarios, and rolled out behind a config/branch.
- **Known GitHub MQ sharp edges:** the 2026-04 multi-PR squash-revert bug (mitigated by `max-PRs-per-merge = 1`); CODEOWNERS-vs-bypass-actor evaluation quirk (we do not use CODEOWNERS — keep it that way); `gh-readonly-queue/*` branches are unprotectable (benign — GitHub-managed, short-lived, agent has no reason to push to them).
- **Eviction CI amplification:** at `max-PRs-per-merge = 1` and low volume this is negligible; at higher concurrency, flaky required checks can trigger regroup re-runs.

### Neutral
- Sub-PR `review-sub-pr` enforcement is unchanged (runs on sub-PRs, not the merge group); the `required-checks.txt` note that those checks "never run in this repo" stays valid.
- FP-recovery (`/dso:fp-recovery`) remains the escape valve for a wrongly-blocking LLM finding on a sub-PR; the merge-group path has no LLM finding to recover.

## Migration outline (if accepted)

1. **Prerequisite:** land proposal P0.a/P0.b and **P0.d (admin-exemption ledger)** — MQ does not substitute for these.
2. **Add the `merge_group` trigger to every required-check workflow/job — atomically (any omission = *silent queue rejection*).** The required set spans five workflow files: `ci.yml` (the deterministic jobs — `actionlint`, `shellcheck`, `lint-python`, `test-hooks`, `test-scripts`, and **`merge-pipeline-checks`**), `ticket-platform-matrix.yml` (the three `Ticket tests` contexts), `ruleset-invariants.yml`, plus the two backstops being promoted to enforce (`review-coverage-invariant.yml`, `dangling-references.yml`). **Concrete trap:** `merge-pipeline-checks`'s job-level `if:` currently gates *solely* on `base_ref` (`main`/`session*`/`bug-batch`/`worktree-*`) with **no `merge_group` arm**, so it would never report on the queue branch → the queue silently rejects every entry. It must gain an explicit `github.event_name == 'merge_group'` arm. Conversely, the `llm-review` job's `event_name == 'pull_request'` guard means it correctly does **not** fire on `merge_group` (this is what preserves the primary goal) — leave it as-is. **Additional rework for the two backstop workflows (de-risk spike finding):** `review-coverage-invariant.yml` and `dangling-references.yml` consume `github.event.pull_request.number` / `.head.sha` and `github.base_ref`, which are **null/empty on a `merge_group` event** — adding the trigger is necessary but **not sufficient**. Their step env must derive the head SHA from `github.event.merge_group.head_sha` (fallback), the base ref from `github.base_ref || 'main'`, and the coverage check must not hard-require a PR number (there is none on `merge_group`). Prototyped + actionlint-validated (see "De-risk spike results").
3. **Add merge-queue provisioning to `provision-ruleset.sh` (new tooling, not a toggle).** The provisioner today emits `bypass_actors` / `required_status_checks` but has **no `merge_queue` rule support** (verified — zero merge-queue keys). MQ enablement on the MAIN ruleset (`max-PRs-per-merge = 1`) therefore requires new provisioning code. **Extend the W1 round-trip drift invariant** (`test-ruleset-provisioner-roundtrip.sh` / `ruleset-design-invariants`) to cover the new `merge_queue` config so the live MQ settings are not left unmonitored by the very drift protection this ADR relies on. Make the deterministic Goal-1 backstops required on `merge_group`; keep `review-sub-pr` on the sub-PR.
4. **Rewrite `ruleset-design-invariants` + reconcile `required-checks.txt` ATOMICALLY with retiring the staged-* model — this is load-bearing.** `ruleset-design-invariants` is itself a **required** check (made so in `f008cfb359`), and `test-ruleset-design-invariants.sh` hard-asserts the exact things this ADR retires: **I1** (sub-PR ruleset `ref_name.include` == `["refs/heads/staged-*"]`), **I2** (`review-sub-pr` required on the sub-PR ruleset), **I6** (main ruleset `required_status_checks` includes `check-staged-head`). Deleting the staged-* ruleset + `check-staged-head` flips I1/I6 to FAIL → **every promotion deadlocks on a permanently-red required check.** So in one atomic change: rewrite the invariant test (drop/replace I1, I2-on-staged, I6 for the MQ model), remove `check-staged-head` from `.github/required-checks.txt`, and delete the staged-* ruleset + `check-staged-head.yml`.
5. Route the session branch into the queue directly (one PR → `main` → queue); behind a config flag, stop creating `staged-*` / PR1 / PR2 in `merge-to-main-pr.sh`; simplify `wait-for-pr.sh` to "wait until MERGED or evicted."
6. Bake in a low-risk window; verify the spike items below; then delete the retired orchestrator phases.

## Open questions / spike-verification items (must confirm before migration)

1. **Trigger correctness:** confirm the LLM review fires on the sub-PR and *not* on `merge_group`, and that `verify-session-provenance.sh` / dispatch logic behaves under the third ref context (v4 CS-8).
2. **Required-check semantics on `merge_group`:** confirm the Goal-1 backstops report correctly on the queue branch, that "Require all queue entries to pass required checks" is enabled, and that `.github/required-checks.txt` (the source the MAIN ruleset's required-membership is provisioned from) is reconciled to the exact `merge_group`-reporting set (migration steps 2 + 4).
3. **Version-bump placement under MQ** with `max-PRs-per-merge = 1`: confirm the pre-queue feature-branch bump (`6c65a4f80c`) does not collide (it shouldn't at 1-per-merge) and that bug `4668-c3ca` is not re-triggered.
4. **Containment regression test:** confirm the non-admin agent can add to the queue but cannot skip it, and the named human bypass still works.

## De-risk spike results + sprint-workflow impact

A code-level de-risk spike (prototyped on a throwaway branch, `actionlint`-validated; no live MQ enablement — that is a gated admin action) plus an opus walkthrough of `/dso:sprint` under MQ produced:

**Spike — the 4 verification items:**
1. **Trigger correctness — VALIDATED.** Adding `merge_group:` to `ci.yml`'s `on:` makes the deterministic jobs (no job-level `if:`) auto-run on the queue; `review-sub-pr` and `llm-review` (both guarded `event_name == 'pull_request'`) correctly do **not** fire on `merge_group` → the LLM never reviews the combined candidate (primary goal structurally preserved). `merge-pipeline-checks` required an explicit `merge_group` arm (the silent-reject trap — confirmed present, fix prototyped). The full prototype (ci.yml + a backstop workflow) is `actionlint`-clean. The `changes` job already forces `code_changed=true` on non-`pull_request` events, so the deterministic steps run fully on `merge_group`.
2. **`merge_group` check semantics — VERIFIED (empirical, 2026-06-02).** A throwaway `mq-spike-target` branch with a live `merge_queue` ruleset (`max-PRs=1`) + a minimal required check was exercised end-to-end (PRs #544/#545, then fully torn down — nothing touched `main`): the `merge_group` event fires on the `gh-readonly-queue/mq-spike-target/pr-N-<sha>` candidate; the required check runs and **reports on that combined candidate**; on green the queue **fast-forwards** the target (PR #544 MERGED); on a failing required check the PR is **BLOCKED and does not merge** (PR #545). The proposed workflow's `merge_group` behavior is confirmed against live GitHub, not just docs.
3. **Version-bump — analysed (= sprint friction G6).** At `max-PRs-per-merge=1` the pre-queue feature-branch bump (`6c65a4f80c`) is safe; relocate the `_phase_source_branch_version_bump` call out of the deleted staged phase into the session→main pre-push.
4. **Containment — CONFIRMED.** The live MAIN ruleset shows the named-human bypass actor as `pull_requests_only` (web-UI override); the agent identity is `never`. Under MQ, adding to the queue needs only write access (agent qualifies) and the only skip is the admin override (reserved to the human) → containment preserved.

**New spike finding (folded into migration step 2):** the two backstop workflows consume `github.event.pull_request.*`, which is null on `merge_group`; they need event-aware input plumbing (prototyped: `github.event.merge_group.head_sha` fallback; no PR number). Also flagged: `concurrency.cancel-in-progress: true` can cancel an in-flight `merge_group` check — production MQ typically scopes a separate non-cancelling concurrency group for `merge_group`.

**Sprint-workflow impact — cumulative model PRESERVED (opus walkthrough):**
- Per-story sub-PRs target the **session branch** (`STORY_PR_BASE`); stacking (story N on story N-1) is resolved **in-tree before the queue**; only the accumulated session branch enters as one PR whose `llm-review` SKIPs via provenance identically to today's PR2. **No case forces the large combined diff through LLM review.** Phases E/F (the per-story machinery) are unchanged; all the work is at the **promotion boundary**.
- **Blockers (all already named in the migration outline):** G1 — gate/short-circuit `_phase_staged_intermediate` (it hard-errors on bypass today) behind the MQ flag; G2 — **rewrite `sprint/check-ruleset-preflight.sh`** (it asserts the staged-* + main two-tier rulesets and would fail at sprint Phase A under MQ); G3 — the atomic `ruleset-design-invariants` I1/I2/I6 + `required-checks.txt` rewrite (migration step 4); G4 — the `merge-pipeline-checks` `merge_group` arm (migration step 2).
- **Friction:** G5 — sprint Phase I's `git merge-base --is-ancestor HEAD main` gate runs *after* `merge-to-main.sh` returns, but MQ fast-forwards `main` **asynchronously**; the simplified `wait-for-pr.sh` ("wait until MERGED **or evicted**") must block on the queue's terminal state so the ancestor check doesn't false-fail and re-enqueue. G8 — concurrent sprints serialize at the queue (by design; this is the CF-5 fix); ensure the wait treats "queued behind another sprint" as live, not timed-out.

## References

- Proposal: `docs/designs/ci-pr-process-remediation-proposal.md` (v2) — CF-2, CF-3, CF-4, CF-5, CF-9, S-11.
- `docs/handoff/workflow-stability-plan-v4-handoff.md` §5 (industry validation + the "Diverge" note), §9 (rejected approaches).
- `docs/adr/0012-merge-to-main-dispatcher-pattern.md` (the bespoke orchestrator's deliberate structure), `docs/adr/0015` (provenance-skip carve-out — the delta-review cost rationale).
- GitHub Docs: [Managing a merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue); [Merging a PR with a merge queue](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/incorporating-changes-from-a-pull-request/merging-a-pull-request-with-a-merge-queue).
- Combined-state norm: [Zuul gating](https://zuul-ci.org/docs/zuul/latest/gating.html); [Prow/Tide](https://docs.prow.k8s.io/docs/components/core/tide/); [bors / Not Rocket Science Rule](https://blog.janestreet.com/making-never-break-the-build-scale/); [merge skew](https://graphite.dev/guides/merge-skew).
- Sharp edges: [2026-04 squash-revert incident](https://dev.to/varshithvhegde/github-broke-git-the-merge-queue-bug-that-silently-deleted-your-code-4f7i); [CODEOWNERS bypass quirk](https://codenote.net/en/posts/github-codeowners-bypass-merge-queue-verification/); [gh-readonly-queue unprotectable](https://joshcannon.me/2025/07/03/gh-mq-branches-unprotectable.html).
- Containment best practice: [GitHub branch protection — do not allow bypassing](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).
</content>
