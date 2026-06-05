# Sync Hardening Proposal — Reconciler Resilience & Self-Healing (rev 4)

**Status**: DRAFT rev 4 (rev 2 addressed C1/I1–I4/M2–M3; rev 3 corrects the substrate write-path to the real snapshot-commit mechanism, replaces the nonexistent `bridge_alert` API with the real `alert_store` surface, and fixes the M3 enum + canary-cron framing; rev 4 acknowledges the snapshot-helper's pre-existing deviation from the _advisory_lock.py:11 invariant, mandates key+timestamp_ns on all alert records, and generalizes all three hardcoded helper guards)
**Date**: 2026-06-04
**Origin**: 2026-06-03/04 Jira-parity probe campaign (bugs 3b5f/85a1/8b25/4292/929a/221b/1f47/1e08)
**Scope note**: A "maintenance hold / campaign exclusivity" item was considered and **rejected by the maintainer**. It is intentionally absent.

## Problem inventory (evidence base)

| # | Failure observed | Root mechanism |
|---|---|---|
| P1 | Reconciler "succeeded" every pass while re-emitting ~259 identical parent mutations, for weeks | No convergence invariant |
| P2 | Parent reads returned `{}` for weeks after Atlassian retired `POST /rest/api/3/search` (410) | Permanent failure classified as transient WARNING; no escalation |
| P3 | The parent fix had to be made twice in one file: `_OUTBOUND_UPDATE_ALLOWLIST` (applier.py:253) and `_OUTBOUND_BATCH_ALLOWLIST` (applier.py:2199); plus a field-vocabulary mismatch (`parent` vs `parent_id`) in the suppression layer (fixed 183fd51ac2) | Duplicated operation logic |
| P4 | Conflict-corrupted `bindings.json`/`prev_snapshot.json` abort passes (correct, post-4292) but recovery is manual; stale bindings re-emit forever (1e08) | Manual recovery; no binding lifecycle GC |
| P5 | Multi-day diagnosis reconstructing reconciler behavior from absent evidence | No per-pass structured summary in Action logs |
| P6 | The 410 retirement shipped silently | No scheduled live contract verification |

## Shared substrate — the pass-window state (C1, M3 resolution)

All of Items 1, 2, and 4b consume one rolling-window file. Its contract, stated once:

- **Location**: `.tickets-tracker/.bridge_state/pass-window.json` — the *version-controlled* state dir on the tickets orphan branch (NOT the repo-root `bridge_state/` log dir; the two are distinct lifecycles). # tickets-boundary-ok
- **Write path (stated against the real code)**: the window is serialized once per pass, *while the pass holds the advisory pass lock*, and persisted by the same snapshot-commit mechanism as `bindings.json` — `_commit_binding_store_snapshot` (reconcile.py:205–277, cf93b2b7ad), which performs a plain local `git add` + `git commit --no-verify` on the tickets checkout and relies on the workflow's commit-back step to reach the remote (it does NOT itself use `rebase_retry`). NOTE: `_advisory_lock.py:11` states "All tickets-branch writes MUST go through rebase_retry" — `_commit_binding_store_snapshot` is a **pre-existing deviation** from that invariant (it survives because the commit is local-only, in-pass-serialized under the pass lock, and persisted by the workflow's commit-back; an idempotent re-commit on the next pass covers any loss). The widening **inherits** this sanctioned-by-practice deviation rather than resolving it; implementers should treat the lock-module comment as aspirational for this one helper, and any future remote-push behavior added to the helper MUST adopt `rebase_retry` at that point (1f47 hardening applies to the lock's own ref CAS). **Required code change, stated explicitly**: `_commit_binding_store_snapshot` currently stages `bindings.json` by hardcoded path (reconcile.py:242,254); it is parameterized to stage a path list and called with `[bindings.json, pass-window.json]` — generalizing ALL THREE hardcoded points: the `git add` (reconcile.py:242), the `exists()` early-return guard (reconcile.py:235), and the `"bindings.json" not in status.stdout` idempotency check (reconcile.py:254) — one commit, both files, identical risk profile to bindings by construction (same function, same in-pass serialization, same commit-back). This is honestly a *widening of an existing writer*, not "no new writer": the safety argument is (a) in-pass writes are serialized by the pass lock (GHA single-flight; local runs acquire the same lock), and (b) the file is consumed only by passes, which read it through the corrupt-state guard below — a clobbered window degrades monitoring for one pass, never the sync.
- **Corrupt-state guard**: `pass-window.json` gets its own entry in the reconcile-time parse guard (reconcile.py:548–573 pattern). Semantics differ from bindings on purpose: **fail-open-for-monitoring, never-block-sync** — a corrupt/unparseable window is treated as an empty window (alert via `alert_store.append`, gated by `is_deduped`), the sync pass proceeds normally, and all window-consuming decisions (convergence alerting, degradation escalation, GC retirement) are SKIPPED that pass. Monitoring must never break the thing it monitors.
- **Record schema** (one schema, three consumers):

```json
{ "passes": [ {
    "pass_id": "...",
    "computed": 0, "applied": 0, "failed": 0, "skipped": 0,
    "mutation_digest": "sha256 of sorted (target,action,fields) tuples",
    "degradations": { "<site-id>": "transient|permanent" },  // stored classes only; the escalating/Unknown state is COMPUTED at read time from the >=3-record streak, never stored
    "bindings_absent": ["DIG-1234", "..."],
    "restores": ["bindings.json"]
} ] }
```
  Window length N=5 (covers every consumer's ≥3-pass predicates with margin).
- **Acceptance tests**: corrupt window → empty-window semantics + sync unaffected + skip flags set; the parameterized snapshot helper stages BOTH files in one commit (unit test against the widened helper); schema round-trip.

## Item 1 — Convergence invariant monitoring

**Design**: after each pass, compare `mutation_digest` across the last 3 window records. If `computed > 0` AND the digest is **identical** 3 consecutive passes (same mutations re-emitting, not new work): `alert_store.append({"kind": "non-convergence", "key": <dedup-key>, "timestamp_ns": time.time_ns(), ...}, repo_root)` gated by `alert_store.is_deduped(key, repo_root, 24h)` — per the alert_store contract (append does NOT auto-populate key/timestamp_ns; is_deduped matches on `key` and reads `timestamp_ns`, defaulting 0 = never deduped; every record this proposal writes carries BOTH fields, following the invariants.py:108 convention) + a `::warning::` GitHub annotation (Item 5 surface). Busy systems with fresh edits never trip it.

**Acceptance**: unit — (a) 3 identical non-empty digests → alert; (b) 3 non-empty differing digests → none; (c) 6→2→0 convergence → none; (d) alert dedup honored. **Live oracle (M2)**: synthetic fixture is primary; the probe's Phase-6 idempotency check is the secondary live oracle and is only authoritative once 4572/1e08 are closed — acceptance is NOT gated on a Phase-6-green full probe before then.
**Failure-mode check**: alerting wrapped fail-open; window unavailable → skip (substrate semantics).

## Item 2 — Degradation taxonomy (transient / permanent / escalating)

**Design**: shared `classify_degradation(exc) -> Transient|Permanent|Unknown` helper; all degradation sites route through it.
- **Permanent** (HTTP 410, 401/403, NXDOMAIN): ERROR log + deduped `alert_store.append` + pass result `degraded_permanent=true`; the reconcile-bridge.yml step that already handles failure states (the `if: failure()` step at line ~298) gains an explicit health annotation: `::error::` naming the site; the **sync step itself still completes unaffected portions** (wiring: the summary-tail step, see Item 5, exits nonzero iff `degraded_permanent` — making the run red without truncating the pass).
- **Transient** (timeout/429/5xx/reset): existing retry/WARNING behavior (`_rest_urlopen_with_retry`).
- **Escalating-unknown**: a site appearing in `degradations` for ≥3 consecutive window records is promoted to Permanent handling.
**Acceptance**: unit per class; promotion rule; the live-410 fixture from this session is the canonical RED test. Classification errors default Transient (never stricter-by-accident).

## Item 3 — Single source of truth for field contracts (Stage A)

**Design**: new leaf module `dso_reconciler/_field_contract.py` (imports nothing from the package — constants only).
- **Verified duplicates consolidated** (the load-bearing core): `_OUTBOUND_UPDATE_ALLOWLIST` (applier.py:253) and `_OUTBOUND_BATCH_ALLOWLIST` (applier.py:2199) become ONE constant. These two are *proven* drift sites (the 0f51601b96 parent fix had to patch both).
- **New shared structure** (not pre-existing literals — framed honestly): `OUTBOUND_TO_INBOUND_FIELD = {"parent": "parent_id"}` extracted from the suppression logic (183fd51ac2) so future field-name vocabulary lives in one place.
- **Enum maps**: at implementation time, enumerate actual definition sites via grep (`_LOCAL_PRIORITY_TO_JIRA` etc. — the authoritative copy sits in acli-integration.py:44; any additional literal copies found in the differs/applier are consolidated; if none exist, only a re-export lands and the structural test pins the single-site invariant going forward).
- **Import safety (I2)**: `acli-integration.py` is loaded via `importlib.spec_from_file_location` from contexts where the `dso_reconciler` package already resolves — proven by its existing `from dso_reconciler.adf import text_to_adf` (line 27). The invariant that keeps this safe: `_field_contract.py` stays a pure leaf, and consumers only load `acli-integration.py` through the established loaders. Both conditions hold today; the structural test asserts the leaf property (no `from dso_reconciler` imports inside `_field_contract.py`).
- **Stage B** (merging typed-leaf and batch apply paths) remains explicitly deferred to a follow-up epic.
**Acceptance**: structural test pinning (a) exactly one allowlist literal repo-wide, (b) the leaf property — written against the enumerated, verified sites only (Rule-5 structural-artifact exception); full reconciler suite green (no behavior change).

## Item 4 — Self-healing state restore + binding GC

**4a Auto-restore (bounded, I4)**: on parse failure of `bindings.json`/`prev_snapshot.json`, attempt ONE restore from the last tickets-branch commit (`git show tickets:<path>`); re-parse through the same guard — still corrupt → abort (as today). Restore events: recorded in the window record (`restores`) + `alert_store.append` gated by `is_deduped` (no spam). **Escalation cap**: restores of the same file in ≥3 consecutive window records promote to Permanent handling via Item 2 (red health, ERROR) — auto-restore must never become a silent perpetual-degradation channel (the P2 anti-pattern).
**4b Binding GC (tombstone pattern)**: at pass start, for bindings whose Jira key appears in `bindings_absent` across ≥3 consecutive window records: verify via direct GET (bounded K=20/pass). Positive 404 → move the binding to `bindings-retired.json` (archive, reversible — soft delete, never hard) + deduped `alert_store.append`. Transient fetch failure (per Item 2 classification) → not evidence; skip. **Grace tuning (M1)**: 3 passes ≈ 1h at the 20-min cron — deliberately shorter than multi-day industry tombstone norms because retirement here is a *reversible archive move* with positive 404 evidence, not data destruction; both K and the pass threshold are constants in `_field_contract.py` for easy tuning.
**Acceptance**: unit — corrupt→restore→proceed; restore-also-corrupt→abort; restore-streak→escalation; GC retires on 3-absence+404; GC skips on transient failure; K bound; archive reversibility (retired binding restorable). Live: out-of-band delete of a probe Jira issue → binding retires within 3 passes, re-emits stop.

## Item 5 (amended) — Per-pass telemetry in the GitHub Action logs

**Design**: per maintainer direction, telemetry goes to the **Action log only** — zero new shared-state writers. One structured stdout line per pass: `RECONCILE_SUMMARY: {pass_id, duration_s, computed, applied, failed, skipped, degradations:{site:class}, lock_cas_retries, convergence:{streak, alerted}, restores:[...], gc:{verified, retired}}` + `::notice::`/`::warning::` annotations. reconcile-bridge.yml gains a summary-tail step that renders the line into `$GITHUB_STEP_SUMMARY` (markdown) and exits nonzero iff `degraded_permanent` (the Item-2 health wiring).
**Acceptance**: unit — exactly one parseable summary line per pass; actionlint green.

## Item 7 — Daily live API contract probes (folded into the existing canary, I1)

**Design**: extend the **existing** `.github/workflows/reconcile-bridge-canary.yml` ("Reconciler Heartbeat Canary": hourly cron, `concurrency: group: reconcile-bridge-canary`, ticket-based alerting) rather than adding a second canary workflow:
- Add a second cron entry (`37 9 * * *`) and a `contract-probes` job gated by `if: github.event.schedule == '37 9 * * *' || github.event_name == 'workflow_dispatch'` — contract probes run daily; the existing heartbeat job is ungated and therefore fires on BOTH crons — hourly plus once more at the daily fire (harmless: it is idempotent and already runs 24x/day); one workflow file, one operator mental model.
- **Read-only by construction**: `dso_reconciler/contract_canary.py` performs only `POST /rest/api/3/search/jql` (1 result; fields=key,parent,comment), `GET /issue/<probe>?fields=parent`, transitions GET, `GET /myself`, `acli --version` + one acli read. No creates/updates/deletes, no reconciler invocation, no tickets-branch access, no bridge state, no lock acquisition. It stays in the canary concurrency group (NOT the sync's `reconcile-bridge` group — joining the sync group would queue the sync behind probes, *creating* coupling where none exists; non-interference is by shared-state absence, not scheduling).
- Shape assertions import the consumed-fields contract from `_field_contract.py` (Item 3) — the canary tests the same contract the code uses (consumer-driven-contract pattern).
- **Alerting model aligned with the existing canary convention (I1)**: on contract failure the job goes red AND files/refreshes a `contract-alert` bug ticket via the same mechanism the heartbeat job uses (one consistent alerting model); the ticket self-closes on the next green run, mirroring heartbeat behavior.
**Acceptance**: unit with mocked endpoints (per-probe shape pass/fail); actionlint; one manual `workflow_dispatch` green against live Jira; `required-checks.txt` untouched; heartbeat job behavior unchanged (existing canary tests stay green).

## Sequencing & validation

1. Lands after chunk-12 merges (shared files); one branch, one commit per item, TDD RED-first.
2. Live verification: synthetic-fixture oracles primary (M2); one full probe (Phase-6 as secondary oracle once 4572/1e08 close); out-of-band binding-GC scenario; one canary `workflow_dispatch`.
3. Two-tier merge; confirm one scheduled reconcile-bridge run shows RECONCILE_SUMMARY + step summary with zero convergence alerts; confirm the daily contract job's first green run.
