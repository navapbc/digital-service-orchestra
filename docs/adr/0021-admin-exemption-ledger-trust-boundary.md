# ADR-0021: Admin-exemption ledger trust boundary (C3)

- **Status:** Superseded by ADR-0022 (identity-based admin exemption). The HMAC-signed-ledger approach this ADR hardened is replaced by a server-set `merged_by ∈ bypass-actor-set` check — no signing key, no PAT, per maintainer direction. The trust-boundary threat this ADR addressed (agent forging a signed row) evaporates by construction. Retained for history.
- **Date:** 2026-06-04
- **Epic/Story:** 588e / 3ebb DD4 unit 5 (C3 — the security gate on G-A key provisioning)
- **Supersedes/relates:** ADR-0020 (two-tier hardening), story 2730 (admin-exemption ledger mechanism), 3ee4 P8c (enforce-flip gate)

## Context

DD4 wired the admin-exemption ledger into **both** Goal-1 gates so an FP-recovered SHA is treated as reviewed-equivalent:
- `review-coverage-invariant.sh` → `ael_sha_is_exempt` (units 1–3; no class filter)
- `verify-session-provenance.sh` → `ael_sha_is_exempt "$sha" "fp-recovery"` (unit 5; drives the `llm-review` dispatch decision)

Ledger entries are HMAC-SHA256 signed. `ael_key_file()` resolves the key as `DSO_ADMIN_EXEMPTION_KEY_FILE` (env) **else** the repo-local `.tickets-tracker/.closure-key`. The recorder (`fp-recovery-record-exemption.sh` → `ael_append`) runs **agent-local today** (FP-RECOVERY-WORKFLOW.md Step 5c). Today this is inert: the key is **not** provisioned to CI (gap G-A), so `ael_sha_is_exempt` fails closed. **G-A — provisioning the key — is what arms both consults.**

### The threat G-A would open (why C3 gates G-A)

The `.closure-key` is **agent-reachable** (local tickets orphan; `ael_key_file` falls back to it). If the **same** key both signs ledger entries **and** is reachable by the dev/sub-agent, then once G-A provisions that key to CI's verification jobs:

> A non-bypass agent can mint an HMAC-valid exemption for an **arbitrary, un-reviewed SHA** and **piggyback** it onto a *legitimately* bypass-merged FP-recovery PR. The human bypass-actor merges the PR; the forged row lands on the base branch; every later PR carrying that SHA passes both Goal-1 gates **with no review and no override**.

The agent being non-bypass does **not** close this — it launders through a human's legitimate merge. C1 (the code-enforced opus-gate, `fp-recovery-record-exemption.sh:54-93`) narrows the forged-`--reviewer-hash` path but **cannot** close a wholly-fabricated findings file when the *signing key itself* is agent-reachable (the documented C1 RESIDUAL, `:54-62`). Verified by the panel against the live code.

## Decision

C3 makes the signing-key boundary an **enforced control**, not agent discipline. The control is **key separation + human-held signing key**, NOT a new CI signer (the panel rejected CI-side signing — see Alternatives). Two load-bearing parts gate G-A; two are backstops.

### Part 1 (load-bearing) — Key separation, fail-closed

The ledger key MUST be a **dedicated secret** (`DSO_ADMIN_EXEMPTION_KEY_FILE`), distinct from `.closure-key`. `ael_key_file()` **removes the `.closure-key` fallback**: it returns the dedicated key if `DSO_ADMIN_EXEMPTION_KEY_FILE` is set, else **fails (rc 1)**. Both `ael_append` (sign) and `ael_sha_is_exempt` (verify) therefore require the dedicated key to be explicitly provisioned; absent it they fail closed (no signature / not exempt — the same inert behavior we have today, so this does not regress current safety). This removes the forge primitive: an agent whose environment lacks the dedicated key cannot sign **any** valid row.

- **New RED test required** (the absent-key path changes from "silently sign with `.closure-key`" to "fail closed"). Existing AEL tests all set `DSO_ADMIN_EXEMPTION_KEY_FILE` explicitly, so none break; none currently cover the no-env path.
- **Code/doc touch:** the `admin-exemption-ledger.sh:19-29` header ("same key file `.closure-key`… the SAME secret used to prove verifier verdicts") becomes misleading after this change and MUST be rewritten to document the two-key split + a `# do not restore the .closure-key fallback — it reopens the forge hole (ADR-0021)` guard at `ael_key_file`.

### Part 2 (load-bearing) — Human-held signing key (NOT a CI signer)

The dedicated key is held in exactly two trusted places: **(a) the human bypass-actor's environment** (to sign) and **(b) CI's gate-verification jobs as a secret** (to *verify* only, via G-A). The dev/sub-agent's session has **neither**. Signing stays where it is today — **inline, synchronous, riding the FP-recovery PR** — but the *signer* is the human bypass-actor, not the agent:

- The agent runs FP-recovery, clears the opus-gate, and **prepares** the exemption request (SHA set + `--reviewer-hash` + `--findings` + reason) and the merge link. It does **not** sign.
- The human bypass-actor (who already performs the manual web-UI merge) runs the recorder with their key (`DSO_ADMIN_EXEMPTION_KEY_FILE=<their key>`), which **re-enforces the C1 gate** then signs, commits the row onto the base branch **as part of the FP-recovery PR they are bypass-merging**, and merges.

