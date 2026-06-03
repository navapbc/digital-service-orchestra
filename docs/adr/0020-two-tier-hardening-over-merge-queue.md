# Two-Tier Flow Hardening over GitHub Merge Queue

- Status: **accepted** (supersedes ADR-0019)
- Deciders: @joeoakhart
- Date: 2026-06-03

## Context

ADR-0019 chose GitHub Merge Queue (MQ) for the `staged-* → main` promotion. Stories MQ-1…MQ-5 were implemented and landed (all flag-gated OFF / inert); MQ-6 (the live cutover) was reached only during **pre-cutover live validation**. That validation, plus targeted GitHub-docs research, surfaced a **fatal mismatch between MQ's enforcement model and a non-negotiable project requirement.**

**Non-negotiable requirement:** every commit reaching `main` must pass an LLM review that is **ruleset-enforced** (a hard GitHub gate), not merely flow-enforced.

## The MQ incompatibility (why ADR-0019 is superseded)

GitHub Merge Queue evaluates a branch's required status checks on the **`merge_group` candidate**, not the PR head, and **does not allow a separate required-checks list for the queue vs the PR** (GitHub community discussion #103114). A required check that never reports on the `merge_group` event does **not** inherit the PR pass — the entry **times out and is evicted** (`check_response_timeout_minutes`, default 60 min; GitHub docs, "Managing a merge queue").

