# Residual Bridge-State Symbol Audit — 2026

**Scope:** Enumerate and classify all references to the three retired bridge symbols (`bridge_state`, `prev_snapshot`, `mapping.json`) introduced by the edge-triggered bridge and superseded by the level-triggered Jira reconciler (epic 3a03). This document covers consumer enumeration only; code removal and rewiring are scoped to sibling tickets.

**Sibling ticket scope:**
- `2f51-e59f-5e0d-41fe` — owns the actual code removal and redirect (remove/redirect rows below are action items for that ticket)
- `9e3f-3208-af65-4b34` — orchestrator topology changes; intersects with any `bridge_state` directory-layout decisions

## Classification Rubric

Each residual reference is classified into one of four buckets. The first three buckets are the canonical set; bucket four was added per AC amendment G3 to disambiguate live-instruction documents from inert historical ones.

### Bucket: `remove`

**Definition:** A production code path that reads or writes a retired state artifact. The symbol is dead code or points to a data structure that the stateless reconciler no longer needs. Remediation is deletion of the code path.

**Worked examples:**

| Path | Line | Symbol | Classification | Note |
|------|------|--------|----------------|------|
| `plugins/dso/scripts/dso_reconciler/reconcile.py` | 291 | `prev_snapshot` | remove | Loads `<pass>.prev.json` from disk to pass into `compute_mutations`; superseded by stateless `compute_mutations_with_ledger` which derives prior state from the ProvenanceLedger |
| `plugins/dso/scripts/dso_reconciler/reconcile.py` | 314, 320 | `prev_snapshot` | remove | Passes `prev_snapshot` into `check_dual_identity_complete` and the differ; both call sites become dead once the stateless path is wired |
| `plugins/dso/scripts/rollback-bridge-cutover.sh` | 181–191 | `bridge_state` | remove | Restores cursor snapshot from `bridge_state/bootstrap/` — rollback script for the retired edge-triggered bridge; no longer a valid recovery path post-cutover |

### Bucket: `redirect`

**Definition:** A code path whose semantic intent must be preserved but rewired to the stateless equivalent. The symbol name is retired but the behavior (e.g., first-run detection, pass-completion signaling) still has a live counterpart. Remediation updates the call site to the new API; sibling `2f51-e59f` executes the rewire.

**Worked examples:**

| Path | Line | Symbol | Classification | Note |
|------|------|--------|----------------|------|
| `plugins/dso/scripts/dso_reconciler/applier.py` | 853 | `mapping.json` | redirect | Writes `bridge_state/mapping.json` with `local_id → jira_key`; the identity-mapping function is still needed but should migrate to the ProvenanceLedger store rather than a flat JSON file |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 1261 | `mapping.json` | redirect | Second call site that resolves `bridge_state/mapping.json` in `apply()`; same rewire target as line 853 |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 705–793 | `mapping.json` | redirect | `load_mapping`, `persist_field_provenance`, `_update_mapping_atomic` helper functions — functional intent preserved in ProvenanceLedger; function bodies to be replaced, not deleted |

### Bucket: `document-as-historical`

**Definition:** Documentation files, archive documents, findings docs, comments, or test fixture names that mention retired terms for historical context only. These references are inert — they describe past behavior, record a postmortem finding, or name a temporary directory in a test. Remediation is annotation or no-action; the text must NOT be silently deleted because it is the record of why the architecture changed.

**Worked examples:**

| Path | Line | Symbol | Classification | Note |
|------|------|--------|----------------|------|
| `docs/findings/3a03-recovery-session-2026-05-24.md` | 15, 51, 96 | `bridge_state` | document-as-historical | Postmortem document recording the defect where `bridge_state/` writes were not persisted across passes; historical investigation artifact |
| `docs/findings/3a03-recovery-session-2026-05-24.md` | 127, 157, 187, 204 | `prev_snapshot` / `bridge_state` | document-as-historical | Same postmortem; describes the inversion bug in the old differ path; should be preserved as architectural record |
| `tests/unit/dso_reconciler/test_applier_mapping.py` | 79–302 | `mapping.json` | document-as-historical | Unit tests for the current `mapping.json` write path; these tests remain green until sibling `2f51-e59f` executes the redirect — at that point the test file is updated in-place, not deleted |

### Bucket: `project-instruction-stale-reference`

**Definition:** Live project-instruction documents (SKILL.md, ticket-cli reference, CLAUDE.md) that mention retired terms but require in-place update to match the stateless reality. Unlike `document-as-historical`, these docs are read on every agent session — stale content actively misleads agents. Remediation is a targeted text revision; this audit flags them but does NOT scope the revision (future audit task).

**Worked example:**

