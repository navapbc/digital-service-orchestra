# 1e08 — Bound-but-absent re-emitter fix (design v4)

**Bug**: `1e08-1a35-0267-4ca6`. Local tickets bound to Jira keys absent from a pass's fetch working set re-emit field updates every pass.

**Goal**: stop the re-emit AND reliably replicate local→Jira edits — no silent drops.

> v4 changelog (from v3 review): [important] config keys are **env vars** (no dotted-config reader exists in the reconciler); [minor] two-file commit uses a **per-file** idempotency check (substring `"bindings.json"` would not match `"bindings-retired.json"` → silent drop); rotation key is the **string `pass_id`** (monotonic timestamp) with `""` never-GET'd sentinel; comment set is **first-page-bounded** (status quo); added the trivial `_rest_issue_to_snapshot_fields` helper so the parity test has a real symbol; refreshed stale line numbers (bound branch ~848-888; `client` + full `jira_snapshot` already passed to `_diff_comments` at ~857-858); acknowledged `bindings.json` now commits ~every pass when absent keys exist.
> v3 changelog: C1 `get_issue_by_rest` 404 = raised `HTTPError`; C2 no field helper, snapshot stores raw `fields`; C3 one-key overlay for `_diff_comments`; I1 three-point snapshot-commit + advisory-lock caveat; I2 retired-file fail-open; I3/I4 least-recently-GET'd rotation; M2 inbound gap tracked as `0702-3b6d-c1db-4ed3`.

## Root cause (confirmed)
`outbound_differ.py` bound branch (~848-888) — `jira_fields = jira_snapshot.get(jira_key, {})` returns `{}` when the bound key is absent from the search-derived snapshot, so `_diff_fields` compares every local field against `""` and emits an update. Two absence sub-classes:
- (a) Jira issue **deleted** → direct GET raises `HTTPError(404)`.
- (b) status=Done **outside** `_DONE_RECENT_CAP=1000` window (`fetcher.py:40-61`) → **alive, HTTP 200**, absent from the search snapshot only.

A bare "skip when absent" guard fixes the re-emit but **silent-drops** sub-class (b) edits. Inbound is also snapshot-bound (`inbound_differ.py:562`), so bare-skip fully strands out-of-window tickets.

## Design

### D1 — Membership discriminator + bounded direct GET (the fix)
`compute_outbound_mutations` already receives `client` and already passes the full `jira_snapshot` to `_diff_comments` (`outbound_differ.py:857-858`). One new param is needed: thread `pass_id` (in scope at `reconcile_once`, `reconcile.py:486`; call site `:821`) into `compute_outbound_mutations` for rotation bookkeeping (`set_last_get`). In the bound branch:

```
jira_key = binding_store.get_jira_key(local_id)   # None for pending → create branch (unchanged)
if jira_key in jira_snapshot:
    jira_fields = jira_snapshot[jira_key]          # EXISTING path, unchanged (raw fields dict)
    # diff as today; _diff_comments(ticket, jira_key, jira_snapshot, client=client) reads jira_snapshot[jira_key]
else:
    # bound-but-absent from THIS pass's working set
    if binding_store.is_retired(jira_key):
        continue                                    # known-dead; no GET, no emit (budget preserved)
    if jira_key in _selected_for_get_this_pass:     # rotation selection, below
        fields = _safe_get_issue(client, jira_key)
        if fields is _DELETED:                        # HTTPError 404
            binding_store.note_absent(jira_key)       # ++consecutive-404 counter; may retire (D2)
        elif fields is _TRANSPORT_ERROR:              # non-404 HTTPError / URLError / timeout
            pass                                      # emit nothing; warn; DEFERRED; counter untouched
        else:                                         # 200: fields == issue["fields"] (raw)
            binding_store.clear_absent(jira_key)      # reset counter — alive
            _overlay = dict(jira_snapshot); _overlay[jira_key] = fields   # one-key overlay (C3)
            # _diff_fields(ticket, fields, ...) via the SAME path as in-snapshot keys, and
            # _diff_comments(ticket, jira_key, _overlay, client=client) so comments use the
            # GET's native fields.comment.comments — NO second network call.
        binding_store.set_last_get(jira_key, pass_id) # rotation bookkeeping (any GET outcome)
    else:
        continue                                      # not selected this pass → DEFERRED (no emit)
```

