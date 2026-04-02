# ADR 0001: Shim Sentinel Self-Detection for DSO Plugin Root Resolution

**Status**: Accepted  
**Date**: 2026-04-01  
**Epic**: d111-5a40 — Environment-Portable Plugin: Dynamic Path Resolution + Web Environment Support

---

## Context

The DSO plugin shim (`.claude/scripts/dso`) dispatches plugin scripts by resolving a `DSO_ROOT` path. Before this change, resolution depended on either:

1. A `CLAUDE_PLUGIN_ROOT` environment variable explicitly set by the operator, or
2. A `dso.plugin_root=<path>` key in `.claude/dso-config.conf`.

Both mechanisms require manual configuration after installation. When the DSO plugin is installed as a subdirectory of the consuming project (the monorepo pattern, where `plugins/dso/` lives inside the same repo as the host project), neither mechanism fires automatically — the operator must remember to set a config key that could have been inferred from the file system.

This caused friction for first-time project setup and for CI environments where `CLAUDE_PLUGIN_ROOT` was not set in the environment.

A machine-readable sentinel file (`plugins/dso/.claude-plugin/plugin.json`) already existed in the plugin directory as a registry marker. This file is reliable: it is part of the plugin's tracked source, it is present whenever the plugin is installed at the canonical location, and its path is deterministic relative to any git repository root.

---

## Decision

Add a third step to the shim's `DSO_ROOT` resolution order:

**Step 3 — Sentinel self-detection**: If `$REPO_ROOT/plugins/dso/.claude-plugin/plugin.json` exists, set `DSO_ROOT="$REPO_ROOT/plugins/dso"` without any environment variable or config-file requirement.

This step runs only when steps 1 and 2 produce no result, preserving backward compatibility. The sentinel file serves as a zero-configuration signal that the plugin is installed at the canonical location.

The full resolution order is now:

1. `$CLAUDE_PLUGIN_ROOT` environment variable (explicit operator override)
2. `dso.plugin_root` key in `.claude/dso-config.conf` (config-file-based override)
3. Sentinel self-detection via `$REPO_ROOT/plugins/dso/.claude-plugin/plugin.json` (automatic, zero-config)
4. Exit with a non-zero error naming the config key and file

---

## Consequences

**Positive**:

- The shim works out of the box when the plugin is installed at `plugins/dso/` without any environment configuration.
- CI environments (GitHub Actions, Docker containers) no longer require `CLAUDE_PLUGIN_ROOT` to be injected as a secret or environment variable when using the monorepo layout.
- The portability smoke test (`.github/workflows/portability-smoke.yml`) validates the self-detection path in a clean Ubuntu container on each push.

**Neutral**:

- Steps 1 and 2 remain higher priority. An explicit `CLAUDE_PLUGIN_ROOT` or `dso.plugin_root` config key always wins over self-detection. Existing configurations are not affected.
- The sentinel file (`plugin.json`) is already tracked in the plugin source. No new file was introduced by this change.

**Risk**:

- If the sentinel file is deleted or the plugin directory is renamed, step 3 silently falls through to step 4 (the error exit). This is the correct fail-safe behavior: an unexpected layout should not silently use a wrong path.