Because the exemption row rides the *same* PR the human is overriding, it is covered by that **one** override — no separate unreviewed commit, **no infinite-regress** (cf. the CI-signer's fatal flaw), **no async race** with PR2's coverage walk, **no automated bypass identity on a protected branch**. This preserves the single-override fitness goal with *less* machinery than today's design, not more.

**Single-override scope (convergence review Q2).** For a **PR2** (staged→main) FP-recovery the row rides PR2 and is covered structurally by that one override. For a **PR1** (source→staged) FP-recovery the row is committed onto `staged`; the single-override guarantee then holds *provided the PR1 row lands on `staged` before PR2's coverage walk runs* — a **procedural precondition** Step 5c already states ("on the `staged-*` branch after the web-UI merge and before PR2 opens"). If that ordering is violated, the outcome degrades only to the pre-existing "second override needed" baseline — never to a forged exemption. A future hardening MAY make this structural (block PR2 open until the PR1 exemption is present on `staged`).

**Signer-failure fallback (convergence review fitness-4).** Human-side signing is synchronous and fails LOUD (the recorder exits 2 on a missing/unreadable key, `:117-125`). If the human's sign+commit step fails or is skipped *after* the bypass-merge, the recorder is simply re-run and the row committed onto the base branch before the next walk — there is no silent no-op and no async window. The fallback is "re-run the recorder," not a new mechanism.

**CI-verify-secret containment (convergence review Q1, a G-A provisioning constraint).** `ael_append` will sign wherever the dedicated key is present, so the CI copy of the key MUST be provisioned **verify-only**: it must not be exposed to any agent-influenceable job context (`pull_request_target`, a step that echoes env, a job the agent's diff can alter). G-A's provisioning checklist owns this constraint.

### Part 3 (backstop) — Reviewable ledger

`.admin-exemption-ledger` stays review-required (it is not allowlisted — confirmed). The row is visible in the FP-recovery PR diff; the same human override that clears the PR covers the ledger change. No regress because the row is never a standalone post-merge commit.

### Part 4 (backstop, DEFERRED — does NOT gate G-A)

The `fp-recovery-audit-sweep.sh` tamper-evident markers remain as-is (a reporting tool). A reconciliation matcher (ledger row ↔ bypass marker) is **deferred**, NOT a go-live gate, because as scoped it would (a) build on an unwired tool, (b) lack a join key (markers are keyed on `merge_sha`, rows on commit SHA), and (c) invert the `review_status` polarity (a legitimate bypass is exactly `missing`/`failed`). If ever built, it must be wired into a workflow + `required-checks.txt` + guarded by a new `no-dormant-security-check.sh` predicate so it cannot ship dormant.

### Invariant (load-bearing)

**Ledger-honoring is reviewed-equivalent ONLY while the signing key is unreachable by the dev/sub-agent.** A regression to agent-reachable signing re-opens the v4-class self-attestation hole (the trailer laundering removed in commit `711c3cc9b7`). Part 1's fail-closed `ael_key_file` + the `do not restore the fallback` guard enforce this.

## Consequences

- **Positive:** the agent cannot forge a valid exemption (no signing key); the single-override benefit is preserved exactly as today (inline, synchronous, on the FP-recovery PR), now *safely*. Defense-in-depth: forge-prevention (1,2) + review visibility (3); detection (4) deferred.
- **Migration:** the in-tree `.admin-exemption-ledger` on main has **0 data rows** today — switching the verification key to the dedicated key needs **no re-sign** (it starts empty at G-A cutover). Note the per-environment (`.closure-key`) → org/CI-secret property change is acceptable precisely because only the human + CI-verify hold the key; no agent environment does.
- **Negative / cost:** one dedicated secret to provision (G-A, admin) to CI-verify + the human bypass-actor's environment; an `ael_key_file` fail-closed change (+ RED test) + a header rewrite; a FP-RECOVERY-WORKFLOW.md Step 5c edit (agent prepares, human signs). No new workflow, no protected-branch automation.
- **Gate:** ADR-0021 + Part 1 (fail-closed key separation, tested) + the Step 5c human-signer doc = the C3 precondition that unblocks **G-A**. G-A then unblocks single-override-live validation → the 3ee4 enforce-flip (P8c). Ordering **C3 → G-A → P8c** matches 3ee4's stated gate.

## Alternatives considered

- **CI-side signer (rev. 1 of this ADR, REJECTED):** a workflow that signs + commits the exemption onto the base branch on bypass-merge. Rejected by the panel: it commits to a *protected* branch (the only precedent, `reconcile-bridge`, writes to the *unprotected* `tickets` orphan), forcing either a new automated bypass identity on `main` (contradicting Goal-4 containment) or an **infinite-regress** where the signer's own unreviewed commit fails the next coverage walk; plus an async race that reintroduces the second override invisibly until enforce-flip. Disproportionate machinery for a rare escape valve.
- **Reviewable-ledger alone (no key separation):** an LLM reviewer cannot feasibly verify each signed row maps to a real cleared review → weak against a piggybacked forgery. Kept only as backstop (Part 3).
- **Reviewer-identity-signed findings:** closes the fabricated-findings residual at its root but is a large cross-cutting change to the review subsystem. Deferred; Part 1+2 achieve the needed trust property for the ledger path.
