# ADR-0022: Identity-based admin exemption (supersedes ADR-0021)

- **Status:** Accepted (rev. 2 — incorporates the 3-lens panel)
- **Date:** 2026-06-04
- **Epic/Story:** 588e / 3ebb DD4 (override-propagation) — re-architecture per maintainer direction
- **Supersedes:** ADR-0021 (admin-exemption ledger trust boundary / C3) and the HMAC-signed-ledger propagation mechanism from story 2730 + DD4 units 1–5.

## Context

DD4 made an admin FP-recovery override *propagate* (so a single override is not re-demanded at every tier) via an HMAC-signed `.admin-exemption-ledger`: a SHA is reviewed-equivalent if the ledger carries a valid signed row for it. That forced the question *who holds the signing key?*, which produced ADR-0021 (key separation + a human-held key) + the C1/C2/C3 controls — all to stop a non-bypass agent from forging a signed row.

**Maintainer direction (2026-06-04):** *"The bypass actor is a designated human admin merging via the GitHub UI. No persistent admin PAT should be required."* The override must be **purely the human admin's web-UI merge** — no signing key, no PAT, no recorder command. The HMAC-ledger violates this (someone must sign each exemption).

The HMAC ledger is **inert on `main` today**: gap G-A (provisioning the key to CI) was never done, both consults fail closed for lack of a key, and `.admin-exemption-ledger` is not even tracked on `main` (a header-only stub with 0 data rows exists only on feature branches). So this supersession removes **dead-but-wired** code — the lowest-risk class — with no live data to migrate and no behavior to preserve.

## Decision

Replace the HMAC-signed ledger with an **identity-based exemption** derived from the merge the designated bypass-actor already performs.

**Rule:** when a coverage/provenance gate walks a SHA that is not otherwise covered, it resolves the SHA's covering merged PR (the lookup both gates already do) and treats the SHA as reviewed-equivalent **iff that PR's `merged_by.id` is in the configured bypass-actor set** (see *Bypass-actor set* below). Per the actual gate layering (`review-coverage-invariant.sh:164-186`: clean-merge → perf-ledger-hit → admin-exemption → `rc_sha_is_reviewed`), this is an **early short-circuit** occupying the exact slot `ael_sha_is_exempt` holds today — checked before the review walk, behavior-equivalent on the "covered" decision.

**Forge-proof by construction.** The named bypass user(s) are the *sole* ruleset bypass actor(s) (`provision-ruleset.sh:279` emits a single `User` actor); the agent runs under a token where `current_user_can_bypass: never` (outcome-verified live by `test-ruleset-design-invariants.sh` I4/I7). The agent therefore *cannot* merge a check-failing PR and *cannot* appear as `merged_by` on a bypassed merge — `merged_by` is set server-side by GitHub, not client-assertable. There is no key to reach, no row to fabricate. This **satisfies the v4/2730 anti-self-attestation lesson by a stronger means**: v4 (commit `711c3cc9b7`) forced provenance onto server-side facts (the covering-PR API + review check) and away from agent-written claims (the DSO-Story trailer); `merged_by` is exactly such a server-side fact. ADR-0021's entire threat model (agent forging an HMAC row / a fabricated findings file) and its load-bearing "signing key must stay agent-unreachable" invariant **evaporate** — there is no key whose reachability must be policed.

### Bypass-actor set (panel: single-actor is bus-factor-1)

The gate compares `merged_by.id` against a **set**, not a scalar: config `ruleset.bypass_user_ids` (comma-separated numeric IDs; env `DSO_RULESET_BYPASS_USER_IDS`), defaulting to the single `ruleset.bypass_user_id` when the set is unset (back-compat). This covers multi-maintainer teams (more than one trusted merger) without a per-incident wedge. The set holds **human user IDs only** — NOT automation/app IDs (see *merge-actor boundary*).

### Merge-actor boundary (panel: auto-merge / merge-queue)