Our `llm-review` is workflow-guarded to `event_name == 'pull_request'`, so it never reports on `merge_group` (verified live, 2026-06-03: it was **absent** on the queue candidate, PR #588). Therefore under MQ:

- Keeping `llm-review` required → **every promotion to `main` times out and evicts** (a wedged trunk for the whole team).
- A "skip-success" `llm-review` on `merge_group` → a rubber stamp that reports success without reviewing the candidate; the real review on the PR head is not what GitHub enforces under MQ → **not ruleset-enforced**.
- Re-running the LLM on the `merge_group` candidate → defeats the entire delta-review cost rationale (the primary goal of ADR-0019).

So under MQ the only ruleset-enforceable review gate on the merge candidate is a **deterministic coverage proxy** (`review-coverage-invariant`) — never the content-aware LLM review itself. **That deterministic gate works identically on the existing two-tier PR2; MQ does not buy the enforcement, it only adds an irreversible cutover, the `merge-to-main` rewrite, and a weaker posture** (it loses the two-tier flow's content-aware `llm-review` backstop, which actually re-reviews un-provenanced files — see V0.2 below).

## Decision

Adopt ADR-0019's named fallback — **Option A: keep the two-tier flow, harden it.** Specifically:

1. Roll back the MQ changes (MQ-1…MQ-5 + hardening) surgically — the flag-gated paths are dormant code; deleting them removes confusion without changing live behavior. Keep ADR-0019 annotated as superseded.
2. Land the P0 prerequisites **S-11** (admin-exemption ledger), **CF-6** (coverage-invariant cache-key/backoff/budget), **CF-8** (sg-based dangling matcher).
3. **Enforce-flip** `review-coverage-invariant` + `dangling-references` on the staged→main PR2 (add to `required-checks.txt` + re-provision the live `main` ruleset) — this closes the merge-skew gap CF-2/CF-9 with **deterministic** combined-state checks, while keeping the existing ruleset-enforced, content-aware `llm-review` gate untouched.

Full plan: `docs/handoff/option-a-pivot-plan.md`.

### Review-semantics decision (E1, decided 2026-06-03)

Two adversarial review passes established that the requirement is not met today (the enforcement chain is a conjunction of independently-skippable required checks) and that genuine closure forks on one decision: does "every commit reviewed" mean per-SHA ("rode through a PR whose review check passed") or per-file ("every changed file's content was reviewed")? Per-file is unbuildable with today's plumbing (review diff-scope is ephemeral; no `{check_run → reviewed_file_set}` evidence artifact exists).

**Decision: per-SHA coverage + a TIGHTENED allowlist (path #2).** Keep the existing per-SHA coverage mechanism, but shrink the review-gate allowlist so only genuinely-inert artifacts skip review (images, lockfiles, generated files). Anything that carries behavior-bearing content — `docs/**`, skills, behavior-driving config — becomes **reviewable** (it currently skips via the allowlist; for an agentic codebase where docs/skills drive agent behavior, an un-reviewed instruction surface is an attack vector). This closes the practical allowlist-laundering risk (C2) without the per-file evidence epic.

**Ticket-data exclusion (load-bearing carve-out):** commits whose diff is **entirely within `.tickets-tracker/**`** (the event-sourced ticket store; the orphan `tickets` branch is never merged to a project PR) are **excluded from review AND from the coverage-invariant walk** — they are machine-generated ticket state, not project code, and not subject to review. The exemption MUST be **diff-scoped evidence** (the commit touches ONLY `.tickets-tracker/**`), never a trailer/self-attestation (the v4 fabricated-trailer lesson): a commit mixing a ticket change with any code/doc file is NOT exempt and requires review. This both honors "ticket commits aren't reviewable" and prevents the per-SHA gate from fail-closing (wedging) on legitimate ticket-sync commits. <!-- # tickets-boundary-ok -->

Consequence: A-4.5 collapses from a multi-story per-file-evidence epic to a bounded build — an always-runs, fail-closed summary gate wrapping the existing per-SHA coverage invariant + the exit-78 fail-closed-with-retry fix + the allowlist tightening + the ticket-diff-scoped exemption.

## Experimental verification results (2026-06-03, against live GitHub)

All Phase-0 verifications were run before adopting the plan. Evidence below.

| ID | Result | Evidence |
|----|--------|----------|
| **V0.3a** — coverage gate precondition path in enforce mode | **FAIL (hole confirmed — must fix before enforce-flip)** | `review-coverage-invariant.sh` returns **exit 78** on a token blip (`PRECONDITION_NOT_MET: cannot resolve GH_REPO` with an invalid token; also "gh not in PATH"). The workflow wrapper `review-coverage-invariant.yml:70-75` maps **exit 78 → `exit 0` UNCONDITIONALLY** (not gated on `DSO_COVERAGE_INVARIANT_MODE`). So after the enforce-flip, a transient API/token failure makes the "airtight" gate silently **green**. |
| **V0.3b** — coverage fail-closed on an unreviewed commit | **PASS** | enforce mode + an unreviewed SHA → **exit 1** (`FAIL_CLOSED <sha> — could not confirm review`). warn mode + same → exit 0 (logs only). The *script* is correctly fail-closed; the hole is purely the wrapper (V0.3a). |
| **V0.3c** — no false wedge on a clean range | **PASS** | enforce mode, `HEAD == origin/main` (empty range) → exit 0 (`ok (no commits in …)`). |
| **V0.2** — `llm-review` re-reviews un-provenanced files (content-aware backstop is real) | **PASS** | `llm-review-dispatch-or-skip.sh`: `unprovenanced-shas.txt` non-empty → **exit 1 → invokes `ci-llm-review-runner.sh`** (a real review of the unreviewed commits); both-empty + marker → exit 0 skip; **marker-absent → ERROR exit 1** (explicit anti-silent-skip guard, bug-class 8a77). This is the property MQ loses and Option A preserves. |
| **V0.6** — live `main` required set == `required-checks.txt` | **PASS** | live ruleset 15629023 required contexts exactly equal the 12 non-comment lines of `required-checks.txt` (incl. `llm-review`, `check-staged-head`, `ruleset-design-invariants`). |
| **V0.1** — two-tier `merge-to-main` works end-to-end (flag OFF) | **PASS (demonstrated)** | MQ-2…MQ-5 + the C2/N1 hardening all landed on `main` this session via the two-tier flow (PR1 `review-sub-pr` → auto-merge → PR2 `llm-review` provenance-skip → fast-forward); most recent PR #590 → #591. |
| **V0.7** — zero live MQ residue | **PASS** | only 2 rulesets live (DSO CI Enforcement, DSO Sub-PR Review Enforcement); `main` has 0 `merge_queue` rules; 0 live `gh-readonly-queue/*` refs. |
| **V0.8** — non-expiring admin credential | **PASS (with caveat)** | admin PAT (`JoeOakhartNava`) reads+provisions rulesets; non-admin `gh` (`joeoakhart`) works for containment reads. NOTE: the prior "golive" PAT **expired mid-session** (HTTP 401) — secure a durable credential before A-5. |
| **V0.5** — removing `merge_group:` triggers breaks no required check | **PASS** | triggers are provably inert (V0.7: no queue ever fires); the 5 carriers are `ci.yml`, `dangling-references.yml`, `review-coverage-invariant.yml`, `ruleset-invariants.yml`, `ticket-platform-matrix.yml`. |
| **V0.5b** — removing the `merge-pipeline-checks` `merge_group` if-arm is safe | **PASS** | `ci.yml` job `if:` is `event_name=='merge_group' \|\| (event_name=='pull_request' && (base_ref=='main' \|\| session/* …))` — the `base==main` path is an independent OR-clause; removing the `merge_group` arm leaves two-tier firing unchanged. |
| **V0.4** — `dangling-references` exit-78 path + FP rate | **PARTIAL** | the wrapper `dangling-references.yml:46-50` has the **same exit-78 → exit 0** mapping as coverage (same hole; same fix needed). The script is git-based (fewer `gh` preconditions) so it triggers 78 less readily. **FP rate on the 20-PR ground-truth set is deferred to CF-8** (the sg-based matcher does not exist yet). |

### Decisive finding

The deterministic coverage gate that Option A (and MQ) relies on is **necessary but not sufficient as wired**: flipping `DSO_COVERAGE_INVARIANT_MODE=enforce` and adding the check to `required-checks.txt` does NOT make it a hard gate, because the **workflow wrapper passes unconditionally on exit 78**. A token-scope regression or transient API failure — a realistic production event — silently disables the gate. This is the **same "silently passes" failure class we pivoted away from MQ to avoid**, and it must be fixed in both `review-coverage-invariant.yml` and `dangling-references.yml` (gate the exit-78 path on mode: in `enforce`, exit 78 must **block** or fail-closed) **before** the enforce-flip (A-5). Added as a hard prerequisite in the plan; verification re-run as part of A-5.

## Consequences

### Positive
- The non-negotiable requirement is met by a chain that is fully ruleset-enforced once the exit-78 fix lands: `review-sub-pr` (sub-PR ruleset) + content-aware `llm-review` (main ruleset, re-reviews un-provenanced files, V0.2) + deterministic `review-coverage-invariant`/`dangling-references` on PR2 (closes CF-2/CF-9).
- No irreversible shared-`main` cutover; the working two-tier flow (V0.1) is retained.
- MQ work is preserved in git history; the tree is cleaned of dormant MQ scaffolding.

### Negative / Risks
- **R1 (load-bearing):** the requirement rests on `review-coverage-invariant` being airtight. The script is (V0.3b); the wrapper is not (V0.3a) until fixed. S-11/CF-6/CF-8 harden the rest. If it cannot be made FP-free AND gap-free, neither MQ nor two-tier can ruleset-enforce the requirement — that becomes the real problem.
- Enforcing a flaky check wedges all promotions for the team → CF-6 (cache-key + backoff + budget convergence) is a hard precondition of A-5.
- The two-tier orchestrator (`merge-to-main-pr.sh`, ~3.2k lines) and its maintenance surface remain — this was MQ's genuine, but secondary (maintainability, not correctness), win.

## References
- Supersedes: `docs/adr/0019-github-merge-queue-for-staged-to-main.md`.
- Plan: `docs/handoff/option-a-pivot-plan.md`.
- GitHub docs: [Managing a merge queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue); merge-queue-specific checks not configurable: [community #103114](https://github.com/orgs/community/discussions/103114).
- Live MQ validation evidence (2026-06-03): PRs #588 (queue happy-path, fast-forwarded; `llm-review` absent on candidate), throwaway ruleset 17199869 (torn down).
