# Epic 3a03 recovery session handoff — 2026-05-24

**Epic**: `3a03-b3f2-b34c-4e4f` — Replace edge-triggered Jira bridge with level-triggered reconciler.

**Session outcome**: 4 ACLI bugs fixed + integration hardened, then live verification surfaced a P0 architectural defect. Reconciler cron disabled, Jira state restored, epic returned to brainstorm.

**Read this document to pick up the work cold.** It captures every load-bearing finding, commit, ticket ID, and decision so a future session can resume without replaying the discovery work.

---

## TL;DR

1. The reconciler shipped from the original cutover had **3 layered ACLI invocation bugs** that each masked the next. All 3 are fixed and on main.
2. After fixing them, live verification pass 1 surfaced a **4th, architectural defect**: the differ/applier `create` semantics are inverted — instead of mirroring unmapped Jira issues DOWN to local tickets, the applier creates DUPLICATE Jira issues.
3. A 5th defect compounds the architectural one: `bridge_state/` writes are never persisted across passes (written to the wrong git worktree on the GHA runner).
4. The architectural defects are NOT session-fixable — they require brainstorm-level design decisions.
5. The hardening work shipped this session (ACLI integration + sanitizers + 36 contract tests) IS net-positive and survives the rework.
6. Reconcile Bridge workflow is currently `state: disabled_manually`. 5 confirmed-duplicate DIG issues were deleted. The Jira project is in a clean baseline state.

---

## What landed on `main` this session

| Commit / PR | Branch | What it did |
|---|---|---|
| PR #333 / `26ac574985` | `recovery-3a03/4fa9-projectkey-fix` | Fix bug `4fa9`: applier.py:512 missing `jira_project=` kwarg → ACLI rejected with "ProjectKey can't be null or blank" |
| PR #334 / `5f5d4963e2` | `recovery-3a03/cleanup-legacy-bridge` | (a) Fix bug `5010`: `_create_issue_from_json` stringified Jira-snapshot priority dict → ACLI rejected as "priority selected is invalid"; (b) deleted legacy bridge files + tests; (c) CC7 doc patch (rollback-impossible forward-fix path); (d) addressed 12 PR review threads |
| PR #335 / `56ed89083c` | `recovery-3a03/c916-label-fix` | (a) Fix bug `c916`: `add_label` used nonexistent `--label` flag → switched to `--from-json` with `labelsToAdd`; (b) added `remove_label`; (c) added `_sanitize_label` + `_sanitize_summary`; (d) 36 contract regression tests; (e) fixed off-by-one `_JIRA_SUMMARY_MAX_CHARS` (255 → 254) |

