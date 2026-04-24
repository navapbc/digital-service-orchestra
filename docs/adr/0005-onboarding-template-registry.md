# ADR 0002: Application Template Registry for Onboarding

- Status: accepted
- Deciders: @joeoakhart
- Date: 2026-03-28

Technical Story: d000-2598 (Application Template Integration for Onboarding)

## Context and Problem Statement

When `/dso:onboarding` runs against an empty project directory — one where `detect-stack.sh` returns `"unknown"` — users had no automated path to bootstrap a production-ready application skeleton. They were dropped directly into the manual Phase 2 configuration dialogue, which presupposes an existing codebase. This created friction for greenfield projects and led to inconsistent scaffolding choices across teams.

The question: how should onboarding offer vetted starter templates without hardcoding template details into the skill itself, and what install mechanisms should be supported?

## Decision Drivers

- Templates must be discoverable and extensible without modifying the SKILL.md
- Install mechanisms differ by template (nava-platform CLI vs. plain git clone)
- Some templates require user-supplied parameters (e.g., `app_name`) before install
- The flow must degrade gracefully when the registry is missing or the installer is unavailable
- `detect-stack.sh` must recognize the newly supported Ruby frameworks (Rails, Jekyll) so Phase 1.7 can re-detect and skip Phase 2

## Considered Options

1. Hardcode template choices directly in SKILL.md
2. YAML registry file parsed by a dedicated shell script, with two install paths
3. Remote registry fetched at runtime from a canonical URL

## Decision Outcome

Chosen option: **Option 2 — YAML registry with shell parser and two install paths.**

A static registry file (`plugins/dso/config/template-registry.yaml`) is the single source of truth for all available templates. `parse-template-registry.sh` validates the file and outputs tab-separated records consumed by the SKILL.md. Two install paths are implemented:

- **Phase 1.6a (nava-platform)**: For templates with `install_method: nava-platform`. Requires `uv` or `pipx` on PATH; installs the nava-platform CLI if absent, then runs `nava-platform app install` with `--data` flags populated from user answers. Falls back to manual flow if neither installer is found.
- **Phase 1.6b (git-clone)**: For templates with `install_method: git-clone`. Runs `git clone <repo_url> .` with no additional prerequisites.

Phase 1.7 re-runs `detect-stack.sh` after installation. If a framework is now detected, Phase 2 is skipped and onboarding proceeds to Phase 3. If detection still returns `"unknown"`, the user is warned and Phase 2 runs normally.

The template gate (Phase 1.5) is silent about registry errors — if `parse-template-registry.sh` returns no output, the gate is skipped and the manual flow is preserved. This makes the feature strictly additive with no regression risk for existing projects.

### New artifacts

| File | Role |
|------|------|
| `plugins/dso/config/template-registry.yaml` | Registry — 4 templates (nextjs, flask, rails, jekyll-uswds) |
| `plugins/dso/scripts/parse-template-registry.sh` | Validates registry; outputs tab-separated records |
| `plugins/dso/scripts/validate-nava-platform-headless.sh` | Spike validation script for nava-platform headless install |
| `plugins/dso/scripts/detect-stack.sh` | Extended with `ruby-rails` and `ruby-jekyll` detection |

## Consequences

### Positive

- Template list is extensible: add a YAML entry, no SKILL.md edits required.
- Both nava-platform and git-clone ecosystems are supported from day one.
- Graceful degradation: missing registry or missing installer never blocks onboarding.
- `detect-stack.sh` now covers Ruby stacks, making Phase 1.7 re-detection reliable for Rails and Jekyll projects.

### Negative

- nava-platform install path requires `uv` or `pipx` as a prerequisite; users without either must install one before templates become available.
- The YAML registry is static — updates to template repo URLs or required flags require a commit to this repository.

### Risks

- If a template repository moves or becomes unavailable, installation fails at runtime. No automated staleness check is in place; operators must monitor template repo health manually.
## Revision — 2026-04-23

Script path updated: `plugins/dso/scripts/parse-template-registry.sh` → `plugins/dso/scripts/onboarding/parse-template-registry.sh`.

All references in `plugins/dso/skills/onboarding/SKILL.md` and test files have been updated. Shim invocation is now `.claude/scripts/dso onboarding/parse-template-registry.sh`. Behavior unchanged. The decision recorded above remains valid; only the filesystem location moved to consolidate onboarding-only scripts under `scripts/onboarding/`.