An admin **bypass** is, by nature, a **manual web-UI merge of a check-failing PR** — GitHub sets `merged_by` to that human. The exemption path fires only for this case. By contrast:
- A **passing** PR completed by GitHub **auto-merge** or the **merge queue** (ADR-0019) carries `merged_by` = the enabling agent or a queue/app actor — but such a PR is **covered via the review path** (`rc_sha_is_reviewed`: a passing review check-run on the covering PR), which does **not** depend on `merged_by`. So queue/auto-merge completions of reviewed PRs clear correctly regardless of merge actor.
- Therefore automation actors are deliberately **excluded** from the bypass set: a merge an app completed was not a human bypass. If `merged_by` is `null` or an app id, the exemption path simply does not fire → the SHA falls through to the review walk → **fails closed** (blocks / "second override"), never silently exempted.

This means the override-propagation benefit holds for the **manual bypass** case (the FP-recovery path, `FP-RECOVERY-WORKFLOW.md` Step 5); auto-merged/queued PRs never needed it (they're reviewed).

### Components

Change (small, but at **three** sites — the two covering-PR filters are intentionally NOT consolidated and carry a standing "KEEP IN SYNC" hazard):
- **Extend the covering-PR filters** to surface `merged_by.id` (currently they emit only `number`/`state`/`merged_at`/`head.sha`/`merge_commit_sha`): `plugins/dso/scripts/lib/review-coverage-lib.sh` (`rc_sha_is_reviewed`, ~:61-95) and `plugins/dso/scripts/verify-session-provenance.sh` (covering-PR block, ~:562-606). **Zero new API calls** — `merged_by` rides the `commits/{sha}/pulls` object already fetched. Each filter must treat `merged_by == null`/absent as not-exempt (fail closed).
- **Replace** the `ael_sha_is_exempt` consult at `review-coverage-invariant.sh:179` and `verify-session-provenance.sh:438` with "`merged_by.id` ∈ bypass set".
- **Read the bypass set** from config inside the gates; fail closed (not exempt) when unset/unresolvable.
- **Audit trail:** add `merged_by.id` to `plugins/dso/scripts/ci/fp-recovery-audit-sweep.sh` markers (currently `pr|merge_sha|merged_at|review_status`). A marker with `review_status != passed` AND `merged_by` ∈ bypass set *is* the identity-exemption audit record.
- **Liveness gate (replaces P-AEL / P-AEL-PROVENANCE):** add a `P-IDENTITY-EXEMPT` predicate to `no-dormant-security-check.sh` + a CI liveness test that injects a synthetic `merged_by == <bypass id>` covering PR and asserts the gate treats the SHA as exempt **in the CI environment**. This mirrors the ledger-liveness test 2730/DD4 mandated; retiring the old dormancy guards without a replacement would re-create the "unguarded silent-skip" failure DD4 exists to kill.

Acceptance criteria (implementation, from the convergence review):
- **Per-element validation:** each token of `ruleset.bypass_user_ids` MUST match `^[0-9]+$` or be discarded; an empty/malformed token must not widen membership (mirror the scalar guard at `provision-ruleset.sh:270-273`). An empty resolved set → fail closed.
- **P-IDENTITY-EXEMPT must drive the PRODUCTION filter, both polarities:** the liveness test exercises the real `rc_sha_is_reviewed` / verifier covering-PR code (NOT a mock reimplementation) and asserts BOTH `merged_by ∈ set → exempt` AND `merged_by ∉ set → NOT exempt`, so it cannot pass while the real `merged_by` extraction is broken.
- **Config reference:** add the `ruleset.bypass_user_ids` stanza to `dso-config.reference.conf` + CONFIGURATION-REFERENCE.md.

Retire (net deletion; all inert on `main`):
- `plugins/dso/scripts/ci/admin-exemption-ledger.sh`, `plugins/dso/scripts/ci/fp-recovery-record-exemption.sh`, the `.admin-exemption-ledger` file (not tracked on `main`), `DSO_ADMIN_EXEMPTION_KEY_FILE` / gap **G-A**, the C2 `exempt_by` class filter, and the old P-AEL / P-AEL-PROVENANCE predicates.
- **ADR-0021 → Superseded;** C1/C2/C3 → obsolete (no key, no signing, no class).
- The two-tier ordering precondition (ADR-0021 §"single-override scope") is **removed structurally**: PR1's commits, when PR2's coverage walk resolves them, map to PR1's covering merged PR whose `merged_by` ∈ the bypass set — cleared with no row and no ordering hazard.

### Drift-lock reality (panel: the claim was overstated)

`ruleset-design-invariants` drift-locks the **containment outcome** (`current_user_can_bypass: never` for the agent token; I4/I7, outcome-based) — it **deliberately does NOT** introspect the live ruleset's bypass-actor *identity* (admin-read-only; `test-ruleset-design-invariants.sh:340-344`; the former I8/I9 identity lock was dropped per CS-19). So nothing live-asserts that the configured bypass set equals the live ruleset's bypass actor(s). The failure mode of any config↔live mismatch is **fail-closed**, never fail-open:
- Config names the wrong/missing user → a legitimate admin merge isn't recognized → SHA blocks ("second override"). Safe.
- Live ruleset fell back to `RepositoryRole:admin` (id 5) → `merged_by.id` is always a *user* id, never `5`, so no merge ever matches → fail-closed. Safe.

**Required follow-up (not a go-live blocker for warn-mode):** add an **admin-run actor-identity assertion** (the bypass set ⊆ the live ruleset `bypass_actors`) on the admin token path 3ee4 DD2 already uses, so a stale config surfaces as an explicit failure rather than mysterious wedges. The ADR does NOT claim the identity is already drift-locked.

### The C1 trade-off (preventive → detective — explicit)

Today C1 *code-enforces* (preventively) that a cleared opus review backs each exemption: `fp-recovery-record-exemption.sh` verifies `--reviewer-hash` + 0 blocking findings and **refuses to sign** otherwise. Under identity-based, the exemption derives **purely from who merged** — nothing in the gate verifies a review was dispatched. This moves the "cleared review before bypass" control from **preventive** (the recorder refuses) to **detective** (post-hoc): the FP-RECOVERY workflow still dispatches the opus reviewer and the admin sees the verdict before merging; the mandatory FP_RECOVERY PR annotation (Step 5b) records the reviewer hash + rationale; the audit-sweep marker captures the bypass for reconciliation. **These are detective, not preventive — they record a careless/unreviewed bypass, they do not stop it.** This residual was already near-worthless against a malicious bypass-actor under the ledger (they held their own signing key); the genuine loss is against an *honest-but-careless* bypass-actor, whose one web-UI merge now auto-propagates exemption to all of that PR's SHAs. Accepted per maintainer direction (the bypass-actor is a trusted human whose merge *is* the authority); recorded here as an explicit, named downgrade — not equivalence.

## Consequences

- **Positive:** materially less machinery (delete an entire HMAC subsystem; extend ~3 sites with a field read + set membership). No signing key, no PAT, no recorder, no G-A, no two-tier ordering precondition. The override is exactly the human's one UI merge. ADR-0021's forge residual is closed *by construction*. Every failure mode degrades **fail-closed** ("second override"), never to "unreviewed code silently exempted" — no integrity regression.
- **Negative / cost:** "cleared review before bypass" is now detective, not preventive (above). The gates take a hard dependency on the bypass set matching the live ruleset, which is **not** live-drift-locked (above) — mitigated by fail-closed behavior + the required admin-run assertion follow-up. The `merged_by` read lands in two KEEP-IN-SYNC parser copies (standing drift hazard) + the audit sweep.
- **Roll-out:** ship the gate change in **warn** mode behind the existing coverage/provenance mode flags; the `P-IDENTITY-EXEMPT` liveness test must be green before any enforce consideration.
- **Doc coupling:** update **3ee4 P8c** HARD-PREREQUISITE item 3 ("S-11 admin-exemption ledger") to reference the identity-based mechanism, so the enforce-flip runbook does not gate on a retired artifact.

## Alternatives considered

- **HMAC-signed ledger (ADR-0021, superseded):** required a signing key held by someone, forcing key-separation + a human-held key + C1/C2/C3 — the PAT/key friction the maintainer direction rejects. Identity-based achieves the same propagation with none of it, and is *stronger* (no key-reachability invariant to defend).
- **CI-side signer (rejected in ADR-0021 rev.1):** committed to a protected branch (regress + bypass-identity problems) and still needed a key.
- **Single scalar bypass id (rejected this rev.):** bus-factor-1; wedges a multi-maintainer team. Resolved by the bypass *set*.