**C1 — `_safe_get_issue` (verified against the call chain).** `get_issue_by_rest` (`acli-integration.py:1107`) returns `_direct_rest_get(path)` with no intermediate catch; `_rest_urlopen_with_retry` re-raises `HTTPError` without retry (`:1267-1269`). So:
```
def _safe_get_issue(client, jira_key):
    try:
        return client.get_issue_by_rest(jira_key).get("fields", {})   # 200 → raw fields
    except urllib.error.HTTPError as e:
        return _DELETED if e.code == 404 else _TRANSPORT_ERROR
    except (urllib.error.URLError, TimeoutError, OSError):
        return _TRANSPORT_ERROR
```
`HTTPError` must be caught before its parent `URLError`. Mirrors `.code` precedent (`acli-integration.py:319,328,497,2087`).

**C2 — field shape (no transform).** No REST→snapshot mapping helper exists; `fetcher.py:307` stores each entry as a verbatim `{k: fields[k] for k in sorted(fields)}` copy, and ALL normalization is downstream in `_diff_fields`/`_extract_jira_field` (`outbound_differ.py:246-415`), which iterates only `local_mapped.items()` (so GET-only extra fields are harmless). Provide a one-line helper purely so the parity test has a symbol:
```
def _rest_issue_to_snapshot_fields(issue): return issue.get("fields", {})
```
Do NOT add any normalization here (double-normalization would reintroduce phantom re-emits).

