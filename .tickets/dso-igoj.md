---
id: dso-igoj
status: open
deps: []
links: []
created: 2026-03-17T18:34:18Z
type: epic
priority: 0
assignee: Joe Oakhart
jira_key: DIG-30
---
# DSO project setup — automated script, interactive skill, and complete documentation

## Goal

A new engineer can fully onboard DSO into any project by invoking `/dso:project-setup` inside Claude Code. The skill calls `scripts/dso-setup.sh` for mechanical setup, then guides the user interactively through configuration. The process works on macOS, Linux, and WSL/Ubuntu without tribal knowledge.

## Why

Since transitioning to a plugin model, the setup path is unclear and partially stale. `dso-setup.sh` only installs the shim; it does not handle prerequisites, git hooks, or example configs. Teammates are waiting to use DSO once setup is stable. The primary entry point (`/dso:project-setup`) must be discoverable inside Claude Code — users should not need to know which script to run.

## Scope

### IN

- Audit `docs/INSTALL.md` and `scripts/dso-setup.sh` for stale or missing content post-plugin-transition
- Expand `dso-setup.sh`:
  - Prerequisite verification (Claude Code version, bash ≥4, GNU coreutils)
  - Pre-commit hook installation (`pre-commit install`)
  - Copy example configs (`.pre-commit-config.yaml`, `ci.yml`) when not present
  - Optional dependency detection + non-blocking install prompts (acli, PyYAML)
  - Environment variable guidance
  - Cross-platform support: macOS, Linux, WSL/Ubuntu
  - Idempotent (safe to re-run)
- Create `skills/project-setup/SKILL.md` — the primary user-facing entry point:
  - Calls `dso-setup.sh` for mechanical steps first
  - Interactive wizard: copy and customize DSO templates, generate `workflow-config.conf` with stack-detected defaults, configure git hooks
  - Offers optional dep installation (acli, PyYAML) — never blocks setup
  - Invokable before any project config exists (requires only `$CLAUDE_PLUGIN_ROOT`)
- Detailed reference documentation for all `workflow-config.conf` keys with descriptions and usage summaries
- Detailed reference for all environment variables used by DSO hooks and skills
- Rewrite `docs/INSTALL.md`:
  - New two-step flow: install plugin → invoke `/dso:project-setup`
  - Full config key reference
  - Environment variable reference
  - Optional dependency notes (acli, PyYAML)
  - Troubleshooting section for cross-platform edge cases
  - Remove stale content
- Absorb and close `dso-qii9` (Create a setup skill)

### OUT

- Changes to `workflow-config.conf` schema or adding new keys
- Automated CI testing of the setup process

## Entry Point

```
claude plugin install github:navapbc/digital-service-orchestra
# then, inside your project:
/dso:project-setup
```

`dso-setup.sh` is the mechanical engine — callable standalone for advanced/CI use — but most users interact with it only through the skill.

## Optional Dependencies

acli and PyYAML are optional. Both the script and skill must detect them, offer installation instructions, and continue without them if declined or unavailable.

## Proposed Stories

- **Story A**: Audit current setup path — trace from scratch on macOS; document INSTALL.md stale content and dso-setup.sh gaps post-plugin-transition
- **Story B**: Expand `dso-setup.sh` — prerequisites, pre-commit hooks, example configs, optional dep prompts, cross-platform
- **Story C**: Create `dso:project-setup` skill — calls dso-setup.sh, then interactive template copying, workflow-config.conf wizard, hook configuration
- **Story D**: Document `workflow-config.conf` keys + environment variables (detailed reference)
- **Story E**: Rewrite `docs/INSTALL.md` — new two-step flow, config/env reference, troubleshooting

## Success Criteria

- A teammate can set up DSO in a new project without asking Joe any questions
- Setup works on macOS, Linux, and WSL/Ubuntu
- Optional deps (acli, PyYAML) are surfaced and offered but never block setup
- `scripts/check-skill-refs.sh` exits 0 on all new skill and doc files

