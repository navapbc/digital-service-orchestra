# Changelog — lockpick-workflow Plugin

All notable changes to this project will be documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versioning follows [Semantic Versioning](https://semver.org/) — see `docs/VERSIONING.md`.

---

## [v0.3.0] — 2026-03-09

### Summary

Config-driven validate-work migration. The `/validate-work` skill is now fully
parameterized via `workflow-config.yaml` — no hardcoded project-specific values
remain in the skill itself.

### Migrated: /validate-work → Config-Driven

- **Staging configuration**: All staging values (`url`, `deploy_check`, `test`,
  `routes`, `health_path`) are now read from `workflow-config.yaml` via
  `read-config.sh`. Previously these were hardcoded or passed as skill arguments.
- **Graceful degradation**: When `staging.url` is absent, all staging sub-agents
  (Sub-Agent 4 and Sub-Agent 5) are skipped automatically with the message
  `SKIPPED (staging not configured)`. Projects without staging environments
  can use validate-work without any staging config.
- **Deploy check dispatch (.sh vs .md)**: The `staging.deploy_check` value is
  dispatched by file extension: `.sh` files are executed as shell scripts
  (exit codes 0=healthy, 1=unhealthy, 2=deploying); `.md` files are read as
  sub-agent prompts. When absent, the skill falls back to a generic HTTP health
  check (Mode D).
- **Staging test dispatch (.sh vs .md)**: The `staging.test` value follows the
  same dispatch rules as `deploy_check`. When absent, the skill uses built-in
  generic tiered validation.
- **CI integration workflow**: The `ci.integration_workflow` config key allows
  validate-work's CI sub-agent to poll a separate integration test workflow.
  When absent, integration workflow checks are skipped.
- **Staging relevance classifier**: The optional `staging.relevance_script` key
  accepts a shell script that classifies whether the current changes affect the
  deployed application. When exit 1 (non-deployment changes), staging sub-agents
  are skipped automatically.
- **Visual baseline pre-check**: The `visual.baseline_directory` key is read
  to locate visual regression baselines before the staging environment test.

### Migration Guide

No action required for projects already using validate-work. The skill now
reads configuration from `workflow-config.yaml` on each invocation. To adopt
staging validation, add a `staging:` section to your `workflow-config.yaml`:

```yaml
staging:
  url: "https://your-staging-url.example.com"
  deploy_check: "scripts/check-staging-deploy.sh"   # optional
  test: "scripts/smoke-test-staging.sh"              # optional
  routes: "/,/upload"                                # optional, default: "/"
  health_path: "/health"                             # optional, default: "/health"
```

See `lockpick-workflow/docs/INSTALL.md` for full configuration reference.

---

## [v0.2.0] — 2026-02-28

### Summary

Initial public plugin release. Extracts the lockpick-doc-to-logic workflow
infrastructure into a standalone, reusable Claude Code plugin.

### Phase 1 — Plugin Scaffold

- Extracted 12 skills from the lockpick-doc-to-logic source project.
- Extracted 18 hooks into `hooks.json` with full event bindings.
- Copied 8 supporting scripts into `scripts/`.
- Copied 9 documentation files into `docs/`.
- Created `plugin.json` describing the plugin structure.

### Phase 2 — Config System

- Added `workflow-config.yaml` as the per-project configuration surface.
- Added `docs/workflow-config-schema.json` for config validation.
- Implemented `scripts/read-config.sh` — reads a key from `workflow-config.yaml`.
- Implemented `scripts/detect-stack.sh` — auto-detects project stack from repo contents.
- Added `/init` skill that generates a starter `workflow-config.yaml` for new projects.
- Updated 4 skills with config-system preambles so they read project config before acting.

### Phase 3 — Hook Parameterization

- Introduced `get_artifacts_dir()` in `hooks/deps.sh` — single source of truth for the
  state/artifact directory path, replacing hardcoded `/tmp/lockpick-*` paths throughout hooks.
- Migrated all hooks to call `get_artifacts_dir()` instead of building their own paths.
- Made `auto-format.sh` config-driven: reads formatter and file patterns from `workflow-config.yaml`.
- Parameterized `validation-gate.sh`, `review-gate.sh`, and `commit-failure-tracker.sh` to use
  `get_artifacts_dir()`.
- Updated workflow documentation (`COMMIT-WORKFLOW.md`, `REVIEW-WORKFLOW.md`) to reflect
  parameterized hook behavior.

### Phase 4 — CLAUDE.md Generation

- Added `/generate-claude-md` skill that produces a project-tailored `CLAUDE.md` from
  `workflow-config.yaml` and detected stack.
- Added a corresponding Markdown template in `templates/`.

### Phase 5 — Cross-Stack Integration Testing

- Validated plugin installation and behavior against Python/Flask, Node.js/TypeScript, and
  Go stacks.
- Confirmed config-driven hooks and skills work correctly across all tested stack types.
- Documented stack-specific caveats in `docs/MIGRATION-TO-PLUGIN.md`.

### Phase 6 — Marketplace Distribution

- Created `marketplace.json` with full distribution metadata (repository, homepage, license,
  install command, compatibility constraints, tags).
- Added `docs/INSTALL.md` with step-by-step installation and configuration instructions.
- Added semver versioning documentation (`docs/VERSIONING.md`) and this `CHANGELOG.md`.
- Added `scripts/tag-release.sh` for version-bump and release-tag workflow.

---

*For the full commit history see `git log --oneline`.*