| Path | Line | Symbol | Classification | Note |
|------|------|--------|----------------|------|
| `plugins/dso/skills/onboarding/SKILL.md` | 707–709 | `bridge_state` / `mapping.json` | project-instruction-stale-reference | Lists `bridge_state/mapping.json`, `bridge_state/bootstrap/`, `bridge_state/health/` as current artifacts; requires update once `2f51-e59f` completes the redirect |

---

## Full Inventory Table

Columns: `path | line(s) | symbol | classification | note`

All three retired symbols (`bridge_state`, `prev_snapshot`, `mapping.json`) are covered.

| Path | Line(s) | Symbol | Classification | Note |
|------|---------|--------|----------------|------|
| `plugins/dso/scripts/dso_reconciler/reconcile.py` | 291 | `prev_snapshot` | remove | Local var loading prior-pass JSON from disk; superseded by ProvenanceLedger path |
| `plugins/dso/scripts/dso_reconciler/reconcile.py` | 314 | `prev_snapshot` | remove | Passed to `check_dual_identity_complete`; dead once stateless path wired |
| `plugins/dso/scripts/dso_reconciler/reconcile.py` | 320 | `prev_snapshot` | remove | Passed to differ; dead once stateless path wired |
| `plugins/dso/scripts/dso_reconciler/reconcile.py` | 262, 286 | `bridge_state` | remove | Constructs `bridge_state/snapshots/` dir path for prev-snapshot load; same dead path |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 853 | `mapping.json` | redirect | Primary write site: `bridge_state/mapping.json` on JQL hit; rewire to ProvenanceLedger |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 1261 | `mapping.json` | redirect | Secondary write site in `apply()`; same rewire |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 705 | `mapping.json` | redirect | `load_mapping` helper; functional replacement needed |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 752 | `mapping.json` | redirect | `persist_field_provenance` docstring and path; functional replacement needed |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 788 | `mapping.json` | redirect | `_update_mapping_atomic` helper; functional replacement needed |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 820, 830 | `bridge_state` / `mapping.json` | redirect | `bridge_state/mapping.json` path construction in dedup guard; rewire |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 1213, 1300 | `bridge_state` | redirect | `bridge_state/snapshots/` dir used in pass-record writes; redirect to new layout |
| `plugins/dso/scripts/dso_reconciler/applier.py` | 669, 679 | `bridge_state` | redirect | `write_pass_record` writes to `bridge_state/snapshots/`; redirect |
| `plugins/dso/scripts/dso_reconciler/fetcher.py` | 2, 8, 143, 187 | `bridge_state` | redirect | Writes snapshot to `bridge_state/snapshots/`; directory layout question for sibling `9e3f-3208` |
| `plugins/dso/scripts/dso_reconciler/health.py` | 16, 19 | `bridge_state` | redirect | `_STATE_SUBDIR = "bridge_state"` — live health signal path; redirect only if directory renamed |
| `plugins/dso/scripts/dso_reconciler/alert_store.py` | 22, 25 | `bridge_state` | redirect | `_STATE_SUBDIR = "bridge_state"` — live alert store path; redirect only if directory renamed |
| `plugins/dso/scripts/dso_reconciler/capability_check.py` | 28 | `bridge_state` | redirect | `bridge_state/bootstrap` capability check; redirect if bootstrap layout changes |
| `plugins/dso/scripts/dso_reconciler/cursor_snapshot.py` | 2, 73, 242 | `bridge_state` | redirect | Writes cursor snapshot to `bridge_state/`; redirect if layout changes |
| `plugins/dso/scripts/dso_reconciler/dso-reconciler-health.py` | 136 | `bridge_state` | redirect | CLI default path `bridge_state/health`; redirect if renamed |
| `plugins/dso/scripts/dso_reconciler/differ.py` | 8 | `prev_snapshot` | document-as-historical | Module docstring describes the old `compute_mutations(prev_snapshot, next_snapshot)` signature; update to reflect new API once `2f51` lands |
| `plugins/dso/scripts/dso_reconciler/differ.py` | 70, 72 | `mapping.json` | document-as-historical | Comment describing historical dedup corruption scenario; accurate historical context |
| `plugins/dso/scripts/rollback-bridge-cutover.sh` | 41–42, 55 | `bridge_state` / `mapping.json` | document-as-historical | Comment block in rollback script explaining caveats about compaction; historical |
| `plugins/dso/scripts/rollback-bridge-cutover.sh` | 181–191 | `bridge_state` | remove | Active code restoring cursor from `bridge_state/bootstrap/`; rollback script for retired bridge |
| `plugins/dso/scripts/ticket-bridge-status.sh` | 15, 20 | `bridge_state` | redirect | References `bridge_state/health/*.json` in comments and logic; redirect if directory renamed |
| `plugins/dso/docs/ticket-cli-reference.md` | 1028 | `bridge_state` | document-as-historical | Historical note: `.bridge-status.json` written by old edge-triggered scripts; sentence is accurate history |
| `plugins/dso/skills/onboarding/SKILL.md` | 707–709 | `bridge_state` / `mapping.json` | project-instruction-stale-reference | Lists retired artifacts as current; requires in-place update after `2f51-e59f` redirect completes |
| `tests/unit/dso_reconciler/test_applier_mapping.py` | 1–302 | `mapping.json` | document-as-historical | Test suite for current `mapping.json` write path; remains live until `2f51-e59f` redirect; update in-place at that time |
| `tests/unit/dso_reconciler/test_applier_provenance.py` | 5, 96–274 | `mapping.json` | document-as-historical | Provenance tests against `mapping.json` store; same lifecycle as `test_applier_mapping.py` |
| `tests/unit/dso_reconciler/test_e2e_dedup_pass.py` | 127, 140, 142, 169–174 | `mapping.json` / `prev_snapshot` | document-as-historical | E2E test fixtures; `prev_snapshot` used as local var in test body, not a system API call |
| `tests/unit/dso_reconciler/test_differ.py` | 257 | `mapping.json` | document-as-historical | Comment in differ test explaining why empty provenance re-introduces dedup corruption; historical context |
| `tests/unit/dso_reconciler/test_reconcile_health_wiring.py` | 61, 81 | `bridge_state` | document-as-historical | Test temp-dir path construction; fixture-level, not a system API |
| `tests/unit/dso_reconciler/test_health_schema.py` | 70 | `bridge_state` | document-as-historical | Test fixture path; inert |
| `tests/unit/dso_reconciler/test_reconcile_invariant_phase.py` | 55, 69 | `bridge_state` | document-as-historical | Test fixture paths in tmp dirs; inert |
| `tests/unit/dso_reconciler/test_fetcher_snapshot.py` | 181, 188 | `bridge_state` | document-as-historical | Test assertion on snapshot path; inert until fetcher redirect lands |
| `tests/unit/dso_reconciler/test_applier_rebase_retry.py` | 246, 258 | `bridge_state` | document-as-historical | Test fixture paths; inert |
| `tests/unit/dso_reconciler/test_alert_store_concurrency.py` | 91 | `bridge_state` | document-as-historical | Test fixture path for alert store; inert |
| `tests/unit/dso_reconciler/test_alert_store_dedup.py` | 23–209 | `bridge_state` | document-as-historical | Alert store test fixtures; inert |
| `tests/unit/dso_reconciler/test_at_most_one_invariant.py` | 300, 309, 329, 499–500 | `bridge_state` | document-as-historical | Invariant test fixtures; inert |
| `tests/unit/dso_reconciler/test_applier.py` | 97, 107 | `bridge_state` | document-as-historical | Manifest write test fixture path; inert |
| `tests/unit/dso_reconciler/test_health.py` | 53, 63, 80, 102, 127 | `bridge_state` | document-as-historical | Health record test fixtures; inert |
| `tests/unit/dso_reconciler/test_health_baseline.py` | 79, 82, 95, 113, 141, 172 | `bridge_state` | document-as-historical | Health baseline test fixtures; inert |
| `tests/scripts/test_cursor_snapshot.py` | 61–279 | `bridge_state` | document-as-historical | Cursor snapshot test fixture dirs; inert until cursor_snapshot.py redirect lands |
| `tests/scripts/test_capability_check.py` | 24, 36, 47, 60 | `bridge_state` | document-as-historical | Bootstrap capability check test fixtures; inert |
| `docs/findings/3a03-recovery-session-2026-05-24.md` | 15, 51, 96, 118, 127, 157, 159, 187, 204 | `bridge_state` / `prev_snapshot` / `mapping.json` | document-as-historical | Postmortem investigation document; all mentions are accurate historical record of the defects found |

---

## Sibling Ticket Cross-References

**`2f51-e59f-5e0d-41fe`** — Code removal and redirect execution. All rows classified `remove` and `redirect` in the inventory above are action items for this ticket. The audit does not scope the actual code changes; it provides the call-site map so `2f51-e59f` can work the list without re-running discovery.

**`9e3f-3208-af65-4b34`** — Orchestrator topology. Several `redirect` rows (particularly `health.py`, `alert_store.py`, `fetcher.py`, `cursor_snapshot.py` directory layout) may be affected by topology decisions made in `9e3f-3208`. The `redirect` classification is contingent on whether `bridge_state/` is renamed in the new topology; if the directory name is preserved, those rows downgrade to no-action.

---

## Discovery Command

The inventory above was produced from:

```
grep -rn -E '(bridge_state|prev_snapshot|mapping\.json)' \
  --include='*.py' --include='*.sh' --include='*.yml' --include='*.md' \
  . 2>/dev/null | head -200
```

Run date: 2026-05-25. Commit context: session worktree `worktree-20260524-135547` at `4f454327e5`.
