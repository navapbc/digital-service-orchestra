# Option A Pivot Plan — Roll back GitHub Merge Queue, harden the two-tier flow

**Status:** DRAFT for review (do not execute until the experimental-verification list is confirmed)
**Date:** 2026-06-03
**Supersedes:** ADR-0019 (GitHub Merge Queue for staged→main)

---

## 1. Why we are pivoting

**Non-negotiable requirement:** every commit that reaches `main` must pass an LLM review that is **ruleset-enforced** (a hard GitHub gate), not merely flow-enforced.

**Why MQ cannot satisfy it (established by live validation + GitHub docs, 2026-06-03):**

- GitHub Merge Queue evaluates required status checks on the **`merge_group` candidate**, not the PR head, and you **cannot** configure a different required-checks list for the queue vs the PR.
- A required check that never reports on `merge_group` does **not** inherit the PR pass — it **times out and evicts** the entry (`check_response_timeout_minutes`, default 60 min). In live validation, `llm-review` was **absent** on the candidate.
- Therefore under MQ the only ruleset-enforceable review gate on the merge candidate is a **deterministic coverage proxy** (`review-coverage-invariant`), never the content-aware LLM review itself. A "skip-success" `llm-review` on `merge_group` is a rubber stamp (no enforcement on the candidate).
- That deterministic coverage gate is what actually delivers "ruleset-enforced every-commit-reviewed" — and **it works identically on the existing two-tier PR2**. MQ does not buy the enforcement; the coverage check does. MQ adds an irreversible shared-`main` cutover, the `merge-to-main` rewrite, and a **weaker** posture (loses the two-tier flow's content-aware `llm-review` backstop that re-reviews un-provenanced files).

**Decision:** adopt the ADR's named fallback — **Option A: keep the two-tier flow, harden only.** Land the P0 hardening (S-11/CF-6/CF-8), enforce-flip `review-coverage-invariant` + `dangling-references` on PR2 to close CF-2/CF-9 (merge skew), and keep the existing ruleset-enforced `llm-review` gate.

---

## 2. Guiding constraints for this plan

1. **Live-GitHub validation at every step.** No step is "done" until verified against live GitHub (rulesets, a real promotion, real check behavior).
2. **Preserve incidental non-MQ fixes.** Roll back MQ-specific code only; keep general robustness improvements bundled into MQ commits where they have standalone value.
3. **Preserve MQ work in git history.** Use `git revert` / surgical edits — never history rewrite. The ADR + proposal docs are **kept and annotated as superseded** (ADRs are historical records; deleting them is itself confusing).
4. **The two-tier flow must remain functional throughout.** Every rollback increment lands via the still-working two-tier `merge-to-main` flow (the `dso.merge_queue.enabled` flag is and stays OFF/removed).
5. **Token/identity:** the golive PAT expired mid-session (HTTP 401). Use the admin PAT (`JoeOakhartNava`) for ruleset ops and the non-admin `gh` auth (`joeoakhart`) for containment-style checks. Confirm a fresh, non-expiring credential before starting.

---

## 2.5 CRITICAL correction (opus review) — the coverage gate is NOT airtight as wired

The linchpin of Option A is that `review-coverage-invariant` (deterministic, fail-closed) becomes a hard ruleset gate. **The script is fail-closed, but the workflow wrapper is not:** `.github/workflows/review-coverage-invariant.yml` (~lines 70–75) and `dangling-references.yml` (~lines 46–50) map **exit 78 (`PRECONDITION_NOT_MET`) → `exit 0` (pass) UNCONDITIONALLY**, not gated on `DSO_*_MODE`. The script returns 78 on a missing/under-scoped `gh` token, an unresolvable `GH_REPO`, or absent `gh`/`python3`. So after the enforce-flip, a **token-scope regression or a transient API blip makes the gate silently GREEN on a candidate that was never content-reviewed** — the exact "silently passes" failure class we pivoted away from MQ to avoid.

**Required fix (prerequisite to A-5):** in enforce mode, exit 78 must **block** (or fail-closed), not pass. Patch both backstop workflows + add verification **V0.3a**. Record in ADR-0020 so a future MQ re-attempt knows mode-flip alone is insufficient.

## 2.6 CRITICAL findings from adversarial review #1 (reframes Option A)

Review #1 established that **the non-negotiable requirement is NOT met by the two-tier flow today — independent of MQ.** The chain is a **conjunction of independently-skippable required checks** ("skippable checks aren't really required"); there is **no always-runs fail-closed required check on PR2.** Three holes:

- **C1 — `code_changed=false` skips every gate to SUCCESS on PR2.** `ci.yml`'s `changes` job runs `skip-review-check.sh`; if the PR2 net diff is allowlisted-only (`docs/**`, `**/.claude-plugin/plugin.json` [the VERSION file], `package.json`, `.tickets-tracker/**`, images), `code_changed=false` → every substantive step in `llm-review`/`review-sub-pr`/deterministic gates is `if: code_changed=='true'` → skipped → **job reports success, the provenance check never runs.** `llm-review` is satisfiable with **zero review** on an allowlisted-only PR2 — Option A's premise ("keep the ruleset-enforced llm-review gate") is FALSE. <!-- # tickets-boundary-ok -->
  - **NARROWED (review #4, confirmed):** `assert-review-liveness.sh` runs **unconditionally** (`ci.yml:896`, no `code_changed` gate) and on the `code_changed=false` path **re-runs `skip-review-check.sh` against the actual PR diff**, failing if any non-allowlisted file is present (`:147-157`). So an allowlisted-only PR2 is NOT "zero checks" — liveness fail-closes on mis-classification. The real exposure is therefore the **allowlist SCOPE** (genuinely-allowlisted content like `docs/**` reaches main with no *content* review — closed by A-4.6), not "the gate never runs." A-4.5's summary gate must reconcile with liveness, not re-implement it.
- **C2 — provenance ≡ per-SHA "covering merged PR's review-check = success", never per-file.** `review-coverage-lib.sh::rc_sha_is_reviewed` credits a covering PR's review success to *every SHA in it*, never checking whether the SHA's files were in the review's diff scope. A skipped-to-success `review-sub-pr` (C1) launders every SHA it carried. C1+C2 = a real laundering path for content in allowlisted paths. (Also CORRECTS the earlier version-bump finding: in the real flow the bump rides PR1 and is classified **reviewed/laundered**, not wedged — the isolation test was unrealistic.)
- **E3 / no-op umbrella — `merge-pipeline-checks` is a no-op success on PR2.** Its only enforcing step `red-test-blocker` requires `head_ref` ∈ `session/|worktree-|fix-|…`; PR2's head is always `staged-*` → it green-stamps every staged→main PR.

**REDESIGN (central recommendation): Option A converges on a SINGLE always-runs, fail-closed review-coverage SUMMARY GATE as THE required check on PR2** — replacing the conjunction of skippable checks. The summary gate: always runs on `base==main` PRs (NOT `code_changed`-gated → closes C1); proves every reachable **file-change** (not just every SHA) was in a passing review's diff scope (closes C2/I3); fail-closes on precondition with **bounded retry** (config-error → block now; transient → retry then block → closes exit-78 + wedge tension); is the sole/minimal required check so nothing it depends on can skip independently. This is materially larger than "enforce-flip two checks" — and it is the same work whether the substrate is MQ or two-tier; two-tier is just the lower-complexity place to build it.

## 2.7 Review #2 verdict — the governing decision (E1) + what's unbuildable today

Review #2: **NO-GO on A-4.5/A-5 as written**; Phase 1 rollback + the exit-78/CF-6/E3 hardening ARE ready.

**The load-bearing finding:** the per-file coverage assertion A-4.5 depends on is **unbuildable with today's plumbing** — every layer proves coverage **per-SHA** ("a covering merged PR's review-check passed"); the diff a review actually saw is **ephemeral** (`mktemp` in `llm-review-dispatch-or-skip.sh`, never persisted) and there is **no `{check_run_id → reviewed_file_set}` artifact** anywhere. Closing C2 (per-file) requires a NEW signed, fabrication-proof evidence layer (**E10**) — a multi-story epic, not a sub-bullet. And it must be review-emitted, never recomputed from the commit, or it re-opens the v4 fabricated-trailer laundering hole.

**E1 — DECIDED (2026-06-03): per-SHA coverage + TIGHTENED allowlist + ticket-data exclusion (path #2; recorded in ADR-0020).**
- Keep the existing per-SHA coverage mechanism. **Shrink the review-gate allowlist** so only genuinely-inert artifacts skip review (images, lockfiles, generated files); `docs/**`, skills, and behavior-driving config become **reviewable** (agentic threat model: un-reviewed instruction surfaces are an attack vector). Closes C2's practical risk without the per-file E10 epic.
- **Ticket-data exclusion (load-bearing):** a commit whose diff is **entirely within `.tickets-tracker/**`** is excluded from review AND from the coverage-invariant walk (machine-generated ticket state; the orphan `tickets` branch never enters a project PR). Exemption is **diff-scoped evidence** (touches ONLY `.tickets-tracker/**`), never a trailer (v4 fabricated-trailer lesson); a commit mixing ticket + code/doc is NOT exempt. This also prevents the per-SHA gate from fail-closing (wedging) on legitimate ticket-sync commits. <!-- # tickets-boundary-ok -->
- Per-file content review (the E10 evidence-plumbing epic) is **deferred/not adopted** unless the threat model changes.

**New gaps from review #2 (fold into A-4.5/A-5 once E1 is decided):**
- NEW-2 allowlisted-docs forced choice (block-docs-promotions vs evidenced-cheap-review) — pick + **E11**.
- NEW-3 OVER_BOUND / budget-exhaustion / FP under the enforced gate must route to `/dso:fp-recovery`, not wedge — **E12**.
- NEW-4 the summary gate MUST be a **single script**, NOT a `needs`/`if: failure()` aggregation (the latter greens on a *skipped* upstream — the disease again) — **E13**.
- NEW-5 write the A-5 cutover **runbook** (exact provision→open-PR→assert→land order); E6 is the experiment, the runbook is the deliverable.

**Experiments added by the E1=per-SHA decision:**
- **E11 [BLOCKING]** — docs-only PR2 under enforce after allowlist tightening: an un-reviewed docs/skills change → `code_changed=true` → BLOCKED (not skip-to-success); a PR1-reviewed docs change → passes. Confirms agent-facing content is now gated.
- **E14 [BLOCKING — ticket exemption]** — (a) a commit touching ONLY `.tickets-tracker/**` → exempt from the gate (no review required, no wedge) in enforce mode; (b) a commit mixing `.tickets-tracker/**` + a code/doc file → NOT exempt → requires review (RED if unreviewed). Confirms the diff-scoped exemption can't be used to launder code into a "ticket" commit. <!-- # tickets-boundary-ok -->

## 2.8 Review #3 corrections (CONDITIONAL GO — folded in)

Review #3 verdict: **the bounded E1 design is sound; no architectural blocker.** Corrections applied:

- **C-A (CRITICAL, resolved in execution):** `merge-to-main-pr.sh` is **surgical-edit-only** — two **non-MQ** fixes sit on top of the MQ changes (`783ce127a1` base-agnostic polling PR-number fallback; `78163b1407` resumable-state auto-detect + empty-staged hardening). A checkout-restore to baseline would silently drop them. The rollback reverse-applied ONLY the `4cf3b2fe9a`/`ec13fe09bb` MQ hunks (clean), preserving both fixes + the 5 pre-existing `mergeStateStatus`. Also confirmed: the 2 change-detector tests (`resume-existing-pr-discovery`, `pr-resume-and-stale`) have **net-zero** MQ change (edited then reverted in `ec13`) → left at `origin/main` (one had non-MQ `78163b1407` content that a baseline-restore would have dropped — corrected).
- **I-1 (A-4.5 ticket exemption ordering):** in `review-coverage-invariant.sh` the ticket check goes **after** `_is_clean_merge` and the ledger check, and **empty file list = NOT exempt** (a clean merge's `diff-tree` is empty → vacuous-true bug). Exempt iff `git diff-tree --no-commit-id --name-only -r <sha>` is **non-empty AND every entry** matches the anchored prefix.
- **I-2 (path safety):** anchored prefix `case "$f" in .tickets-tracker/*) ;; *) return 1 ;; esac` (trailing slash mandatory, so `.tickets-tracker-backup/` is NOT matched); git tree paths can't contain `..`. Symlink-in-ticket-dir is a defense-in-depth note, not a blocker. <!-- # tickets-boundary-ok -->
- **I-3 (allowlist tightening scope):** beyond `docs/**`, also remove behavior-driving config from the skip set — **`.pre-commit-config.yaml`, `.semgrep.yml`, `.claude/docs/**`, `.claude/scripts/**`**. NOTE: `skip-review-check.sh` **already force-reviews** `hooks/`, `skills/`, `docs/workflows/`, `CLAUDE.md` (case block) — so "make skills reviewable" is already done; the real edit is `docs/**` + those config files. Keep `skip-review-check.sh` and `compute-diff-hash.sh` consumers in sync.
- **I-4:** make `review-gate` the **unambiguous enforcement floor**; `llm-review` stays `code_changed`-gated → it is best-effort content review, NOT the floor. Do not add `review-coverage-invariant`/`dangling-references` to `required-checks.txt` individually (they aren't today) — only the single `review-gate`.
- **I-5:** remove `merge-pipeline-checks` from the **main ruleset only** at A-5 (it stays on the sub-PR path); pair its removal with adding `review-gate` in the same provision (window-free swap).
- **N-1 (retry):** bounded retry wraps the **outer** invariant invocation in-script (ledger persists in workspace → no budget re-spend), not per-`gh api` call.
- **New experiments:** **E15** (clean-merge + ticket-only + mixed ticket+code all in one PR2 range — proves the ordering & empty-set=not-exempt); **E16** (post-rollback, `merge-to-main-pr.sh`'s `783ce127a1`+`78163b1407` behavior survives).

## 2.9 Completeness audit (grounding review vs live codebase) — additions before building

Verified accurate: rollback is clean (only GitHub auto-merge + pre-existing `mergeStateStatus` retained); ADR-0019 + proposal carry SUPERSEDED banners; `review-coverage-invariant`/`dangling-references` ARE warn-mode and NOT in `required-checks.txt`; d205 (Node-20, ~2-week deadline) intact. Missing items to add:

**Parity fix (CRITICAL — corrected by review #4 + experiments V0.9/V0.10):** A-5 must **remove `merge-pipeline-checks` from `required-checks.txt` AND the live ruleset** when adding `review-gate` — not just the ruleset. The live main ruleset (15629023) required set == the 12 `required-checks.txt` lines (incl. `merge-pipeline-checks`). **DO NOT rely on `ruleset-design-invariants` to catch a one-sided swap — it only asserts MEMBERSHIP (`check-staged-head ∈ live`), not full-set parity.** The real full-set live-parity guard is the **R5 (offline) ∧ R8 (live arm)** chain in `test-ruleset-provisioner-roundtrip.sh` (R5: provisioner dry-run == `required-checks.txt`; R8: live `main` contexts == provisioner dry-run — transitively, live == `required-checks.txt`). **CORRECTED by the parallel reviews + CI-log verification:** `DSO_RULESETS_READ_TOKEN` **IS configured** (created 2026-06-01) and the live arm **is already active and passing in CI** — run `26901868917` shows `R7`/`R8` PASS, `PASSED: 8`. So R8 is **NOT inert today**; the live-parity guard already enforces on every PR2. V0.10 reproduced the *latent* failure mode (a token that 403s → `_live_round_trip` `return 0`s → green asserting nothing), which is the **durable risk on PAT expiry/scope-strip** (V0.8 showed PATs expire mid-work), NOT the current state. The remaining real fix is therefore **(a) make `_live_round_trip` fail-closed under an enforce flag** (so expiry can't silently re-open it) and **(b) verify the existing PAT's scope + expiry** — the secret is already configured. Swap = `merge-pipeline-checks` OUT / `review-gate` IN on **both** sides; the swap is already guarded by the live R8 today, and the fail-closed fix makes that guarantee durable. Live-verify with **E6′** (drift → R8 RED).

**Mirror the ticket exemption to ALL coverage-lib consumers — BUILD a shared helper, do not copy-paste (review #4):** the `.tickets-tracker/**` diff-scoped exemption (A-4.5) is **greenfield in all three consumers** — `review-coverage-invariant.sh` (`_is_clean_merge`, no ticket logic), `verify-session-provenance.sh` (G3; `_vsp_is_clean_merge`, no ticket logic), and `fp-recovery-audit-sweep.sh` which has **NO clean-merge scaffolding at all** (nothing to mirror into — build from scratch). Implement ONE shared `rc_diff_is_tickets_only <sha>` helper (in `review-coverage-lib.sh` or a sourced lib) consumed by all three; the helper is identical, the per-script wiring honors each one's error posture (invariant fail-closes `return 2`; verifier routes-to-review). A divergence wedges or launders ticket-only SHAs. Live-verify **E14/E15 across all three**, not just the gate. <!-- # tickets-boundary-ok -->

**Harden the R8 live drift guard (P0 prerequisite of A-5 — peer to the exit-78 fix):** the secret `DSO_RULESETS_READ_TOKEN` is **already configured** and R8 already runs green in CI (verified, run 26901868917), so A-5 already HAS a live "did the provision take effect" signal today. The remaining work is durability, not activation: (1) make `_live_round_trip` **fail-closed under an enforce posture flag** — today it `return 0`s on ANY token/precondition failure (same silent-pass class as exit-78); in enforce a skipped live arm must FAIL, so a future PAT expiry/rotation/scope-strip cannot silently re-open the hole (V0.8: the golive PAT already expired mid-session); (2) **verify the existing PAT's scope (`Administration:read` / ruleset-structure read) and expiry**, and apply CS-7a credential hygiene + CS-19 least-privilege (see §2.10.1). (3) **Extend the exit-78 fail-closed-under-enforce fix to `ruleset-invariants.yml`** — it is the THIRD carrier of the 78→pass wrapper hole (CS-17) and, unlike the coverage/dangling wrappers, it gates an **already-required** check (`ruleset-design-invariants`); a token blip there silently green-stamps the drift guard A-5 leans on.

**`ruleset-design-invariants` test:** it does NOT pin the full required set (only I6=`check-staged-head`, I2=sub-PR check) — **a membership invariant is insufficient** to guarantee `review-gate ∈ live` after A-5. The full-set guarantee comes from the **reactivated R8** (above), not from adding another membership assertion. A-6 may still add a `review-gate ∈ required` membership invariant for fast-fail clarity, but R8 (live-reading, fail-closed under enforce) is the load-bearing parity guard. Update contract `plugins/dso/docs/contracts/review-defenses.md` in lockstep.

**`required-checks.txt` consumer sweep (A-5/A-6):** beyond `provision-ruleset.sh`/`validate-required-checks.sh`, also `promote-ruleset-required.sh`, `update-required-checks-manifest.sh`, `github-bootstrap.sh`, and tests `test-promote-ruleset-required.sh`, `test-provision-ruleset.sh`, `test-ruleset-provisioner-roundtrip.sh`, `test-github-bootstrap.sh`, `test-ci-enforcement-e2e.sh` — any that snapshot the list need updating.

**A-4.6 local-pipeline impact (expand):** tightening the allowlist changes **local** commit behavior (docs-only commits now require local review via `pre-commit-review-gate.sh` / COMMIT-WORKFLOW.md Step 0.5) — a real contributor-facing change for this repo's own doc edits. Consumers beyond the CI `changes` job: `pre-commit-review-gate.sh`, `pre-commit-test-gate.sh`, `pre-commit-ticket-gate.sh`, `compute-diff-hash.sh`, `review-complexity-classifier.sh`, `assert-review-liveness.sh`, `check-allowlist-correctness.sh`. Re-baseline tests: `test-review-gate-allowlist.sh`, `test-behavioral-equivalence-allowlist.sh`, `test-skip-review-check.sh`, `test-review-gate-config-doc-dirs.sh`, `test-compute-diff-hash-tickets*.sh`, and the `check-allowlist-correctness.sh` probe set.

**A-6 docs list (expand) — the doc set that goes stale:** add `WORKFLOW-STABILITY-CHECKS.md` (warn→enforce go-live + the new `review-gate`/subsumption), `contracts/review-defenses.md` (load-bearing for `ruleset-design-invariants`), `runbooks/rulesets-rollback.md`, `HOOKS-REFERENCE.md` + `CONFIGURATION-REFERENCE.md` (allowlist semantics), `workflows/COMMIT-WORKFLOW.md` Step 0.5 (local gate), `INSTALL.md` (Goal-4 / go-live + the `merge-pipeline-checks` ownership note), and `CLAUDE.md` (required-checks/go-live story). `CI-INTEGRATION.md` already named.

**Sprint preflight review-gate awareness (A-6):** `check-ruleset-preflight.sh` (sprint Phase A, ci-pr) asserts the main-ruleset checks; teach it about `review-gate` so a sprint validates against the post-Option-A ruleset. Confirmed clean of MQ residue; debug-everything skill also clean.

**A-7 PR1-title test:** `test-merge-to-main-pr.sh` asserts `gh pr merge` argv; the PR1-title-format change is net-new coverage (only PR2 title uses `_derive_pr_title` today) — add a PR1-title argv assertion; may touch `test-merge-to-main-pr-trailer-injection.sh`.

> Also fix ADR-0020 V0.6 row to name `merge-pipeline-checks` in the live required set and state the OUT/IN swap.

## 2.10 Review #4 (code-grounded adversarial) + confirming exploration + experiments — revisions of record

A fourth opus review opened the actual source for every load-bearing claim and queried live GitHub. Findings were then independently confirmed by read-only exploration and three experiments (V0.3a-reconfirm, V0.9, V0.10). Net effect on the plan:

**Corrections to claims we had wrong:**
- **§2.9 parity guard was self-contradictory and partly false.** `ruleset-design-invariants` only asserts MEMBERSHIP (`check-staged-head ∈ live`), not full-set parity. The real full-set live-parity guard is **R8** (`test-ruleset-provisioner-roundtrip.sh`), which is **inert in CI** because `DSO_RULESETS_READ_TOKEN` is unconfigured (V0.10 reproduced the green-skip). Fixed in §2.9 + new R8-reactivation prerequisite + A-5 gate item 2/3.
- **BLOCKER 2 (compute-diff-hash) overstated → downgraded.** The hardcoded `:!docs/**` is a degradation **fallback** only; the normal path uses the allowlist (so A-4.6's edit works). Residual = strip the fallback array too. Fixed in A-4.6.
- **C1 framing overstated.** `assert-review-liveness.sh` is a real always-run fail-closed cross-check; the true exposure is allowlist SCOPE, not "no review runs." Fixed in §2.6 NARROWED + A-4.5 reconciliation note.

**Re-scoping confirmed greenfield (not "mirror"/"edit"):**
- Ticket exemption is greenfield in all 3 consumers; `fp-recovery-audit-sweep.sh` has no clean-merge scaffolding → build a shared `rc_diff_is_tickets_only` helper (§2.9, A-4.5).
- `dangling-references` is git-grep today; the `sg` swap + E7 (0 FP) is BLOCKING for A-5 (A-4).

**Experiments run this session (read-only/local; live-mutation E6′ deferred while a PR is mid-merge):**
- **V0.3a-reconfirm** — `review-coverage-invariant.sh` exits 78 on a token blip; wrapper maps 78→0 unconditionally (`review-coverage-invariant.yml:64-66`). Hole reproduced.
- **V0.9** — R8 runs and passes (8/8) with a ruleset-read-scoped token; also re-confirms live `main` == `required-checks.txt` post-rollback.
- **V0.10** — with a token that 403s on the rulesets API (the CI condition), R8's live arm SKIPs and the test exits 0 (PASSED 6) — green asserting nothing about live. This is the operational core of BLOCKER 1.

**A-5 R8 prerequisite (superseded by §2.10.1 reconciliation):** the original framing here ("no working CI signal — R8 inert — configure the secret") was based on a stale local `gh secret list` and was **CORRECTED** by the two parallel reviews + CI-log verification. See §2.10.1. Detailed evidence ledger: `/tmp/option-a-review4-findings.md` → migrate to ADR-0020 V-series.

## 2.10.1 Reconciliation of the two parallel reviews against live state (2026-06-03, post-rollback)

Two opus reviews (grounding/accuracy + historical-gotchas) ran in parallel; their findings were reconciled against direct live reads (admin PAT) and CI logs. Net:

**CORRECTED (my prior claim was wrong):**
- **R8 is NOT inert in CI.** `DSO_RULESETS_READ_TOKEN` IS configured (created 2026-06-01); CI run `26901868917` shows the live arm ran green (`R7`/`R8` PASS, `PASSED: 8`). My earlier "secret unconfigured" came from a stale local `gh secret list` (no `-R`). So the live full-set parity guard **already enforces** on every PR2; V0.10 reproduced the *latent* expiry/scope-strip failure mode, not the current state. The real remaining work shrinks to: fail-close `_live_round_trip` under enforce + verify PAT scope/expiry. (§2.9, A-5 gate item 2 updated.)

**DISPROVEN by live read (historical review's headline worry):**
- The unmerged prior go-live `32819d767f` (branch `golive/enforce-coverage-dangling`) did NOT leave residual contexts on live. Live `main` ruleset 15629023 == exactly the 12 `required-checks.txt` contexts; **no `review-coverage-invariant`/`dangling-references` residue** (direct read). The reviewer's method (trust live `gh` over code) was right and is adopted as a Phase-0 step (below), even though the specific worry was false — it is the same method that caught my secret error.

**VALID — folded in:**
- **3rd exit-78 carrier (CS-17):** `ruleset-invariants.yml` has the same 78→pass wrapper and gates an *already-required* check — extend the exit-78 fail-closed fix to it (A-5 gate item 2 / §2.9).
- **Re-baseline against current `origin/main` (now `407d3f8473` after the rollback landed):** the worktree plan snapshot is behind; `merge-to-main-pr.sh` has moved further (e.g. this session's `36dd1a4ff2` CONFLICTING fast-fail, `acb17a3cef` empty-state PR discovery). Before the build phase touches merge-to-main, re-run the §4.2 per-file `git log <pre-MQ-sha>..origin/main` guard against current main, not the snapshot.
- **Token least-privilege / CS-7a hygiene:** the existing PAT already reads ruleset structure (R8 works), so the scope is sufficient; document the intentional divergence from CS-19's outcome-only `current_user_can_bypass` (full-set parity needs structure read), keep it read-only + rotated, and add the CS-7a probe (`git credential fill` + `gh api user` must NOT resolve to a bypass actor) to the A-5 gate.
- **Shared-helper equivalence test:** mandate a single shared-fixture test asserting all three ticket-exemption consumers return identical verdicts (the trailer-shortcut survived in one path after removal from another — same divergence risk).
- **Liveness skip-stub revalidation after A-4.6:** confirm `assert-review-liveness.sh`'s stub acceptance still fail-closes for the newly-reviewable `docs/**`/config paths (TS-1).

**NEW Phase-0 BLOCKING step (cheap insurance, honors the verify-live method):** before any A-5 planning, read the **live** ruleset 15629023 contexts with the admin PAT and diff vs `required-checks.txt`, explicitly checking for residual go-live contexts. (Done this session: clean — 12 contexts, no residue.)

**Grounding minors:** R8 phrasing corrected to "R5 (offline) ∧ R8 (live arm)"; §2.5 exit-78 cites should be tightened to `review-coverage-invariant.yml:64-66` / `dangling-references.yml:41-43` (the §2.10 cites are already exact).

**CONVERGENCE STAMP (stability review #6, 2026-06-03): `CONVERGED` — 0 NEW-BLOCKERS.** A dedicated convergence pass walked the A-5 OUT/IN swap as a state machine, the R5∧R8 parity chain, all three exit-78 carriers, and three previously-unexamined lenses (multi-PR concurrency during cutover, coverage-ledger cache-poisoning across the warn→enforce boundary, `strict_required_status_checks_policy:false` interaction) and found nothing both new and load-bearing. Every constructible risk was already captured with a settling experiment. Verdict: execute the already-specified greenfield pieces gated behind the named BLOCKING experiments (E6′, E7, E14/E15, V0.3a-post-fix). The only additions were two runbook sentences (now in A-5: land the swap with no other PR2 in flight; E7-underperforms fallback), not design changes. **Remaining un-verified-until-built assumptions** (all acceptable to defer, none a hidden fork except E7 which is already BLOCKING): E6′ confirms only the RED direction (mechanism already green in CI); E7 sg FP-rate is the one genuine rebuild-risk and is correctly elevated; the 3 exit-78/`_live_round_trip` fail-closed fixes + the shared ticket helper are architecturally settled greenfield.

## 3. Phase 0 — experimental verification

**Pre-flight V0.\* (DONE — results in ADR-0020):** V0.1 ✅, V0.2 ✅, V0.3a ❌(hole confirmed), V0.3b ✅, V0.3c ✅(empty-range only — see E8), V0.5 ✅, V0.5b ✅, V0.6 ✅, V0.7 ✅, V0.8 ✅, V0.4 ⚠️(partial).

**Post-review experiments (DONE 2026-06-03 — see §2.10/§2.10.1 + ADR V-series):** V0.3a-reconfirm ✅(hole reproduced: exit 78; wrapper maps 78→0 unconditionally), **V0.9** ✅(R8 live-parity arm works with a ruleset-read-scoped token — 8/8), **V0.10** ✅(LATENT failure mode reproduced: a token that 403s → live arm SKIP → exit 0 — this is the expiry/scope-strip risk, NOT the current CI state), **V0.11** ✅(CI-log verification, run 26901868917: R7/R8 run green in CI — secret IS configured, R8 already enforces live; corrects V0.10's framing), **V0.12** ✅(live ruleset 15629023 == 12 `required-checks.txt` contexts, no residual go-live contexts from unmerged `32819d767f`). **Still gated:** E6′ (mutates live `main` — run after the rollback lands & no PR mid-merge — rollback now LANDED `407d3f8473`), V0.3a-post-fix, E7 (post-`sg`), E14/E15 (post-helper), E-compute-hash (post-A-4.6).

**Review-#1 experiments E1–E9 (BLOCKING — must pass before A-5; these supersede the "enforce-flip is ready" assumption):**

- **E1 [BLOCKING — review semantics]** version-bump/allowlist provenance: a PR2 carrying an allowlisted-only commit that rode a real PR1 — does coverage classify it `verified` (laundered) or `unreviewed`? **Decision required:** is "covered by a PR whose review-check passed" acceptable, or must every byte be content-reviewed? If the latter → per-file coverage needed.
- **E2 [BLOCKING — skip-to-success]** an allowlisted-only PR2 (`docs/foo.md` + `plugin.json`) → does `llm-review` report success-without-review? (It will today.) Fix = force `code_changed=true` on `base==main` PRs OR the summary gate.
- **E3 [BLOCKING — no-op umbrella]** confirm `merge-pipeline-checks` red-test-blocker no-ops on a `staged-*` head → there is no always-runs fail-closed required check. Mandates the summary gate.
- **E4 [BLOCKING — exit-78 fail-closed-WITH-retry]** after the fix: scope-stripped token → block immediately; simulated transient 5xx/rate-limit → retry+PASS (do not wedge on one blip).
- **E5 [BLOCKING — ledger warm-hit/CF-6]** drop `github.run_id` cache key; force budget exhaustion mid-walk; re-run → `ledger_hits>0`, converges within K.
- **E6 [IMPORTANT — atomic provision/assert/A-5 ordering]** out-of-order (assert-then-provision) wedges `ruleset-design-invariants`; correct order green. Document where re-provision sits in the A-5 PR lifecycle.
- **E7 [IMPORTANT — dangling file-coverage + FP]** post-CF-8: reference-side scans `.md/.yml/Makefile/.txt`; FP rate acceptable on the 20-PR ground-truth set.
- **E8 [IMPORTANT — populated staged-merge-commit]** V0.3c only tested the empty range; test the real `staged-*` merge-commit head: clean merge → exempt (no false wedge); evil merge (manual edit in the merge commit) → RED.
- **E9 [IMPORTANT — in-flight session resume]** simulate `--resume` of a pre-rollback state file against the post-rollback script → either works or quiesce live worktrees before the `merge-to-main-pr.sh` rewrite. **Review #4: `worktree-20260602-154728` is GONE; `worktree-20260602-144432` (on `staged-c622ad2fcae4`) is live.** Re-confirm PR #593's draft-umbrella guidance in §4.4b before relying on it — its session no longer exists.

(Original V0.\* list retained below for reference.)

Verify ALL of these against live GitHub before Phase 1. Ordered so the items that, if false, mean **Option A also cannot ruleset-enforce the requirement** come first.

- **V0.3a [BLOCKING — R1 linchpin]** — `review-coverage-invariant` precondition path does NOT pass-through in enforce mode. Throwaway `staged-*`→`main` PR with one un-provenanced commit; run with `DSO_COVERAGE_INVARIANT_MODE=enforce` AND a scope-stripped token (force exit 78). **Pass = check RED.** (Today it goes GREEN — exit 78→0.) Failure ⇒ the central fitness claim is false until the wrapper is patched fail-closed.
- **V0.3b [BLOCKING]** — `review-coverage-invariant` fails-closed on a genuinely-uncovered file (enforce mode, un-provenanced SHA on PR2 → RED). Failure ⇒ the deterministic gate isn't a gate; neither MQ nor Option A works → escalate.
- **V0.3c [BLOCKING]** — `review-coverage-invariant` does NOT false-wedge a clean, fully-provenanced PR2 (staged merge commit hits the clean-merge exemption). Failure ⇒ enforcing wedges every legitimate promotion → S-11 ledger insufficient → block A-5.
- **V0.2 [BLOCKING — backstop]** — `llm-review` genuinely **re-reviews** un-provenanced files (not skip-all): introduce an un-provenanced file in a throwaway staged branch; observe `llm-review-dispatch-or-skip.sh` take the DISPATCH path (real runner), not SKIP. Failure ⇒ the content-aware backstop doesn't exist → raises V0.3a/b stakes.
- **V0.6 [BLOCKING]** — live MAIN ruleset (15629023) required set == `required-checks.txt`, AND the restored two-tier `ruleset-design-invariants` passes green against live AND on its own rollback PR (it is itself a required check). Failure ⇒ rollback PR2 wedges.
- **V0.1 [BLOCKING]** — two-tier `merge-to-main` works end-to-end on current `main` (flag OFF): throwaway feature→staged→main promotion completes. Failure ⇒ rollback baseline broken; fix first.
- **V0.7 [BLOCKING — fast]** — zero live MQ residue (live main has no merge_queue rule per R13; no live `gh-readonly-queue/*`; no MQ ruleset). 
- **V0.8 [IMPORTANT]** — a non-expiring admin credential exists (golive PAT already 401'd): admin PAT can read+provision rulesets; non-admin `gh` can run containment reads; expiry beyond the work window.
- **V0.5 [IMPORTANT]** — removing the 5 `merge_group:` triggers breaks no current required check: strip on a throwaway branch; every required context still reports green on a normal PR to main (they're inert).
- **V0.5b [IMPORTANT]** — removing the `event_name=='merge_group'` arm from `merge-pipeline-checks`'s `if:` does NOT change its firing on real two-tier PRs (before/after on a `staged-*`→main PR — runs identically via the base==main path).
- **V0.4 [IMPORTANT]** — `dangling-references` (sg-based, CF-8) FP rate acceptable on the 20-PR ground-truth set, AND its exit-78 enforce path blocks (mirror of V0.3a). Failure ⇒ enforcing wedges or silently passes → block A-5.

The 5 workflows carrying `merge_group:` triggers (name explicitly): `ci.yml`, `dangling-references.yml`, `review-coverage-invariant.yml`, `ruleset-invariants.yml`, `ticket-platform-matrix.yml`.

---

## 4. Phase 1 — Roll back the MQ changes (surgical, validated)

### 4.1 MQ commit inventory (on `origin/main`)

| Commit | Story | Disposition |
|--------|-------|-------------|
| `9e694c5a09` | MQ-1: ADR-0019 ratify + `merge_group` trigger fan-out | workflows: remove triggers; ADR + proposal: KEEP + annotate superseded; `test-mq-merge-group-triggers.sh`: DELETE |
| `b67443fcff` | MQ-2: gated merge_queue provisioning + drift | `provision-ruleset.sh`: remove merge_queue rule; `CONFIGURATION-REFERENCE.md`: remove `dso.merge_queue.enabled`; roundtrip test: remove R9–R13 |
| `7c2441354b` | MQ-3: dual-mode invariants | `test-ruleset-design-invariants.sh`: restore two-tier-only; `…-modes.sh`: DELETE |
| `cf072500eb` | MQ-3 fix (incidental robustness) | preserve `_require_json` / stderr surfacing IF still applicable to two-tier path (else accept loss — pre-MQ was already robust) |
| `10b717c9e1` | MQ-4a: wait-for-pr queue terminal-state | `wait-for-pr.sh`: remove `mergeStateStatus` + eviction wording; remove MQ test cases |
| `4cf3b2fe9a` | MQ-4b: flag-gated merge-to-main | `merge-to-main-pr.sh`: remove flag-gating + 3 branch points; `test-merge-to-main-mq-path.sh`: DELETE |
| `56eb23167d` | MQ-4 fix (behavioral test) | subsumed by deleting the mq-path test |
| `ec13fe09bb` | MQ-4 refactor (restructure flag gates) | subsumed; verify the 2 change-detector tests net-match pre-MQ |
| `a90ffd09b7` | MQ-5: dual-mode preflight | `check-ruleset-preflight.sh`: restore two-tier-only; remove MQ test cases |
| `42cadb23a5` | hardening C2/N1 | `ci.yml`: revert C2 SHA-capture + N1 comment (both reference `merge_group`) |

### 4.2 Rollback mechanism (per file — surgical, NOT blanket revert)

- **Pure-MQ new test files → delete:** `test-mq-merge-group-triggers.sh`, `test-ruleset-design-invariants-modes.sh`, `test-merge-to-main-mq-path.sh`.
- **Files only touched by MQ → restore the pre-MQ version** via `git checkout <pre-MQ-sha> -- <file>` after confirming no *later non-MQ* commit touched them: `provision-ruleset.sh`, `wait-for-pr.sh`, `merge-to-main-pr.sh`, `check-ruleset-preflight.sh`, `test-ruleset-design-invariants.sh`, the 5 workflows' `merge_group` blocks (surgical — keep all non-MQ workflow content).
- **Shared files → surgical section removal:** `CONFIGURATION-REFERENCE.md` (remove the `dso.merge_queue.enabled` entry), `test-ruleset-provisioner-roundtrip.sh` (remove R9–R13), `test-wait-for-pr.sh` (remove MQ cases), `test-check-ruleset-preflight.sh` (remove MQ cases).
- **Per-file guard:** before restoring any file, run `git log <pre-MQ-sha>..origin/main -- <file>` to confirm only MQ commits touched it; if a non-MQ commit did, switch that file to surgical edit to preserve the non-MQ change.

### 4.2.1 DO-NOT-TOUCH guards (opus review — destructive-edit risks)

- **`mergeStateStatus` is PRE-EXISTING two-tier logic — do NOT pattern-match-remove it tree-wide.** It exists pre-MQ in `plugins/dso/scripts/merge-to-main-pr.sh` (5×, BEHIND/CONFLICTING handling) and `tests/scripts/test-merge-to-main-pr.sh` (28×). Removal is correct **only in `wait-for-pr.sh`** (where MQ-4 introduced it; absent pre-MQ). Restore `merge-to-main-pr.sh` by region (the flag-gating blocks) to `9e694c5a09^`, NOT by deleting `mergeStateStatus`.
- **`tests/scripts/test-merge-to-main-pr.sh` — leave UNTOUCHED.** Not an MQ file; its queue/auto-merge references are pre-MQ.
- **`merge-to-main-pr.sh` restructure (`ec13fe09bb`) rolls back to `9e694c5a09^` structure, not ec13's.** After restore, confirm the two change-detector tests (`test-merge-to-main-resume-existing-pr-discovery.sh`, `test-merge-to-main-pr-resume-and-stale.sh`) match `9e694c5a09^`.
- **`merge-pipeline-checks` `if:` arm:** MQ-1 added `github.event_name == 'merge_group' ||` to the job-level `if:` in `ci.yml`. Remove that clause surgically (verify via V0.5b) — it is separate from the C2 SHA-capture revert.
- **PRESERVE `cf072500eb`'s `_require_json` + gh-stderr-to-fd2** in the restored two-tier `test-ruleset-design-invariants.sh` — it is NET-NEW robustness (absent pre-MQ); do not accept its loss.
- **CF-6 cache-key fix (drop `github.run_id`) is a HARD precondition of A-5**, not merely "before" — enforcing a check whose ledger never warm-hits across re-runs wedges the team.
- **Phase 1 is CODE-ONLY.** The live ruleset is touched exactly ONCE, at A-5 (to ADD the two backstops). Do not re-provision live during rollback.

### 4.3 Docs & decision record

- **Keep** `docs/adr/0019-…md` and `docs/designs/ci-pr-process-remediation-proposal.md`; add a header banner: `Status: SUPERSEDED (2026-06-03) — not adopted; see ADR-0020. Live validation showed llm-review cannot be a ruleset-enforced merge_group check.`
- **Add** `docs/adr/0020-two-tier-hardening-over-merge-queue.md` recording the Option A decision + the validation evidence.
- **Update** `CLAUDE.md` / `CI-INTEGRATION.md` references to remove any MQ-as-current-direction language.

### 4.4 Tickets

- Close `MQ-6` (9b07) as `wont-fix`/superseded with rationale.
- Annotate the closed MQ-1…MQ-5 stories: "reverted 2026-06-03 — see Option A pivot; code preserved in git history."
- Keep `S-11`, `CF-6`, `CF-8` open (they become Option A's P0 work).
- Create an **Option A epic** (or repurpose 1a6c) with stories: A-1 rollback, A-2 S-11, A-3 CF-6, A-4 CF-8, A-5 enforce-flip-on-PR2, A-6 validation+docs.
- Keep the Node-20 ticket (d205) — unrelated.

### 4.4b Cleanup: stray sprint draft umbrella PRs

`create-sprint-draft-pr.sh` (sprint Phase A) opens a **long-lived draft session→main PR** (the `GitHubPRDefenseStore` substrate). These linger and, with arbitrary worktree branch names, read as "erroneous Draft `worktree-*`→main PR" to anyone scanning the repo. As part of cleanup:
- Detect open draft `*`→`main` PRs (`gh pr list --state open --draft --base main`); for any that are stale/orphaned sprint umbrellas (no active session), **close them**. (At plan time: none currently open — but make this a standing cleanup + see the A-7 root-cause fix.)
- Do NOT close a draft umbrella for an actively-running session (e.g. `worktree-20260602-154728`, PR #593's session) — coordinate, since "this work takes priority" but other sessions' substrate PRs are load-bearing for their defense store.

### 4.5 Land + live-validate the rollback

- Land the rollback via the two-tier flow (one or a few PRs).
- **Live checks:** after landing, confirm (a) the live `main` ruleset unchanged + still two-tier; (b) `ruleset-design-invariants` passes against live; (c) a throwaway two-tier promotion still completes; (d) `grep -ri "merge_queue\|merge_group\|DSO_MERGE_QUEUE" plugins/ tests/ .github/` returns only the annotated ADR/proposal.

---

## 5. Phase 2 — Implement Option A (harden the two-tier flow)

> Sequenced so the **ruleset-enforced review gate is never weakened** at any point.

- **A-2 (S-11):** admin-exemption ledger for `review-coverage-invariant` (reviewed-equivalent entries, audit metadata, HMAC-signed). Without it, the first admin bypass after enforce wedges all future PRs. Land + **live-verify**: bypass → exempt → next-PR-passes.
- **A-3 (CF-6):** coverage-invariant stable cache key (drop `github.run_id`), save-always + merge ledger, bounded API backoff, budget-convergence retryable status. Land + **live-verify**: budget exhaustion → re-run warm-hits partial ledger → converges within K re-runs.
- **A-4 (CF-8):** `sg`-based dangling matcher (guarded fallback), reference-side scans `.md/.yml/Makefile/.txt`, short-symbol guard. **Confirmed greenfield (review #4): `check-dangling-references.sh:20-21` is a git-grep stopgap today** — the `sg` swap is a HARD prerequisite of adding `dangling-references` to `required-checks.txt` (git-grep FPs on comments/strings → enforce-flip would wedge). Land + **live-verify** FP rate on the 20-PR ground-truth set (E7 — BLOCKING for A-5).
- **A-4.5 (NEW — build the fail-closed summary gate; bounded per the E1=per-SHA decision):** create a single required check `review-gate` implemented as **ONE script** (NOT a `needs`/`if: failure()` aggregation — that greens on a *skipped* upstream; NEW-4/E13) that **always runs on `base==main` PRs** (no `code_changed` skip) and is the sole always-runs fail-closed required review check on PR2. It:
  1. **fails-closed unless every SHA in `origin/main..head` is proven reviewed** by the existing per-SHA `review-coverage-invariant` (a covering merged PR's review-check = success), **except** SHAs whose diff is entirely within `.tickets-tracker/**` via the shared `rc_diff_is_tickets_only` helper (ticket-data exemption, diff-scoped; §2.9) — closes C1/E2; honors the ticket-exclusion decision; prevents ticket-sync wedge; <!-- # tickets-boundary-ok -->
  - **Reconcile with liveness, do not duplicate it (review #4):** `assert-review-liveness.sh` already runs unconditionally on PR2 and fail-closes when a non-allowlisted file rides a `code_changed=false` PR (§2.6 NARROWED). The summary gate's job is the **per-SHA coverage proof** liveness does NOT do; it must not re-implement liveness's classification cross-check. Define the boundary explicitly so the two gates are complementary, not redundant.
  2. runs `dangling-references` inline (same script) so it cannot independently skip-to-success;
  3. fail-closes on precondition with **bounded retry** (config-error → block; transient 5xx/rate-limit → retry then block — closes exit-78/E4) and warm-hits the CF-6 ledger (E5);
  4. replaces the no-op `merge-pipeline-checks` umbrella as the always-runs fail-closed gate on PR2 (closes E3).
- **A-4.6 (allowlist tightening, per E1 decision):** audit `review-gate-allowlist.conf` (+ `skip-review-check.sh`); remove `docs/**`, skills, and behavior-driving config from the skip set so they become reviewable; KEEP only genuinely-inert artifacts (images, lockfiles, generated) AND `.tickets-tracker/**` (ticket data). TDD: a docs-only PR now yields `code_changed=true` (reviewed); a tickets-only commit stays exempt. **Live-verify E2/E11/E14.** <!-- # tickets-boundary-ok -->
  - **Two-file edit, not one (review #4):** the allowlist `conf` is the normal-path source of truth (so the edit DOES change behavior — BLOCKER 2 was overstated), BUT `compute-diff-hash.sh:142-151` keeps a **hardcoded `_FALLBACK_PATHSPECS`** (incl. `:!docs/**`, `:!.claude/docs/**`) used in the degradation else-branch (`:160-163`) when the allowlist fails to load. Strip `docs/**`/`.claude/docs/**` from that fallback array too, so the degraded path matches the tightened normal path; re-baseline `test-compute-diff-hash-tickets*.sh`. (The two consumers already share `dso_sanitized_doc_dirs`/`config-paths.sh` by design — `:174-187` — so the normal-path divergence risk is already guarded; this is only the degradation path.) Add **E-compute-hash**: identical file list incl. `docs/foo.md` → `skip-review-check.sh` and `compute-diff-hash.sh` classify docs identically.
  Land the gate in `warn`/advisory first; **live-verify E1-decision behavior, E2/E3/E8/E11/E13/E14** before flipping enforce.
- **A-5 (enforce-flip — the summary gate):** add `review-gate` (and retain `llm-review`) to `required-checks.txt`; re-provision the live `main` ruleset (admin PAT) in the **atomic order verified by E6** (provision precedes the `ruleset-design-invariants` assertion update within the A-5 PR lifecycle, or the PR wedges itself). **Live-verify:** an allowlisted-only PR2 with un-reviewed content is BLOCKED (not skip-to-success); a clean fully-reviewed PR2 passes; a real combined-state issue is BLOCKED; no false wedge (E2/E3/E8). Do NOT add the `review-coverage-invariant`/`dangling-references` backstops to `required-checks.txt` individually (they are not there today — I-4); the summary gate subsumes them.
  - **Runbook (stability review §6 — repo-wide blast radius):** land the A-5 swap PR with **no other PR2 in flight.** `ruleset-invariants.yml` fires on every PR to main with no path filter, and the live provision is a global mutation — during the live↔`required-checks.txt` skew window R8 goes **RED on every concurrent PR2**, not just the swap PR. Quiesce other promotions, provision live, land the file-PR fast.
  - **A-5 HARD PREREQUISITE GATE (do not flip until ALL green — revised by review #4 + experiments):**
    1. exit-78 fail-closed fix landed in **both** `review-coverage-invariant.yml` AND `dangling-references.yml` (V0.3a-post-fix re-run RED);
    2. **R8 hardened** — secret already configured + R8 already green in CI (run 26901868917); remaining: `_live_round_trip` fail-closed under enforce + verify PAT scope/expiry + apply the same fail-closed fix to the 3rd carrier `ruleset-invariants.yml` (CS-17);
    3. **E6′** passed — live drift (review-gate IN / merge-pipeline-checks OUT but `required-checks.txt` NOT updated, and the reverse) → a required check actually goes **RED**;
    4. **E7** passed — `sg`-based dangling matcher (A-4) at **0 FP** on the 20-PR ground-truth set (git-grep would FP-wedge — E7 is BLOCKING, not optional). **Fallback if `sg` can't hit an acceptable FP rate:** ship `review-gate` with `review-coverage-invariant` ENFORCED and `dangling-references` ADVISORY (warn) — E7 underperformance degrades scope, it does NOT invalidate the architecture or block the rest of A-5;
    5. **durable admin PAT** secured (the golive PAT 401'd mid-session — V0.8).
- **A-6 (validation + docs):** full two-tier promotion through the enforced summary gate; update `ruleset-design-invariants` to assert the new required set; record the per-SHA-vs-per-file semantics decision (E1) in ADR-0020; update docs; completion verifier; close the epic.

- **A-7 (two-tier-flow UX/correctness fixes — non-MQ defects surfaced this session):**
  - **PR1 descriptive titles.** `merge-to-main-pr.sh:938-939` (review #4: not :966) hardcodes `_pr1_title="staged: ${BRANCH} -> ${_staged_branch}"` — a generic, non-descriptive title (e.g. PR #593: `staged: worktree-20260602-154728 -> staged-515e4a07cfa7-…`). Fix: derive the PR1 title from the branch's meaningful commit subject (reuse `_derive_pr_title`, the same helper PR2 already uses) with the `staged:` prefix retained for filterability — e.g. `staged: <descriptive subject>`. TDD via the gh-stub harness in `test-merge-to-main-pr.sh` (assert the `gh pr create --title` argv for PR1 is descriptive, not the branch-arrow form). **Live-verify:** a throwaway promotion's PR1 shows a descriptive title.
  - **Sprint draft umbrella PR.** Review `create-sprint-draft-pr.sh`: (a) give it a descriptive title/body (epic title, not just `Long-lived sprint draft PR. Epic: {{id}}`); (b) confirm its lifecycle closes the draft at sprint end (or document why it is long-lived) so stale `worktree-*`→main drafts don't accumulate; (c) since Option A KEEPS the two-tier flow, this script is **retained** (the MQ-6 plan to retire it is void). **Live-verify:** a sprint Phase A creates a clearly-labeled draft that is cleaned up at session close.
  - Both are independent of the enforce-flip and can land any time after Phase 1; group them so a single PR carries the two-tier UX fixes.

**Note:** A-5 must not land before A-2/A-3/A-4 are verified — enforcing a flaky/wedge-prone check would block the whole team's promotions (the exact reason these were P0 prereqs).

---

## 6. Live-validation checkpoint summary

| Step | Live-GitHub validation |
|------|------------------------|
| Phase 0 | V0.1–V0.7 (above) — ALL verified before Phase 1 |
| Phase 1 rollback | ruleset unchanged; invariants pass; two-tier promotion works; no MQ residue |
| A-2 S-11 | bypass→exempt→next-PR-passes |
| A-3 CF-6 | budget exhaustion converges within K re-runs |
| A-4 CF-8 | FP rate acceptable on ground-truth PRs |
| A-5 enforce-flip | real combined-state issue BLOCKED; clean passes; no false wedge |
| A-6 closure | full enforced two-tier promotion green end-to-end |

---

## 7. Open questions / risks

- **R1 (load-bearing):** is `review-coverage-invariant` airtight enough to be THE ruleset-enforced review gate? If it cannot be made FP-free AND gap-free, neither MQ nor two-tier can ruleset-enforce the requirement — this is the real risk and must be settled in Phase 0 (V0.3) / A-2…A-4.
- **R2:** the un-provenanced `llm-review` backstop (V0.2) — confirm it works today and remains intact after rollback.
- **R3:** rollback ordering — must not transiently break a live required check (e.g., reverting `provision-ruleset.sh` must not be paired with a live re-provision that drops a required check).
- **R4:** credential — secure a non-expiring admin token before starting (golive PAT already expired).