**C3 — comments via one-key overlay, single GET.** `_diff_comments` re-derives `jira_issue = jira_snapshot.get(jira_key, {})` (`:557`) and gates on `"comment" in jira_issue` (`:569`). A default `GET /issue/{key}` (no `fields=` limiter, `:1114`) returns the `comment` field at `fields.comment.comments` — the same shape `get_comment_map` builds. Passing `_overlay` (full snapshot + the one GET'd key) makes `_diff_comments` take the snapshot-carried path (post-6afc: machine-metadata exclusion + truncation-converge) with **zero extra network calls**. Note: a single GET returns only the **first page** of comments — identical to the existing `get_comment_map` enrichment limitation (`:1840-1869`), not a v4 regression.

**Rotation / fairness (I3/I4).** Per-binding `last_get_pass` (the string `pass_id`, a monotonic `%Y-%m-%dT%H-%M-%S` timestamp from `__main__.py:109`) is stored in `bindings.json`; never-GET'd uses sentinel `""` (sorts first). Each pass, bound-but-absent non-retired keys are sorted by `last_get_pass` ascending; the first `K` form `_selected_for_get_this_pass`. This bounds servicing of every absent key to ≤⌈N/K⌉ passes, so (i) a persistently-editing live out-of-window ticket cannot starve the tail, and (ii) a dead key accrues its GRACE consecutive-404 GETs within ≤GRACE·⌈N/K⌉ passes and retires, freeing budget. Second-granularity `pass_id` ties GET in arbitrary order (harmless).

### D2 — Binding lifecycle (GC), self-contained
In `binding_store.py` (no dependency on the unshipped pass-window substrate):
- `note_absent(jira_key)`: ++`absent_404_count`. At `>= GRACE` (default 3 *consecutive 404 GET results*), move the binding to `bindings-retired.json` (soft delete, reversible) + deduped `alert_store.append({kind:"binding-retired", jira_key, local_id})`.
- `clear_absent(jira_key)`: reset counter (any 200 GET).
- `set_last_get(jira_key, pass_id)`: rotation bookkeeping.
- `is_retired(jira_key)`: membership against the retired set (loaded once per pass).
- **Persistence (I1)**: generalize `_commit_binding_store_snapshot` (`reconcile.py:205-277`) to stage BOTH files via all **three** hardcoded points (`sync-hardening-proposal.md` §"Write path"): the `exists()` early-return guard (`reconcile.py:240`), the `git add` (`:247`), and the idempotency check (`:259`). **The `:259` check must become per-file** — the current substring test `"bindings.json" not in status.stdout` does NOT match `"bindings-retired.json"`, so a retirement-only change would be silently skipped; replace with explicit per-basename membership over `status.stdout` lines. Inherits the sanctioned `_advisory_lock.py:11` deviation (local-only, in-pass-serialized under the pass lock, reconciled by the workflow commit-back); adds NO remote push (would require `rebase_retry`).
  - **Churn note**: writing `last_get_pass`/counters means `bindings.json` changes on ~every pass that has absent keys, so the `:259` no-op fast path rarely fires — an extra local commit/push-back per such pass. Accepted: rotation state must persist to bound servicing; the cost is one small commit, in-pass-serialized.
- **Load semantics (I2)**: `bindings-retired.json` parse is **fail-OPEN** (corrupt → empty retired-set + deduped alert), NOT fail-closed. A retired binding wrongly treated as live costs exactly one GET (it re-404s → re-retires after GRACE), never a re-emit (404 emits nothing). Contrast `bindings.json` which stays fail-closed (bug 4292: losing real bindings → mass-create duplication). `absent_404_count`/`last_get_pass` live in `bindings.json` (open-dict entries, `save()` dumps `sort_keys=True` — schema-compatible) and inherit its fail-closed guard.

### D3 — see C3 (comments via the one-key overlay; single GET; first-page-bounded as status quo).

### D4 — Guarantees / non-guarantees (explicit)
- Guarantees: no `{}`-comparison re-emit; out-of-window **local** edits reach Jira (every absent key serviced ≤⌈N/K⌉ passes — never dropped); dead bindings retire after GRACE consecutive-404 GETs and stop consuming budget.
- Does NOT guarantee: inbound mirroring of out-of-window **Jira-side** edits (inbound snapshot-bound, `inbound_differ.py:562`). Tracked as **`0702-3b6d-c1db-4ed3`** (symmetric inbound bounded-GET, reusing this budget/retirement machinery).

### M1 — Budget arithmetic
Worst-case added REST cost per pass: ≤ K single-issue `GET /issue/{key}` (comment field included → no extra `get_comments` on the 200 path). K=20 default → ≤20 cheap immediately-consistent GETs/pass vs the paged-search budget the `f6cc` `_ACLI_CEILING=1200` cap protects — negligible.

## Config (env vars — the reconciler has no dotted-config reader; matches `fetcher.py`/`applier.py` env-var pattern; document in CONFIGURATION-REFERENCE.md alongside the other reconciler env vars)
- `RECONCILER_ABSENT_GET_BUDGET` — int, default **20** (per-pass bounded GETs; `K`).
- `RECONCILER_ABSENT_RETIRE_GRACE` — int, default **3** (consecutive-404 GETs before retirement).

**Defensive parse** (these are the reconciler's first int-valued env vars): wrap `int(os.environ.get(...))` in `try/except ValueError` falling back to the default (mirror `_get_dso_id_guard_mode_from_config`'s best-effort degradation, `applier.py:1488-1493`), and clamp `K >= 1`. A typo'd ops value must NOT abort the pass. Add a test: malformed value → default. (Optional future parity: env > `dso-config.conf` flat-key > default, per the `dso_id_guard_mode` template — not required now.)

## Regression tests (must-have)
1. Bound-but-absent, alive (200) → divergent fields → outbound update IS emitted with the real diff.
2. Bound-but-absent, 404 → zero mutations; after GRACE consecutive-404 GETs the binding retires; once retired, no further GET.
3. RED anchor — bound-but-absent never diffs local fields against `{}`/`""` (the original defect).
4. Present-with-empty-fields (key IN snapshot) still diffs and emits (membership, not value, is the discriminator).
5. Pending binding (`jira_key=None`) routes to the create branch, never the absent guard.
6. Recovered-this-pass binding absent from snapshot → bounded GET (200) resolves and syncs the same pass.
7. **C1**: `_safe_get_issue` maps raised `HTTPError(404)` → `_DELETED`; raised `HTTPError(500)`/`URLError`/timeout → `_TRANSPORT_ERROR` (counter NOT incremented).
8. **I3/I4**: N≫K persistently-absent **live** (200) tickets → every ticket serviced within ⌈N/K⌉ passes; a deleted key behind a saturated budget still retires in bounded passes.
9. A single 200 resets the absence counter (no premature retirement of a flapping issue).
10. **C2 parity**: `_rest_issue_to_snapshot_fields(real_GET_payload)` field VALUES match the fetcher snapshot entry on the intersecting field set (description ADF, parent `{key}`, priority/status `{name}`, assignee dict). Compare intersecting values, not dict equality (a GET returns a superset of the search `fields=` set, `acli-integration.py:1181`).
11. **C3**: the 200-path issues exactly ONE network call servicing both field-diff and comment-diff (no double-fetch).
12. **I2**: corrupt `bindings-retired.json` → pass proceeds, retired-set empty, alert emitted (fail-open).
13. **I1 (per-file commit)**: a retirement-only change (only `bindings-retired.json` modified) IS committed — the idempotency guard does NOT skip it.
14. **Idempotency anchor**: two consecutive passes over an unchanged bound-but-absent-alive issue → zero mutations on pass 2 (guards the 200-path against reintroducing churn — failure class of bugs 85a1/4175).
