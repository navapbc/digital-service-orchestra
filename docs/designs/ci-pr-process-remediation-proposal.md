# CI/PR/llm-review Pipeline — Remediation Proposal (v2, re-baselined)

**Status:** Draft for user approval
**Process:** 2 independent opus audits → 10 convergent findings → blue-team verification (9 sustained, 1 downgraded, 0 dismissed) → proposal → opus proposal-review (approved) → **4-stream due diligence** (Merge-Queue spike, scenario stress-test, historical why-not, prior-art convergence) → this v2 re-baseline.

---

## 0. Re-baseline — read this first (CRITICAL)

The v1 of this proposal was drafted against `origin/main` and **over-counted new scope**. The historical audit (against HEAD + in-flight branches) establishes that **most "findings" are in-flight v4 work, already partly shipped in the last 1–2 days.** This changes the framing from "approve new work" to "**harden + finish the v4 stability plan correctly, plus one genuinely-new architectural ADR (Merge Queue).**"

**What is already done / in-flight (verified):**
- **The enforce go-live is already committed** on branch `golive/enforce-coverage-dangling` (commit `32819d767f`): flips `review-coverage-invariant` + `dangling-references` warn→enforce, adds both to `required-checks.txt`, provisions the live ruleset. **It is unmerged** — `origin/main` is still warn-mode (it is the attempt rolled back earlier this session after PR #529's merge-commit failure, whose clean-merge-exemption fix has since landed on main). → **P0 is not a decision to make; it is a committed go-live to harden-then-complete.**
- **W2c convergence detector** (`042a6981fc`, `review-convergence-check.sh`) is **on main** but unwired. The documented plan (v4 exec-log go-live item #3) is to **wire** it. → P0.c's "delete" default would *reverse* a deliberate ~1-day-old deliverable.
- **PR1 deadlock + resume-advance are already fixed on main**: `684ffa858b` (PR1 auto-merge, closed bug `c9fe-8b6c`) + `623b3f7b05` (resume advances to PR2 instead of duplicating PR1, closing the #490/#492 class). → P1.a's residual is **narrower** than v1 implied.
- **Version bump already moved** to the feature branch during PR1 (`6c65a4f80c`) for a ruleset reason; open bug `4668-c3ca` tracks the staged-* push-rejection. → P1.b must not re-introduce `4668-c3ca`.
- The `BRANCH`-mutation/state-path root cause (CF-3) was **partly addressed** by `623b3f7b05` (persists `staged_branch` before re-pointing `BRANCH`).

**Action:** re-baseline against HEAD + `golive/enforce-coverage-dangling` + `feat/ruleset-bypass-actor-f008cfb359` before executing anything below.

---

## 1. Framing

The v4 overhaul's design and scripts are sound; the gap is **enforcement lagging design** plus **two hardening gaps the committed go-live did not include**. The work splits into:

1. **Complete the rolled-back Goal-1 go-live — but harden it first** (CF-1, CF-2, CF-6, CF-8 + two NEW blockers from the scenario stress-test). The enforce flip is committed; it is **premature** because it omits (a) ledger/API hardening, (b) the `sg`-based dangling matcher, and (c) **an admin-exemption ledger** without which the first admin bypass after enforce **wedges the entire repo**.
2. **Evaluate Merge Queue** (CF-9, CF-3, CF-2, CF-5) — the one genuinely-new, never-evaluated, industry-aligned direction. Both the spike and the prior-art research independently land here.
3. **Finish the orchestrator-reliability residual** (CF-4 residual, CF-5) — building on already-shipped commits, not re-introducing them.
4. **Contained fixes** (CF-7, CF-10, CF-8-appendix) — clean, no prior decision.

**Non-negotiable sequencing rule (validated by scenario + prior-art):** *a fail-closed gate that runs in warn-mode is not fail-closed — it is "green-when-blind"; but flipping it to enforce before hardening converts a silent gap into a CI-wedge.* **Harden (P0.a/P0.b + the exemption ledger) before completing the committed flip. Never flip first.**

---

## 2. Findings (post-blue-team + scenario hardening; final severities)

| ID | Final sev | Status vs. main | One-line |
|----|-----------|-----------------|----------|
| CF-1 | **critical** | enforce committed-but-unmerged; convergence on-main-unwired | Goal-1 backstops inert on main: both invariants warn-mode & not required; `review-convergence-check.sh` unwired. |
| CF-2 | **high** | open | All-provenanced staged→main `llm-review` SKIPs (delta-only); cross-sub-PR combination conflict reaches main; backstop warn-mode. |
| CF-9 | **high** | open (never evaluated) | Bespoke delta-review ≠ combined-state re-validation (the universal merge-queue norm; failure class = "merge skew"). |
| **S-11** | **critical (NEW)** | open | **Admin-bypass contagion wedge:** coverage-invariant has no reachability prefilter + ledger records only proven-reviewed SHAs → the first unreviewed admin/hotfix SHA on main is re-enumerated by *every* later PR and blocks all of them indefinitely. |
| CF-4 | **medium** (was high) | deadlock+resume **shipped**; FINDING-failure path residual | PR1 *review-finding* failure may still exit without PR2's resolve loop; resume must look-up-before-create (idempotency). |
| CF-5 | **medium** | partly mitigated by `6c65a4f80c` | Concurrent staged-base staleness; no lock. (MQ subsumes; P1.b must not re-trigger bug `4668-c3ca`.) |
| CF-6 | **medium** | open | Ledger cache key uses `github.run_id` → warm-restores but never exact-hits; check-runs API has zero backoff → fail-closed at enforce. |
| CF-8 | **medium** | open | `dangling-references` reference scan is unescaped textual `git grep`, sh/py-only; misses `.md`/`.yml`/`Makefile` callers; short-symbol FP. |
| CF-7 | **medium** | open | `_is_clean_merge` duplicated; verdict hand-synced ("KEEP IN SYNC"). |
| CF-3 | **high** | partly addressed (`623b3f7b05`); mostly mooted by MQ | 3,214-line orchestrator; resume complexity. Largely retired if MQ adopted. |
| CF-10 | **low** | open | `DSO_DISPATCH_FILES_CAP=100` < region-split `gate_file_count=120`; OVER_BOUND fires *before* region-split. |

---

## 3. Workstreams

### P0 — Harden, then complete the committed Goal-1 go-live (closes CF-1, CF-2, CF-6, CF-8, **S-11**; partially CF-9)

The enforce flip (`32819d767f`) is **on hold until the following land**. Treat the committed go-live as *premature*, not as the deliverable.

**P0.a — Coverage-invariant ledger + API hardening + budget convergence (CF-6).**
- Replace the cache `key` `…-${{ github.run_id }}` with a stable additive key (`…-${{ github.base_ref }}`) + explicit `actions/cache/save` (save-always) + **merge-not-overwrite** ledger writes.
- Add bounded retry/backoff + a per-run API budget to the check-runs path (`_rc_gh`/`rc_sha_is_reviewed` in `review-coverage-lib.sh`), mirroring the verifier's `_call_gh_with_backoff`.
- **Budget-exhaustion must CONVERGE, not just fail (scenario 6):** an exhausted budget on a cold 300-commit PR emits a **distinct, retryable "re-run to continue" status** (not the fail-closed coverage-gap status), and because the ledger persists partially, the re-run **warm-hits** already-verified SHAs and converges within K re-runs. Test: explicit converge-on-rerun fixture, not just a cache round-trip.
- Effort: S–M. Risk: low.

**P0.b — `sg`-based dangling matcher + reference breadth (CF-8).**
- Swap `check-dangling-references.sh` `_references_at_head`/`_defined_at_head` to `sg` (ast-grep) with the CLAUDE.md guarded fallback (`command -v sg`); when falling back to `git grep`, `printf '%q'`-escape the symbol.
- **Reference-side scan must include `.md`/`.yml`/`.yaml`/`Makefile`/`.txt` (scenario 12b):** this repo routinely invokes `.sh` from runbooks/workflows; a `.sh`/`.py`-only reference scan misses real cross-PR dangling callers (a recall hole that undercuts CF-2's "structural backstop" claim). Definition-side stays code (`.sh`/`.py`).
- **Short/ambiguous-symbol guard (scenario 5):** the existing 20-PR ground-truth set almost certainly lacks a short-common-symbol rename (`run`/`get`/`id`), so a green bake is false confidence. Add explicit short-symbol FP/FN fixtures; add an arity heuristic (symbol with ≥N defs repo-wide ⇒ inherently ambiguous ⇒ advisory, not block).
- Effort: M. Risk: medium (matcher correctness). Test: 20-PR set + the new fixtures.

**P0.c — WIRE the convergence detector (CF-1) — do NOT delete by default.**
- **Reversed from v1.** `review-convergence-check.sh` (`042a6981fc`/W2c) was deliberately built ~1 day ago; the documented plan (exec-log go-live item #3) is to **wire** it. Wire it into the integration `llm-review` path (persist `DSO_CONVERGENCE_HISTORY` via a stable cache, pass `DSO_REVIEW_CYCLE`), warm-up in warn, then required. Deleting it would *reverse* a settled W2c decision — only do that with an explicit decision to abandon W2c, not as a YAGNI default.
- Effort: S. Risk: low.

**P0.d — Admin-exemption ledger (S-11) — THE go-live blocker.**
- **New, highest-impact.** Before the enforce flip, add an **admin-acknowledged exemption ledger**: a reviewed-equivalent entry (distinct from "reviewed", carrying audit metadata — who/why/when, ideally HMAC-signed like the existing audit-sweep markers) that the coverage-invariant honors via a parallel `_exempt_has`. Provide the on-call runbook: "post-bypass → add an exemption entry for the bypassed SHA."
- **Rationale:** without it, the *first* legitimate admin bypass after enforce go-live makes that unreviewed SHA permanently re-enumerated by every later PR's `origin/main..HEAD` walk (no reachability prefilter; ledger never records it) → **all PR throughput wedges**. This is the single difference between "enforce catches laundering" and "enforce bricks the repo."
- Effort: M. Risk: medium (security-load-bearing — the exemption path must be admin-only + audited, never agent-reachable). Test: bypass-then-exempt-then-next-PR-passes scenario.

**P0.e — Operator-message disambiguation (scenarios 9, 11).**
- The coverage-invariant's generic "no covering merged PR with a passing review check-run" message misattributes (a) GitHub API exhaustion, (b) an Anthropic/provider outage that failed the review check for infra reasons, and (c) a known admin bypass — all as a coverage gap, sending on-call after phantom laundering holes. Emit distinct statuses for: genuine-not-reviewed | API-budget-exhausted (retryable) | infra/provider-failure | known-exempt.
- Effort: S. Risk: low.

**P0.f — Complete the flip (CF-1, CF-2) — only after P0.a–e bake green.**
- Re-baseline `32819d767f` onto current main, confirm the clean-merge-exemption fix (already on main) + P0.a–e are present, bake in warn for a time-boxed window, then merge the enforce flip + provision (coverage-invariant first, dangling second). Adopt **W6(c)** — re-enter a covered file into integration-review scope when an exported symbol in it changed — **targeting the integration-diff scoping path** (`build-integration-diff.sh` / the dispatcher's unprovenanced-scope construction), **not** the provenance walk (`verify-session-provenance.sh` is SHA-level and does not subtract covered files).
- **Named accepted residual (prior-art caveat):** W6(c) + enforcing dangling-references closes the *symbol-rename* class of cross-PR conflict, **not** arbitrary behavioral/semantic interaction. Combined-state *testing* (P3, Merge Queue) catches the broader class. If we keep the bespoke delta path, **explicitly accept** residual exposure to non-symbol semantic conflicts — do not leave it implicit.

### P1 — Orchestrator reliability residual (closes CF-4 residual; mitigates CF-5)

**P1.a — PR1 review-FINDING recovery + resume idempotency (CF-4 residual).**
- Build on `684ffa858b` (deadlock) + `623b3f7b05` (resume-advance) — **do not re-introduce them.** The residual: a genuine PR1 *review-finding* FAILURE still exits without running PR2's `_phase_resolve_threads`/remediate loop. Factor that loop into a PR-number-parameterized helper (it already takes `$1=pr_number`) and run it for PR1 on FAILURE before re-waiting.
- **Resume idempotency (scenario 8):** on resume, **look up the existing open PR1 by head/base before `_create_staged_ref`** — the `pr1_open=1` fail-safe default means any `gh` hiccup falls back to the create path → duplicate staged ref + PR1 (the #490/#492 class `623b3f7b05` fixed; don't regress it).
- Effort: M. Risk: medium (load-bearing orchestrator). Test: gh-stub "PR1 review-finding fails → fix → resume to PR2" + a flaky-detection idempotency case.

**P1.b — Version-bump staleness (CF-5) — reconcile with the ruleset constraint.**
- `6c65a4f80c` already moved the bump to the **feature branch during PR1** because the staged-* ruleset rejects a fresh bump commit (bug `4668-c3ca`). So "bump after the main-sync" **cannot** land the bump on staged-*. Re-derive the bump value against current main **on the feature branch** (re-bump before PR1 if main advanced), or defer entirely to the Merge Queue serialization (P3). **Do not** move the bump to the staged-* branch (would re-trigger `4668-c3ca`).
- Advisory lock remains **deferred** to the MQ decision (YAGNI; consistent with prior intent). Until P3 lands, name the same-minute-concurrency staleness as a **known residual**.
- Effort: S. Risk: low.

### P2 — Contained fixes (closes CF-7, CF-10; CF-8 appendix)

**P2.a — Consolidate `_is_clean_merge` + verdict (CF-7).** Hoist `_is_clean_merge` into `review-coverage-lib.sh` single-source; replace the embedded hand-synced verdict copy in `verify-session-provenance.sh` with a call to `rc_review_check_verdict` (already the designated single-source — finish the job). Add a divergence test if deferring. Effort: S–M. Risk: low–medium (add the test regardless).

**P2.b — Reconcile the file-count caps (CF-10).** Raise `DSO_DISPATCH_FILES_CAP` to **≥120 (= `gate_file_count`)** AND reconcile the 5 MB `DSO_DISPATCH_BYTES_CAP` against the region-split LOC budget — the dispatcher cap aborts to OVER_BOUND **before the runner's region-split can fire**, so the magic number must be explicit, not "≥ region-split." Document the full threshold ladder (dispatch_files_cap ≥ gate_file_count; bytes_cap vs LOC gate) with one owner. Effort: S. Risk: low.

**P2.c — Tighten symbol-injection reference set (CF-8 appendix; coordinate with `425edbbe55`).** Constrain `symbol_injection.py::_referenced_identifiers` to call-site/attribute shapes rather than every identifier token (the imprecision the module header warns about and the prior-art literature flags). **Not** a dangling-references enforce prereq (it feeds the region-split appendix, not the safety check). Touches recently-shipped `425edbbe55` — coordinate. Effort: S. Risk: low.

### P3 — Merge Queue evaluation (the one genuinely-new ask) → addresses CF-9, CF-2, CF-5, CF-3

**P3.a — ADR: adopt GitHub Merge Queue for staged→main.** Both the spike and the prior-art research independently recommend it, and the historical audit confirms it was **never formally evaluated** (only cited as prior art) — so it legitimately deserves an ADR.
- **Recommendation: GO, scoped** — enable MQ on `main` with **max-PRs-per-merge = 1** (sidesteps the 2026-04 multi-PR squash-revert incident and makes the combined candidate trivially = this-PR-on-current-main); **keep the LLM review as a required check on the sub-PR** (the cost win — never put the paid LLM call on the queue's eviction-amplified hot path); make the **deterministic Goal-1 backstops (`dangling-references`, `coverage-invariant`) required on `merge_group`** (their natural enforce home — MQ runs them on the *true* combined candidate, strictly better than today's staged-head approximation); keep **identity containment** unchanged (prior-art: textbook best practice).
- **What it structurally resolves:** CF-2/CF-9 (combined-state re-test for deterministic checks), CF-5 (serialization), CF-3 + CF-4 (retires staged-ref creation, PR1/PR2, most resume logic, the `BRANCH`-mutation root cause).
- **What it does NOT resolve:** CF-1 hardening (P0.a/P0.b/P0.d still required — MQ only relocates *where* those checks run, to `merge_group`); LLM combined-state review (deterministic dangling-references on `merge_group` is the proportionate substitute — same conclusion as P0); version-bump must stay a pre-queue feature-branch commit (P1.b) before any batching.
- **Spike caveats to verify:** (1) **every required workflow must add the `merge_group` trigger at once** or the queue silently rejects; (2) the LLM-review trigger is keyed `base_ref == main` vs `!= main` (v4 CS-8) — `merge_group` is a *third* ref context the trigger logic must survive; (3) CODEOWNERS-vs-bypass-actor quirk (we don't use CODEOWNERS — keep it that way); (4) `gh-readonly-queue/*` branches are unprotectable (benign for us).
- Effort: M (ADR/spike). Risk: low (analysis). Output: go/no-go ADR.

**P3.b — Conditional scoped orchestrator refactor (CF-3) — ONLY if P3.a says "keep bespoke."** Make `BRANCH` immutable + carry the staged branch separately (credit `623b3f7b05` as a down-payment) + one resume entrypoint reading a persisted phase. Gated entirely on P3.a — adopting MQ retires most of it. Effort: L. Risk: medium-high. Do not start before P3.a decides.

---

## 4. Sequencing

```
RE-BASELINE (§0) ─► against HEAD + golive/ + feat/ruleset-bypass-actor branches

P0.a (ledger/API/converge) ─┐
P0.b (sg dangling + breadth + short-sym) ─┤
P0.c (WIRE convergence) ─┤── all merge ─► bake green (warn) ─► P0.f (complete the committed flip + W6c)
P0.d (admin-exemption ledger) ─┤              ▲
P0.e (operator messages) ─┘                   └─ P0.d is the hard gate: no enforce without it (S-11)

P2.a (predicate consolidation) ── precede P0.f (consolidate the security predicate before it's enforce-load-bearing)
P2.b (cap reconcile) ─┐ parallel, independent
P2.c (symbol-inj precision) ─┘

P1.a (PR1 finding-recovery + idempotency) ─► CF-4 residual   ┐ parallel with P0
P1.b (version-bump reconcile) ─► CF-5 mitigated              ┘

P3.a (Merge Queue ADR) ─► go/no-go ─► if GO: relocate P0.d/P0.b checks to merge_group, retire CF-3/CF-4/CF-5 work
                                   └─► if NO-GO: P3.b scoped refactor
```

**Critical path:** P0.d (exemption ledger) + P0.a + P0.b + P2.a must all land and bake before P0.f (the enforce completion). P3.a runs as a parallel strategic track and, if GO, **changes where P0's checks run** (`merge_group`) — so ideally decide P3.a **before** P0.f to avoid relocating the enforce wiring twice.

---

## 5. YAGNI / non-goals (validated against history)

- **Do not** complete the enforce flip (`32819d767f`) before P0.a/P0.b **and P0.d (exemption ledger)** land — it would wedge the repo on the first admin bypass.
- **Do not** default-delete `review-convergence-check.sh` — that reverses W2c (`042a6981fc`); wire it.
- **Do not** re-introduce PR1 deadlock/resume logic — it shipped (`684ffa858b`/`623b3f7b05`); build the *finding-failure* residual on top.
- **Do not** move the version bump to the staged-* branch — re-triggers bug `4668-c3ca`.
- **Do not** build a bespoke merge-lock — defer to the MQ decision.
- **Do not** expand the LLM review to the combined diff / `merge_group` — keep it on the sub-PR (cost); deterministic dangling-references on `merge_group` is the substitute.
- **Do not** start P3.b before P3.a decides.

---

## 6. Net recommendation

1. **Re-baseline** against HEAD + the `golive/` and `feat/ruleset-bypass-actor` branches (the proposal is largely *finishing* v4, not new scope).
2. **P0 is the priority and it has a NEW hard blocker (S-11 admin-exemption ledger)** the committed go-live lacks — without it, completing the enforce flip bricks the repo on the first bypass. Harden (P0.a/b/d/e) → bake → complete the flip (P0.f).
3. **Merge Queue (P3.a) is the one clean, never-evaluated, industry-convergent direction** — recommend a GO ADR scoped per the spike (max-PRs=1, LLM on sub-PR, deterministic backstops on `merge_group`, identity containment kept). It subsumes CF-2/CF-3/CF-4/CF-5 and should ideally be decided **before** P0.f so the enforce wiring is placed on `merge_group` once.
4. **P1/P2** proceed in parallel, built on already-shipped commits.
5. **Name the accepted residual:** delta-review (even with W6c) does not catch non-symbol semantic conflicts; only combined-state testing (MQ) does. Accept it explicitly or adopt MQ.
</content>
