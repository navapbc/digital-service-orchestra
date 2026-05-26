# Contract: Asymmetric Manifest

## Purpose

The reconciler emits a per-pass manifest whose shape varies by rollout mode.
Each mode trades verbosity against blast-radius risk: early rollout phases
enumerate every inbound write; later phases summarize.

The renderer lives at `${CLAUDE_PLUGIN_ROOT}/scripts/dso_reconciler/manifest_renderer.py`
and is dispatched from `applier.apply()` based on the `mode` argument
(threaded through from `__main__.main()` → `run_pass()` → `reconcile_once()`).

## Mode → manifest shape

| Mode                 | Cap (mutations applied) | Manifest file | Shape                                  |
| -------------------- | ----------------------- | ------------- | -------------------------------------- |
| `dry-run`            | 0                       | yes           | `render_dry_run_or_strict`             |
| `bootstrap-strict`   | 10                      | yes           | `render_dry_run_or_strict`             |
| `bootstrap-throttle` | 100                     | yes           | `render_throttle`                      |
| `live`               | uncapped                | NO            | GHA log only — `applier.apply` returns `None` for `manifest_path` |

`MODE_CAPS` is the single source of truth (`${CLAUDE_PLUGIN_ROOT}/scripts/dso_reconciler/mode.py`).

## Shapes

### `render_dry_run_or_strict`

```json
{
  "outbound": {
    "totals": {"create": <int>, "update": <int>, "delete": <int>}
  },
  "inbound": [
    {"key": "<jira-key-or-local-id>", "action": "<create|update|delete|...>", "fields": {...}},
    ...
  ],
  "applied_count": <int>,
  "deferred_count": <int>
}
```

* `outbound.totals` reports the union of applied + deferred outbound mutations.
* `inbound` enumerates every inbound mutation (applied + deferred) with full
  field detail. The early rollout phases treat inbound work as the dangerous
  side (writes to the local tracker), so operators need per-ticket evidence.
* `applied_count` + `deferred_count` together equal the total mutation count.

### `render_throttle`

```json
{
  "outbound": {"totals": {"create": <int>, "update": <int>, "delete": <int>}},
  "inbound":  {"totals": {"create": <int>, "update": <int>, "delete": <int>}},
  "spot_check": [
    {"key": "<...>", "direction": "<inbound|outbound>", "action": "<...>", "fields": {...}},
    ...
  ],
  "applied_count": <int>,
  "deferred_count": <int>
}
```

* Both directions summarized to totals.
* `spot_check` is a deterministic 10% sample selected by
  `hash(target) % 10 == 0`. Stable across runs as long as the target ID is
  stable. Renders the same field detail as `render_dry_run_or_strict.inbound[]`.

### `live`

No manifest file is written. `applier.apply()` returns `None` in place of the
manifest path. Per-pass observability comes from the GHA workflow log only.

## Deterministic ordering

Mutations passed to either renderer are pre-sorted by
`(direction, action, target)` (the same ordering enforced by
`applier.apply()`'s cap loop). The renderer preserves input order; do not
sort or shuffle inside the renderer.

## JSON serializability

Renderer output is a plain `dict` containing only JSON-primitives
(str / int / float / bool / None / list / dict). Callers may pass the result
directly to `json.dump`.
