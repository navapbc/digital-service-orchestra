# Workflow-Stability Session Log — 2026-05-31

**Purpose**: Complete record of this session so the next session can continue execution without re-deriving context. The *plan* lives in `workflow-stability-plan-v4-handoff.md`; this log records what was investigated, decided, and **applied live** this session.

**Branch**: `worktree-20260528-085216` (a DSO worktree session; run from the worktree root).

---

## 1. Arc of the session

1. Picked up from a prior session's in-flight PRs; **PR #509 merged** (its cycle-3 `llm-review` was a verified stale-context FP, cleared via `/dso:fp-recovery`); stranded staged ref deleted.
2. Loaded the **v3 plan**, found its central premise (Q3: "broaden the sub-PR ruleset include to `~ALL`") was **false and dangerous** (live `staged-*` is canonical; `~ALL` would fail invariant I1 / brick main). **Marked v3 SUPERSEDED**, wrote **v4** (`workflow-stability-plan-v4-handoff.md`).
3. Ground-truthed the whole CI/PR process against **live `gh` + executable code** (docs/comments treated as untrusted), ran 2 industry-research passes, multiple opus reviews, and probes P2/P5/P9. Re-diagnosed the chronic bug.
4. **Closed Goal-4 containment for real** (live admin changes + credential hygiene + an enforcing CI invariant). Details in §3–§4.

## 2. Root-cause re-diagnoses (corrects v3 and earlier assumptions)

- **Chronic integration-review re-flag (the #509 class)** is caused by **diff construction**, not defense suppression: the integration review builds its diff by **concatenating per-commit `git show`** (`llm-review-dispatch-or-skip.sh:414-419`), so an introduce-then-fix across commits shows *both* hunks and the reviewer flags the intermediate state. Defenses are never even loaded at integration (cycle always resets to 1 + `DSO_SUPPRESS_PRIOR_DEFENSES=true`). → fix = net-end-state diff (v4 W2).
- **Goal-1 hole (live)**: the dispatcher's `comm -23` filter (`:385`) and the verifier's `^origin/main` exclusion (`verify-session-provenance.sh:357`) equate **reachable-from-main** with **reviewed** — so any SHA that reaches main unreviewed (admin bypass, hotfix) is permanently "laundered" (P9). → fix = a fail-closed coverage invariant (v4 TS-1).
- **Cross-sub-PR semantic conflicts** are structurally invisible to the integration review (covered files are subtracted from scope) — module-scope alone is insufficient; need a symbol-level dangling-reference check (P2 → v4 W6).
- **Containment is identity-based, not config-based**: `bypass_mode: pull_request` does NOT mean "web-UI only" — an admin/bypass-actor can merge a failing PR via REST API. Only a non-bypass-actor identity is contained (v4 CS-6/CS-7).

## 3. LIVE GitHub changes APPLIED this session (navapbc/digital-service-orchestra)

These are **already in effect** on the live repo:

1. **Ruleset bypass actor switched** on BOTH rulesets (15629023 main, 16961402 sub-PR): from `{RepositoryRole: admin (id 5)}` → **`{User: JoeOakhartNava (id 207596960), bypass_mode: pull_request}`**. The admin *role* no longer bypasses; only the named human (via web UI). Verified: agent identity `joeoakhart` → `current_user_can_bypass: never` on both.
2. **`DSO_RULESETS_READ_TOKEN` secret set** — a least-privilege **non-admin** token (account `joeoakhart`, scopes `public_repo,read:org,read:project,repo:status,repo_deployment`). (An earlier token was pasted in plaintext in the session transcript and is **exposed → must be revoked**; the secret value was re-delivered via file and is NOT in the transcript.)
3. **`ruleset-design-invariants` added to the main ruleset's required status checks** — drift detection is now **live and enforcing** (previously it was neither a live required check nor token-provisioned → inert).

**Credential hygiene applied** (CS-7a): the admin token `JoeOakhartNava` was found being used by `git` (via osxkeychain) — a live containment hole — and was **erased from the keychain + logged out of `gh`**. Both `gh` and `git` now resolve to non-admin `joeoakhart`. The temporary admin PAT used for the live changes was removed from the agent environment at session end.

## 4. CODE changes committed this session (this commit)

- **Deleted** `plugins/dso/scripts/sync-sub-pr-ruleset.sh` + `tests/scripts/test-sync-sub-pr-ruleset.sh` — an **armed regression** that hardcoded `~ALL` and would PATCH the live ruleset to the forbidden shape if run. Scrubbed the dangling reference in `lib/default-branch.sh` + `provision-ruleset.sh` comments.
- **Config-driven bypass actor**: new config key **`ruleset.bypass_user_id`** (`.claude/dso-config.conf` = `207596960`; documented in `dso-config.reference.conf`). `provision-ruleset.sh` now reads it and emits a `User` bypass actor (templated `${BYPASS_ACTORS_JSON}`), defaulting to `RepositoryRole:admin` when unset. Env override: `DSO_RULESET_BYPASS_USER_ID`.
- **Outcome-based invariant test**: `test-ruleset-design-invariants.sh` I4/I7 now assert **`current_user_can_bypass == "never"`** (the running identity cannot force-merge) instead of introspecting `bypass_actors` (which is admin-read-only). Verified: passes as non-admin (9/9), correctly fails for a bypass-capable identity. Dropped the actor-identity drift-lock (former I8/I9).
- **v4 plan + this log + the superseded v3 + prior residual handoff** docs.

## 5. Key gotcha discovered (important for the next session)

- **`bypass_actors` is admin-read-only.** A non-admin token sees it empty. This is why the invariant check is **outcome-based** (`current_user_can_bypass`, readable by any token) rather than introspecting the actor list. The per-PR CI check therefore proves *the CI/agent identity can't force-merge*; it does NOT independently re-prove "a generic admin role can't bypass" (that was achieved by the live switch and is re-checkable by an admin-run audit). This is by design (matches the directive "verify the outcome, not the specific actors").

## 6. State summary

| Area | State |
|---|---|
| Goal-4 containment | ✅ **live + self-enforcing** (bypass actor=named human; agent can't force-merge by any path; enforced by a required CI invariant) |
| Drift detection | ✅ **live** (`ruleset-design-invariants` required + `DSO_RULESETS_READ_TOKEN` provisioned) |
| v4 plan | ✅ current, self-contained; CS-1..19, W1-W8, probes, decisions |
| Chronic bug (W2), Goal-1 invariant (TS-1), semantic-conflict (W6), fp-recovery web-UI + post-hoc audit (W3d), single-source-of-truth (W1 remainder), docs (W8) | ⏳ **specified, not yet implemented** |

## 7. Open security follow-ups (USER)
- Revoke the exposed `ghp_…30mAcc` token (pasted in chat).
- Decide keep/revoke the admin PAT provisioned for the live changes.

## 8. Pointers
- Plan + workstreams + probes + decisions: `workflow-stability-plan-v4-handoff.md`
- Superseded: `workflow-stability-plan-v3-handoff.md` (do not execute)
- Prior-session residual items: `2026-05-31-session-residual-work-handoff.md`
