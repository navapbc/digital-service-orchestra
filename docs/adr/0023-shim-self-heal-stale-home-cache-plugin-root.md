# ADR 0023: Shim Self-Heal for Stale Marketplace Home-Cache Plugin Root

**Status**: Accepted
**Date**: 2026-06-17

---

## Context

ADR 0001 established the `DSO_ROOT` resolution order for the `.claude/scripts/dso`
shim, with the `dso.plugin_root` config key (step 2) taking precedence over
sentinel self-detection (steps 2.5 and 3). ADR 0001 stated that "existing
configurations are not affected" because steps 1 and 2 always win.

Bug 9841-4169 later hardened the **installer** (`onboarding/dso-setup.sh`) to stop
writing the installing developer's absolute marketplace home-cache path into
`.claude/dso-config.conf`, relying instead on the shim's step 2.5 home-cache
autodetect. New installs are therefore portable.

However, **legacy** host repos still carry a committed `dso.plugin_root` written
before that fix — an absolute path like
`/Users/<someone>/.claude/plugins/marketplaces/digital-service-orchestra/plugins/dso`.
That value is valid only on the machine that wrote it. On every other clone — and
in every fresh git worktree, which inherits the committed config rather than a
local `skip-worktree` override — step 2 reads the foreign path and short-circuits
before step 2.5 can autodetect the correct local cache. The result is a recurring,
confusing failure:

```
command not found: ticket (looked for /Users/<someone>/.../scripts/ticket)
```

The shim already knows the canonical autodetect for exactly this layout
(step 2.5), but it never runs because the foreign config value wins.

## Decision

Treat a `dso.plugin_root` value that has the **marketplace home-cache shape** as a
hint rather than an authoritative path. After reading it in step 2, if the value
ends with the canonical suffix
`.claude/plugins/marketplaces/digital-service-orchestra/plugins/dso` but has **no
plugin sentinel** (`.claude-plugin/plugin.json`) on the current machine, discard
it so resolution falls through to the step 2.5 home-cache autodetect.

The check is deliberately narrow:

- It fires **only** for the marketplace-cache suffix. Any other explicit,
  operator-chosen `dso.plugin_root` (vendored monorepo paths, custom install
  locations, relative paths) is used verbatim, preserving the ADR 0001
  "config wins" contract — including non-existent paths used in tests.
- It fires **only** when the configured cache path is invalid on this machine
  (sentinel absent). A valid local home-cache config is kept untouched.

A value that cannot possibly be correct (it names another machine's home cache)
is the only case overridden, and it is overridden by the shim's own, more
reliable autodetect.

The full resolution order is now:

1. `$CLAUDE_PLUGIN_ROOT` environment variable
2. `dso.plugin_root` in `.claude/dso-config.conf` — **a stale/foreign marketplace
   home-cache value with no sentinel here is discarded in favor of step 2.5**
3. (2.5) Self-detect: home-directory marketplace cache install (sentinel check)
4. (3) Self-detect: in-repo plugin directory via sentinel
5. Exit non-zero with a descriptive error

## Consequences

**Positive**:

- Legacy host repos with a committed foreign home-cache path self-heal on every
  machine and in every fresh worktree, with **no host-repo edit** required.
- When autodetect cannot resolve a local install either, the shim now exits with
  its clear "plugin root not configured" message instead of dispatching to a
  non-existent foreign path and failing with a misleading "command not found".

**Neutral**:

- Explicit non-marketplace `dso.plugin_root` values are unchanged — the ADR 0001
  precedence still holds for every path that is not a marketplace-cache shape.

**Risk**:

- If a developer intentionally points `dso.plugin_root` at a marketplace-cache
  path that is not yet populated (no sentinel), the shim will autodetect instead
  of using the configured value. This is the desired fail-safe: an unpopulated
  cache path is never a working plugin root.