`origin/main` HEAD at session close: `56ed89083c` (post-PR-#335 merge).

---

## Defect catalog (in discovery order)

### Code bugs — FIXED

| Bug | Title | Layer | Fix |
|---|---|---|---|
| `4fa9-0846-519e-4c30` | AcliClient constructor omits `jira_project` kwarg | acli-integration.py | PR #333 |
| `5010-1c6a-9387-4b5b` | `_create_issue_from_json` priority dict stringified via `str()` | acli-integration.py | PR #334 |
| `c916-74a1-ed06-40e4` | `add_label` uses ACLI singular `--label` (nonexistent flag) | acli-integration.py | PR #335 |
| (no separate bug ID) | `_JIRA_SUMMARY_MAX_CHARS` off-by-one (255 → 254) | acli-integration.py | PR #335 (commit `952f2b7457`) |
| `5dde-9d13-4bf6-49e1` | rollback-bridge-cutover.sh STEP 3 dropped allowlist entry on revert | rollback-bridge-cutover.sh | Fixed earlier (pre-session); verified working in 7339 dryrun |

### Architectural defects — NOT FIXED (returning to brainstorm)

| Bug | Title | Layer | Why not session-fixable |
|---|---|---|---|
| `7f36-6ca9-d9ae-432b` | differ + create_one inversion: unmapped Jira issue → duplicate Jira issue (not local mirror) | dso_reconciler.differ + dso_reconciler.applier contract | Requires direction marker on mutations + reshaped differ-to-applier schema; brainstorm-level design decision |
| (Defect B in `7f36`) | bridge_state writes are not persisted across passes | reconcile-bridge.yml workflow + applier write path | bridge_state writes go to main-branch working dir on GHA runner; workflow commits only tickets branch worktree. Requires deciding where bridge_state actually lives |

### Process / governance bugs — FILED (not blocking)

| Bug | Title | Skill / workflow affected |
|---|---|---|
| `0dee-a535-45dd-4bc4` | brainstorm + preplanning feasibility research captured at insufficient depth | brainstorm SKILL.md, preplanning SKILL.md, feasibility-reviewer agent |
| `fe3a-a3fb-4523-4ccc` | implementation agent bypassed old bridge ACLI patterns, activated dormant broken code | sprint orchestration, prior-art-search.md |

Both reference the **prior-art hierarchy** established this session: external authoritative + empirical evidence > internal prior art > inference.

---

## What was VERIFIED with sufficient evidence (Closure Checks + Success Criteria)

### Verified Closure Checks

| Check | Evidence |
|---|---|
| **CC1** Legacy YAMLs deleted + no post-cutover scheduled runs | `git ls-tree origin/main .github/workflows/` shows neither legacy file; `gh api .../workflows/{inbound,outbound}-bridge.yml` returns `state=deleted`; `gh run list --created='>2026-05-23T23:17:56Z'` returns zero. The 4 pre-cutover runs at 21:19-22:47Z fired BEFORE PR #327 merged at 23:17:56Z. |
| **CC3b** Heartbeat firing on simulated disable | Story `7004-3121-e68b-4d80` closed P1=PASS 6/6. Canary run `26347600778` opened bug ticket `c03a-2e77-b229-4144` autonomously when the reconciler was stale; subsequent runs commented (dedup verified). |
| **CC4** Weekly fsck 2 consecutive on-demand cycles | Runs `26350906355` + `26350930124` both ran the audit infrastructure (Python setup + tickets-branch mount + ticket-bridge-fsck.py) and reported identical 1738 anomaly counts (stable snapshot proven). |
| **CC5** No legacy code refs | Final grep across `plugins/dso/`, `.github/`, `.claude/` returns 0 non-shim-exempt matches for `bridge-outbound.py | bridge-inbound.py | _outbound_cursor | _outbound_handlers | _inbound_api`. |
| **CC7** Rollback-impossible-after-Nh forward-fix path documented | `rollback-bridge-cutover.sh` header now contains a 50-line operator-facing block documenting 3 irrecoverable-state indicators + the forward-fix procedure. Committed in `ed41294987` (part of PR #334). |

### Verified Success Criteria

| Criterion | Evidence |
|---|---|
| **SC7** Rollback dry-run + post-rollback CI cycle | Story `7339-ce88-39ff-4d31` closed by explicit user override 2026-05-24. DD1+DD2+Closure Check PASS via `dryrun-bridge-rollback-in-worktree.sh` exit 0 at HEAD `31bb823d9c`; DD3 ("old bridges run 1 scheduled cycle post-revert") structurally unverifiable post-cutover, evidence sufficient by user authorization. |

### Live evidence captured that DOES NOT count toward closure

- **Pass 1 reconciler ran 9m9s with no ACLI errors** (run `26352037828`, 2026-05-24T04:38-04:47Z). All 4 ACLI bugs from earlier in the session are confirmed fixed at the ACLI surface level. Output: `invariants: scanned=1825 filed=0 (cap=5)` + `OK: steady-state pass converged — 1825 mutations`.
- **Live empirical test of hardened `add_label` / `remove_label` / `_sanitize_label` against DIG-3802** (2026-05-24T04:38Z) — all 4 hardening behaviors passed: add preserves existing labels, re-add is idempotent, remove preserves other labels, sanitizer rejects whitespace.
- **Independent validation audit** (sub-agent `a52143da`, 2026-05-24T04:30Z) — 22 ACLI invocation patterns cross-checked against authoritative Atlassian docs + 20+ GitHub prior-art consumers. 21/22 CONFIRMED-CORRECT; the 1 finding was the summary off-by-one that we fixed in the same PR.

### NOT verified (blocked by architectural defect)

- **SC1** Bootstrap convergence ≥80% drop — would require working differ/applier to execute.
- **SC2** Open-count parity over 3 consecutive passes.
- **SC3** Zero dual-creation duplicates — IRONIC: the duplication bug is exactly what SC3 was meant to prevent.
- **SC4** Idempotent reconciler (0-mutation 2nd pass).
- **SC5** Anomaly alert path end-to-end.
- **SC6** Drift harness 3 modes against live workflow.
- **CC2** bridge_state/mapping.json populated on tickets branch.
- **CC3a** 5 consecutive workflow_dispatch runs exit 0.
- **CC6** Per-pass REST budget under cap with 0 429s across 5 passes.

---

## The architectural defect — full explanation

### What the epic spec said the reconciler should do

From the 3a03 epic spec, **Conflict policy** section:

> Wholly-new Jira issues (no `dso_local_id`) mirrored down as `jira-*` local tickets, then become local-authoritative.

The intended INBOUND flow for an unmapped Jira issue:
1. Fetcher returns the issue from Jira.
2. Differ identifies it as needing reconciliation (no `dso_local_id` property, no `dso-id:<uuid>` label).
3. Applier:
   - Generates a new local UUID.
   - **Creates a local `jira-*`-prefixed ticket** in the local ticket store with the new UUID. <!-- tickets-boundary-ok -->
   - **Stamps the EXISTING Jira issue** with `dso-id:<new-uuid>` label.
   - **Sets the EXISTING Jira issue's** `dso_local_id` property to `<new-uuid>`.
   - Writes mapping.json: `<new-uuid> → <existing-Jira-key>`.

No new Jira issue is created.

### What the code actually does

The code path through `fetcher.py` → `differ.py:compute_mutations` → `applier.py:create_one`:

1. Fetcher returns the unmapped Jira issue.
2. Differ sees it's in `next_snapshot` but not `prev_snapshot` → emits a `create` mutation with `local_id = _derive_local_id(...)` which **falls back to the Jira key** when no local UUID exists.
3. `applier.create_one` (acli-integration.py line 269+) does:
   - Searches Jira: `labels = "dso-id:<local_id>"` → MISS for an unmapped issue.
   - Calls `client.create_issue(_ticket_data)` → **CREATES A NEW JIRA ISSUE**.
   - Stamps the NEW Jira issue (not the existing one) with `dso-id:<local_id>` label.
   - Sets `dso_local_id` property on the NEW Jira issue.

Result: every unmapped Jira issue triggers creation of a duplicate Jira issue.

### Forensic evidence (deleted at end of session)

5 confirmed duplicates were in Jira at peak of this session:

| Duplicate | Source | Pattern |
|---|---|---|
| DIG-4006 | DIG-2099 | Same summary, label `dso-id:DIG-2099` |
| DIG-4007 | DIG-2100 | Same summary, label `dso-id:DIG-2100` |
| DIG-4008 | DIG-2101 | Same summary, label `dso-id:DIG-2101` |
| DIG-4009 | DIG-2102 | Same summary, label `dso-id:DIG-2102` |
| DIG-4010 | DIG-2103 | Same summary, label `dso-id:DIG-2103` |

These were created during EARLIER failed passes (the failing ProjectKey/priority/label runs). Each pass crashed after ~5 successful creates, leaving the partial duplications behind. **Pass 1 post-PR-#335 did NOT create more duplicates only because the dedup-by-label short-circuit at `applier.py:307-316` found those existing 5 and skipped re-creation.** Without that incidental safety net, pass 1 would have created ~1820 new duplicates.

All 5 deleted at 2026-05-24T05:00Z via `acli ... workitem delete --yes`. JQL `labels in ("dso-id:DIG-2099", ..., "dso-id:DIG-2103")` now returns 0.

### Why this is NOT session-fixable

See the justification posted to the epic ticket — the short version:

1. **The defect is in the CONTRACT** between differ and applier, not in any single function. The differ emits `create` mutations without a direction marker (inbound vs outbound). The applier dispatches on `action`, not direction. Fixing it requires reshaping the differ-to-applier mutation schema.
2. **bridge_state persistence is a separate axis**. Even fixing the inversion doesn't fix bridge_state persistence; the two compound. Both touch architecture.
3. **The capability probe** (cfd6) verified ACLI surface, NOT band composition. Wrong layer to catch this.
4. **Remediation requires design decisions** (authority direction; mutation schema; bootstrap path; bridge_state location) that exceed fix-bug authority.
5. **Blast radius scales with** (unmapped Jira issues × passes until interrupted). With 1825 unmapped issues + a clean Jira state, a 9-min pass duplicates the project. Different category from a unit-bounded bug.

---

## Files touched this session (sample, not exhaustive)

Hardening + bug fixes (now on `main`):
- `plugins/dso/scripts/acli-integration.py` — sanitizers + add_label/remove_label rewrite + priority dict branch + projectKey kwarg + summary length off-by-one
- `plugins/dso/scripts/dso_reconciler/applier.py` — `jira_project=` kwarg in AcliClient construction
- `plugins/dso/scripts/dso_reconciler/__main__.py` — workflow ACLI install env
- `.github/workflows/reconcile-bridge.yml` — ACLI cache/install + `JIRA_PROJECT` env passthrough
- `tests/scripts/test_bridge_acli_field_coverage.py` — 36 contract regression tests
- `tests/unit/dso_reconciler/test_applier.py` — pin `jira_project` kwarg
- `CLAUDE.md` — trimmed reconciler bullet to rule-level pointer
- `plugins/dso/scripts/rollback-bridge-cutover.sh` — rollback-impossible-after-Nh forward-fix path docs
- Deletions: `plugins/dso/scripts/bridge-{inbound,outbound}.py`, `plugins/dso/scripts/bridge/` (full dir + 14 modules), 18 legacy bridge test files

---

## Resume instructions for next session

### Operator state at hand-off

- `origin/main` HEAD: `56ed89083c` (post-PR-#335)
- Reconcile Bridge: `state=disabled_manually` (no auto-passes)
- Reconciler Heartbeat Canary: still enabled — will continue to fire if reconciler stays stale; one existing alert ticket `c03a-2e77-b229-4144` is OPEN. Consider whether to also disable the canary during the brainstorm-and-rework period to avoid alert noise.
- Jira DIG project: 0 duplicates from the bug class. 1 issue with `dso-id` label (DIG-3802, the cfd6 capability-probe baseline).
- Tickets branch: bridge_state/ is EMPTY (consistent with no bootstrap ever having persisted).

### Pick-up flow

1. **Open epic 3a03 in brainstorm** with the 7 inputs listed in the brainstorm-inputs section of the epic status comment (`LIVE_VERIFICATION_HALTED` + `EPIC_STATUS_AND_BRAINSTORM_RETURN`):
   - `7f36-6ca9-d9ae-432b` P0 architectural inversion
   - `4fa9-0846-519e-4c30` ProjectKey null (FIXED)
   - `5010-1c6a-9387-4b5b` priority dict shape (FIXED)
   - `c916-74a1-ed06-40e4` add_label flag (FIXED)
   - `0dee-a535-45dd-4bc4` brainstorm/preplanning research depth (process)
   - `fe3a-a3fb-4523-4ccc` implementation agent ignored old code (process)
   - This document (`docs/findings/3a03-recovery-session-2026-05-24.md`) for full context

2. **Brainstorm decisions** the next session must make:
   - **Authority direction**: who owns truth for each field (local vs Jira, per field, per state)?
   - **Mutation schema**: should `create`/`update`/`delete` carry an explicit `direction: inbound | outbound` field?
   - **Bootstrap path**: how does the reconciler transition the existing 1825 unmapped Jira issues into mirrored state WITHOUT duplicating any? Two natural options: (a) one-time stamp-and-mirror sweep with explicit human review; (b) incremental capture as each issue is touched by local activity.
   - **bridge_state location**: does it live on `main` (with its own commit step in the workflow), on the tickets branch, or as a GHA cache/artifact? Document the persistence contract explicitly.
   - **Differ scope**: should the differ ONLY produce mutations that don't require new Jira creates? Or should it produce direction-marked mutations and let the applier route?

3. **Re-feasibility evidence** to capture in the next brainstorm:
   - **External authoritative**: this session's audit findings (Atlassian docs + community threads + 20+ GitHub prior-art consumers — see `docs/findings/` history).
   - **Empirical**: live `acli --generate-json` outputs for each subcommand we use; throwaway-issue probes for `view`, `search`, `comment list` shape; live confirmation that `add_label` via `--from-json labelsToAdd` is additive.
   - **Internal prior art (cross-check only)**: the OLD bridge code (in git history at `d871dbc9ae` and earlier, deleted at PR #334 merge `5f5d4963e2`). Useful as a "did this work in production?" cross-check but NOT authoritative — `add_label`'s broken `--label` flag was dormant in the old code too.

4. **Tests to keep**: `tests/scripts/test_bridge_acli_field_coverage.py` — 36 contract regression tests that pin the empirically-verified ACLI surface. These are correct against ACLI v1.3.18 and should be preserved through any rework.

5. **Things to NOT redo**:
   - DON'T re-research ACLI invocation patterns from scratch — the audit is in this doc + bug `c916` comments.
   - DON'T re-implement `add_label` / `remove_label` / sanitizers / off-by-one — already on main, already tested.
   - DON'T re-fix `ProjectKey null` / `priority dict` / `--label` flag — already on main.

---

## Open questions for the user

1. Should the heartbeat canary be temporarily disabled during the brainstorm/rework period to avoid alert noise from the (intentionally) stopped reconciler?
2. Should we delete the existing `c03a-2e77-b229-4144` heartbeat-alert bug, or leave it open as a marker that the reconciler is intentionally paused?
3. The 5 cleaned-up duplicates were created from DIG-2099 through DIG-2103. Are those 5 source issues themselves correct, or should we audit whether any other DIG issue inadvertently received a `dso-id:<jira-key>`-shaped label from earlier passes that we missed in the cleanup query? (The cleanup query covered only the 5 confirmed pairs.)

---

## Bug tickets created or updated this session

| Ticket | Title | Status |
|---|---|---|
| `4fa9-0846-519e-4c30` | ProjectKey null in AcliClient constructor | closed (fixed) |
| `5010-1c6a-9387-4b5b` | priority dict shape stringified | closed (fixed) |
| `c916-74a1-ed06-40e4` | add_label --label flag nonexistent | closed (fixed) |
| `5dde-9d13-4bf6-49e1` | rollback STEP 3 allowlist drop | closed (verified working) |
| `7f36-6ca9-d9ae-432b` | dso_reconciler differ + create_one inversion | OPEN (P0, blocks epic; brainstorm required) |
| `0dee-a535-45dd-4bc4` | brainstorm + preplanning research depth | OPEN (process; not blocking) |
| `fe3a-a3fb-4523-4ccc` | implementation agent ignored old code | OPEN (process; not blocking) |
| `75d4-63d0-d39e-4942` | sprint orchestrator closes stories without verifier dispatch | OPEN (filed earlier, not addressed this session) |

---

*End of handoff document. Author: session at 2026-05-24T04:00-05:10Z.*
