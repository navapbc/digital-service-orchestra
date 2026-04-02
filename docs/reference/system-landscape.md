---
last_synced_commit: 223a85d5080d755c692eddc5cca3474bdb9491d5
---

# System Landscape Reference

This document describes the structural components, boundaries, and resolution mechanisms of the DSO plugin. It reflects the current state of the system.

## Plugin Root Resolution (Shim)

The DSO shim (`.claude/scripts/dso`) resolves `DSO_ROOT` at dispatch time using a four-step priority chain. The first step that produces a value wins; subsequent steps are skipped.

| Step | Source | Mechanism |
|------|--------|-----------|
| 1 | Environment variable | `$CLAUDE_PLUGIN_ROOT` — explicit operator override; highest priority |
| 2 | Config file | `dso.plugin_root` key in `.claude/dso-config.conf` at the git repo root; supports relative paths (resolved against repo root) |
| 3 | Sentinel self-detection | `$REPO_ROOT/plugins/dso/.claude-plugin/plugin.json` exists → `DSO_ROOT` set to `$REPO_ROOT/plugins/dso` automatically; zero configuration required |
| 4 | Error exit | Non-zero exit with instructions to set `CLAUDE_PLUGIN_ROOT` or `dso.plugin_root` |

After resolution, `DSO_ROOT` is exported as `CLAUDE_PLUGIN_ROOT` (unless `CLAUDE_PLUGIN_ROOT` was already set by the caller). `PROJECT_ROOT` is also exported as the git repo root for use by dispatched scripts.

ADR: `docs/adr/0001-shim-sentinel-self-detection.md`

## Command Wrappers

`.claude/commands/*.md` files provide one wrapper per user-invocable skill (26 total). Each wrapper uses Claude Code's shell preprocessing to detect whether the DSO plugin is installed via the marketplace:

```
!`bash -c 'timeout 3 claude plugin list 2>/dev/null | grep -q "digital-service-orchestra" && echo "PLUGIN_DETECTED" || echo "LOCAL_FALLBACK"'`
```

- **PLUGIN_DETECTED**: Invoke the skill via the Skill tool (`/dso:<skill-name>`).
- **LOCAL_FALLBACK**: Read `plugins/dso/skills/<skill-name>/SKILL.md` inline and follow its instructions.

Wrapper files live in `.claude/commands/` and are named after the skill (e.g., `sprint.md`, `fix-bug.md`). They are not skill files — they are dispatch shims that choose between marketplace and local invocation.

## Portability Lint

`plugins/dso/scripts/check-portability.sh` detects hardcoded home-directory paths that break portability across machines and CI environments.

**Patterns flagged**:
- `/Users/<username>/` — macOS home directories
- `/home/<username>/` — Linux home directories

**Inline suppression**: Append `# portability-ok` to any line to exempt it from the check. Use this only for lines where the hardcoded path is intentional and documented (e.g., example output in documentation, test fixture data).

**Operation modes**:
- With file arguments: scans the specified files directly.
- Without arguments: discovers staged files via `git diff --cached --name-only --diff-filter=ACM`.

**Exit codes**: `0` — no violations; `1` — one or more violations.

**Hook registration**: Registered as a pre-commit hook in `.pre-commit-config.yaml`. Violations block commits. Violations are printed to stderr in `file:line` format.

**CI validation**: `.github/workflows/portability-smoke.yml` runs the shim self-detection path in a clean Ubuntu container to validate zero-config portability on each push.

## Agent Fallback

When a named sub-agent (dispatched via `subagent_type`) is unavailable or dispatch fails, agents read the agent definition inline from `plugins/dso/agents/<agent-name>.md`. The `<agent-name>` is the portion of `subagent_type` after the `dso:` prefix (e.g., `subagent_type: dso:complexity-evaluator` → `plugins/dso/agents/complexity-evaluator.md`). The file contents are used as a prompt and the agent logic runs inline.

All named agents are defined in `plugins/dso/agents/`. Agent routing configuration: `config/agent-routing.conf`.
