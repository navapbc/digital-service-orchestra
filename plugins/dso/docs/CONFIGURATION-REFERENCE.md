---
last_synced_commit: cae021ba4ae077a7a0a8b5d2fced728204bdb610
---

# Configuration Reference

This document is the authoritative reference for all `dso-config.conf` keys and
environment variables consumed by DSO hooks, scripts, and skills.

---

## Table of Contents

- [Section 1 — dso-config.conf Keys](#section-1--dso-configconf-keys)
- [Section 2 — Environment Variables](#section-2--environment-variables)

---

## Section 1 — dso-config.conf Keys

`dso-config.conf` is an optional flat `KEY=VALUE` file placed at `.claude/dso-config.conf`
in the project root (or at `$CLAUDE_PLUGIN_ROOT/.claude/dso-config.conf`). Keys use dot-notation for grouping.
List values use repeated keys (one value per line). Parsed by `.claude/scripts/dso read-config.sh`
using `grep`/`cut` — no Python dependency required.

**Config resolution order** (handled by `.claude/scripts/dso read-config.sh`):
1. `WORKFLOW_CONFIG_FILE` env var if set (exact path — highest priority, for test isolation)
2. `$CLAUDE_PLUGIN_ROOT/.claude/dso-config.conf` if `CLAUDE_PLUGIN_ROOT` is set
3. `$(git rev-parse --show-toplevel)/.claude/dso-config.conf` (project root — most common)

Schema: `docs/workflow-config-schema.json`

---

### `version`

| | |
|---|---|
| **Description** | Config schema version (semver). Must be present. Increment minor when adding new keys. |
| **Accepted values** | `<major>.<minor>.<patch>` (e.g., `1.0.0`) |
| **Default** | No default — **required** |
| **Used by** | `.claude/scripts/dso validate-config.sh` |

---

### `stack`

| | |
|---|---|
| **Description** | Explicitly declares the project stack. When absent, `.claude/scripts/dso detect-stack.sh` auto-detects from marker files: `pyproject.toml` → `python-poetry`; `package.json` → `node-npm`; `Cargo.toml` → `rust-cargo`; `go.mod` → `golang`; `Gemfile` + `config/routes.rb` → `ruby-rails`; `Gemfile` + `_config.yml` → `ruby-jekyll`; `Makefile` → `convention-based`. Written automatically by `/dso:onboarding` Phase 3 Step 2b using the `$STACK_OUT` value from `detect-stack.sh`. |
| **Accepted values** | `python-poetry`, `node-npm`, `rust-cargo`, `golang`, `ruby-rails`, `ruby-jekyll`, `convention-based`, `unknown` |
| **Default** | Auto-detected |
| **Used by** | `.claude/scripts/dso detect-stack.sh`, all skills that resolve commands, `/dso:onboarding` (Phase 3 config generation) |

---

### `paths.app_dir`

| | |
|---|---|
| **Description** | Application directory, relative to the repo root. Controls where hooks, scripts, and skills look for source code, tests, and virtual environments. |
| **Accepted values** | Relative directory path (e.g., `app`, `.`, `backend`) |
| **Default** | `app` |
| **Used by** | `hooks/lib/config-paths.sh`, `scripts/validate.sh`, `scripts/agent-batch-lifecycle.sh`, `scripts/retro-gather.sh` | # shim-exempt: internal implementation references in config documentation

---

### `paths.src_dir`

| | |
|---|---|
| **Description** | Source code directory, relative to `paths.app_dir`. Used for file impact analysis and auto-format scope. |
| **Accepted values** | Relative directory path (e.g., `src`, `lib`) |
| **Default** | `src` |
| **Used by** | `hooks/lib/config-paths.sh`, `scripts/ticket-next-batch.sh` | # shim-exempt: internal implementation references in config documentation

---

### `paths.test_dir`

| | |
|---|---|
| **Description** | Test directory, relative to `paths.app_dir`. Used for test file discovery, snapshot paths, and file impact analysis. |
| **Accepted values** | Relative directory path (e.g., `tests`, `test`) |
| **Default** | `tests` |
| **Used by** | `hooks/lib/config-paths.sh`, `scripts/ticket-next-batch.sh` | # shim-exempt: internal implementation references in config documentation

---

### `paths.test_unit_dir`

| | |
|---|---|
| **Description** | Unit test directory, relative to `paths.app_dir`. Used for targeted test discovery when distinguishing unit from integration tests. |
| **Accepted values** | Relative directory path (e.g., `tests/unit`) |
| **Default** | Absent — falls back to `paths.test_dir` |
| **Used by** | `scripts/ticket-next-batch.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `interpreter.python_venv`

| | |
|---|---|
| **Description** | Path to the Python virtual environment interpreter, relative to the repo root. Used to locate the correct Python binary for running scripts and tests. |
| **Accepted values** | Relative file path (e.g., `app/.venv/bin/python3`, `.venv/bin/python3`) |
| **Default** | `app/.venv/bin/python3` |
| **Used by** | `hooks/lib/config-paths.sh`, `scripts/ticket-next-batch.sh` | # shim-exempt: internal implementation references in config documentation

---

### `format.extensions`

| | |
|---|---|
| **Description** | File extensions to process via the auto-format PostToolUse hook. Repeatable key (one extension per line). |
| **Accepted values** | `.py`, `.ts`, `.tsx`, etc. |
| **Default** | `.py` |
| **Used by** | `hooks/auto-format.sh` |

---

### `format.source_dirs`

| | |
|---|---|
| **Description** | Directories to restrict auto-format processing to, relative to repo root. Repeatable key (one directory per line). |
| **Accepted values** | Relative or absolute directory paths |
| **Default** | `app/src`, `app/tests` |
| **Used by** | `hooks/auto-format.sh` |

---

### `ci.fast_gate_job`

| | |
|---|---|
| **Description** | Display name of the fast-gate CI job. Checked first on any failure for early exit. Must match the `name:` field in your CI workflow file exactly. Written by `/dso:onboarding` Phase 3 Step 2b using `project-detect.sh` `ci_workflow_names` output. |
| **Accepted values** | String matching the CI job name |
| **Default** | `Fast Gate` |
| **Used by** | `.claude/scripts/dso ci-status.sh` |

---

### `ci.fast_fail_job`

| | |
|---|---|
| **Description** | Display name of the job whose `timeout-minutes` defines the end of the fast-fail polling phase. Must match the `name:` field in your CI workflow file exactly. Written by `/dso:onboarding` Phase 3 Step 2b using `project-detect.sh` `ci_workflow_names` output. |
| **Accepted values** | String matching the CI job name |
| **Default** | Same as `ci.fast_gate_job` |
| **Used by** | `.claude/scripts/dso ci-status.sh` |

---

### `ci.test_ceil_job`

| | |
|---|---|
| **Description** | Display name of the job whose `timeout-minutes` defines the end of the test polling phase. Must match the `name:` field in your CI workflow file exactly. Written by `/dso:onboarding` Phase 3 Step 2b using `project-detect.sh` `ci_workflow_names` output. |
| **Accepted values** | String matching the CI job name |
| **Default** | `Unit Tests` |
| **Used by** | `.claude/scripts/dso ci-status.sh` |

---

### `ci.workflow_name`

| | |
|---|---|
| **Description** | GitHub Actions workflow name for `gh workflow run`. Used by `merge-to-main.sh` for post-push CI trigger recovery when the push does not automatically trigger a run (e.g., after a fast-forward merge). When absent (and the deprecated `merge.ci_workflow_name` is also absent), the CI trigger recovery step is skipped entirely. **This is the preferred key** — `merge.ci_workflow_name` is deprecated and should be migrated to this key. |
| **Accepted values** | Exact workflow name string matching the `name:` field in your `.github/workflows/` YAML (e.g., `CI`, `Build and Test`, `Run Tests`) |
| **Default** | Absent — CI trigger recovery step skipped |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (ci_trigger phase) |

**Example values:**

```ini
# Minimal: single-word workflow name
ci.workflow_name=CI

# Multi-word: must match the workflow's name: field exactly
ci.workflow_name=Build and Test

# Common pattern for projects with a named pipeline
ci.workflow_name=Run Tests
```

**Migration from `merge.ci_workflow_name`:**

If your project currently uses `merge.ci_workflow_name`, migrate to this key:

1. Copy the value: `ci.workflow_name=<your-value>`
2. Remove the old key: delete the `merge.ci_workflow_name=` line
3. No other changes needed — `merge-to-main.sh` reads `ci.workflow_name` first

When `ci.workflow_name` is set, `merge.ci_workflow_name` is silently ignored. When only `merge.ci_workflow_name` is present, `merge-to-main.sh` falls back to it and logs a deprecation warning to stderr.

---

### `ci.integration_workflow`

| | |
|---|---|
| **Description** | GitHub Actions workflow filename for integration test status checks. Used to poll the integration workflow separately from the main CI workflow. When absent, integration workflow status checks are skipped. Distinct from `ci.workflow_name`: `ci.workflow_name` is the primary CI workflow for `merge-to-main.sh` trigger recovery; `ci.integration_workflow` is the integration test workflow polled by `/dso:sprint` Phase G and `ci-status.sh`. They may reference the same file or different ones. Written by `/dso:onboarding` Phase C Step 2b using a confidence-gated selection: when `project-detect.sh` returns `ci_workflow_confidence=high` with a single detected workflow, the value is written automatically; when confidence is low or multiple workflows are detected, the user is shown a numbered selection dialogue to identify which workflow serves which purpose. |
| **Accepted values** | Exact workflow name string (e.g., `Integration Tests`) |
| **Default** | Absent — integration checks skipped |
| **Used by** | `.claude/scripts/dso ci-status.sh`, validate-work skill, `/dso:onboarding` (Phase 3 config generation) |

---

### CI LLM Review — Classifier-Driven Tier Selection

The CI LLM review job selects the reviewer tier **automatically per-PR** based on the complexity classifier score. There is no manual tier override environment variable — tier selection is fully automatic. Score ranges:

| Classifier score | Tier dispatched |
|-----------------|-----------------|
| 0–2 | light (haiku — fast feedback) |
| 3–6 | standard (sonnet — comprehensive) |
| 7+ | deep (3 × sonnet + opus synthesis) |

Security, performance, and test-quality overlays are dispatched automatically when the classifier flags them. The 3-tier version resolution chain below controls which plugin version runs the classifier and reviewers.

---

### `ci.dso_plugin_version`

| | |
|---|---|
| **Description** | Overrides the DSO plugin version used in CI LLM review. This is **Tier 2** of the 3-tier version resolution chain implemented by `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-dso-version.sh`: **Tier 1** is `~/.claude/plugins/installed_plugins.json` (the Claude per-project plugin tracking file; key `dso@digital-service-orchestra`) — overridable via the `PLUGIN_TRACKING_FILE` env var; **Tier 2** is this config key in `.claude/dso-config.conf` (project-level override without editing the workflow) — overridable via the `DSO_CONFIG_FILE` env var; **Tier 3** is the `dso` (stable) channel in `.claude-plugin/marketplace.json` — overridable via the `MARKETPLACE_JSON` env var. The resolver does **not** fall back to the `dso-dev` channel; if Tier 3 is reached and the stable `dso` channel is absent or malformed, the resolver exits non-zero. When all three tiers fail, the workflow exits with a diagnostic indicating which tier(s) failed. | # shim-exempt: internal implementation references in config documentation
| **Accepted values** | A version tag (e.g., `v1.13.0`) or a marketplace channel name resolvable in `marketplace.json` |
| **Default** | Absent — Tier 1 (`installed_plugins.json`) or Tier 3 (`marketplace.json` `dso` channel) is used |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/resolve-dso-version.sh` (called by `ci-dso-fetch.sh` in the generated host-project CI workflow) | # shim-exempt: internal implementation references in config documentation

---

### `DSO_ASSETS_DIR` (CI environment variable)

| | |
|---|---|
| **Description** | Required in host-project CI when running `ci-llm-review-runner.sh` (shim in S3+; delegates to `python3 -m dso_ci_review.runner`) outside the DSO source checkout. When the runner detects that the marker file `${CLAUDE_PLUGIN_ROOT}/.dso-source-of-truth` is absent (indicating it is NOT running from the DSO local source), it falls back to `DSO_ASSETS_DIR` as the plugin root. If the marker is absent AND `DSO_ASSETS_DIR` is unset, the runner exits 1 with an error to stderr. In local DSO development, this variable is not required — the marker file is present and the runner uses a BASH_SOURCE-relative plugin root. |
| **Accepted values** | Absolute path to the fetched DSO plugin assets directory |
| **Default** | Absent — only required in host-project CI |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/ci-llm-review-runner.sh` (shim in S3+; delegates to `python3 -m dso_ci_review.runner`) (auto-detect runner mode) | # shim-exempt: plugin path in config documentation, not an invocation

---

### `commands.test`

| | |
|---|---|
| **Description** | Full test suite command. |
| **Accepted values** | Any shell command string (e.g., `make test`, `npm test`) |
| **Default** | Stack-derived (e.g., `poetry run pytest` for `python-poetry`) |
| **Used by** | Skills: `/dso:sprint`, `/dso:fix-bug`, `/dso:debug-everything` |

---

### `commands.test_dirs`

| | |
|---|---|
| **Description** | Colon-separated list of test directories. When set, `validate.sh` invokes `test-batched.sh` with `--runner=bash --test-dir=<dirs>` so each `test-*.sh` file runs as an individual resumable item. This enables incremental progress across `validate.sh` re-invocations for large test suites that exceed the 45s budget. When absent, `test-batched.sh` treats the entire suite as one atomic command (no sub-test resume). |
| **Accepted values** | Colon-separated directory paths relative to repo root (e.g., `tests/hooks:tests/scripts:tests/skills:tests/integration`) |
| **Default** | Empty (generic single-command runner) |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh` (`run_test_check`) | # shim-exempt: plugin path in config documentation, not an invocation

---

### `commands.test_runner`

| | |
|---|---|
| **Description** | Test runner command used by `suite-engine.sh` for individual test file execution. Distinct from `commands.test` (full suite) — this command is invoked per-file by the test batching infrastructure. |
| **Accepted values** | Any shell command string (e.g., `pytest`, `npx jest`, `bundle exec rspec`) |
| **Default** | Stack-derived (see per-stack defaults table below) |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/suite-engine.sh`, `${CLAUDE_PLUGIN_ROOT}/scripts/test-batched.sh` | # shim-exempt: plugin paths in config documentation, not invocations

---

### `commands.lint`

| | |
|---|---|
| **Description** | Linter command. |
| **Accepted values** | Any shell command string (e.g., `make lint`, `npm run lint`) |
| **Default** | Stack-derived (see per-stack defaults table below) |
| **Used by** | Skills: `/dso:sprint`, `/dso:fix-bug`, validate-work; `validate.sh` (as of story 8657-e8cc); `validate-phase.sh` (when present) |

---

### `commands.format`

| | |
|---|---|
| **Description** | Auto-formatter command — modifies files in place. |
| **Accepted values** | Any shell command string (e.g., `make format`, `cargo fmt`) |
| **Default** | Stack-derived (see per-stack defaults table below) |
| **Used by** | `hooks/auto-format.sh` (as of story 5278-dfae), skills; `validate-phase.sh` (when present) |

---

### `commands.format_check`

| | |
|---|---|
| **Description** | Formatting check command — fails if files need reformatting, does not modify files. |
| **Accepted values** | Any shell command string (e.g., `make format-check`, `cargo fmt --check`) |
| **Default** | Stack-derived (see per-stack defaults table below) |
| **Used by** | `.claude/scripts/dso validate.sh`, pre-commit hooks; `blast-radius.sh` (as of story 5b0c-7928); `dependency-check.sh` (as of story 5b0c-7928); `validate-phase.sh` (when present) |

---

### Per-stack defaults for `commands.*`

When a `commands.*` key is absent from `dso-config.conf`, DSO falls back to stack-derived defaults. The table below shows the pre-filled values used for each stack. Override any value by setting the key explicitly in `.claude/dso-config.conf`.

| Stack | `commands.test_runner` | `commands.lint` | `commands.format` | `commands.format_check` |
|---|---|---|---|---|
| Python (`python-poetry`) | `pytest` | `ruff check .` | `ruff format .` | `ruff format --check .` |
| Node/JS (`node-npm`) | `npx jest` | `npx eslint .` | `npx prettier --write .` | `npx prettier --check .` |
| Ruby (`ruby-rails` / `ruby-jekyll`) | `bundle exec rspec` | `bundle exec rubocop` | `bundle exec rubocop -A` | `bundle exec rubocop --format simple` |
| Rust (`rust-cargo`) | _(none — set explicitly)_ | _(none — set explicitly)_ | _(none — set explicitly)_ | _(none — set explicitly)_ |

---

### `commands.validate`

| | |
|---|---|
| **Description** | Full validation gate command. Typically runs lint + format-check + tests together. |
| **Accepted values** | Any shell command string (e.g., `./scripts/validate.sh --ci`) |
| **Default** | Stack-derived |
| **Used by** | Skills: `/dso:sprint`, `/dso:debug-everything` |

---

### `commands.test_unit`

| | |
|---|---|
| **Description** | Unit tests only — faster feedback loop, no integration or E2E tests. |
| **Accepted values** | Any shell command string (e.g., `make test-unit-only`, `npm run test:unit`) |
| **Default** | Stack-derived |
| **Used by** | Skills: `/dso:fix-bug`, `/dso:debug-everything` |

---

### `commands.test_e2e`

| | |
|---|---|
| **Description** | End-to-end test command. Typically slower, may require external services. |
| **Accepted values** | Any shell command string (e.g., `make test-e2e`, `npx @playwright/cli test`) |
| **Default** | Absent — E2E tests skipped when not set |
| **Used by** | `.claude/scripts/dso validate.sh`, validate-work skill |

---

### `commands.test_visual`

| | |
|---|---|
| **Description** | Visual regression test command. Compares screenshots against baselines. |
| **Accepted values** | Any shell command string |
| **Default** | Absent — visual tests skipped when not set |
| **Used by** | `.claude/scripts/dso validate.sh`, validate-work skill |

---

### `commands.test_changed`

| | |
|---|---|
| **Description** | Command to run changed integration/E2E tests before committing. When absent, Step 1 of `commit-workflow-validation.md` (the changed-tests step) is skipped. |
| **Accepted values** | Any shell command string (e.g., `./scripts/run-changed-tests.sh`) |
| **Default** | Absent — step skipped |
| **Used by** | `docs/workflows/COMMIT-WORKFLOW.md` |

---

### `commands.env_check_app`

| | |
|---|---|
| **Description** | Project-specific environment check command. Invoked by `.claude/scripts/dso check-local-env.sh` after generic checks. Exit 0 = all checks passed; non-zero = failure. |
| **Accepted values** | Any shell command string (e.g., `make env-check-app`) |
| **Default** | Absent — project-specific checks skipped |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `commands.env_check_cmd`

| | |
|---|---|
| **Description** | Full environment check command invoked by `.claude/scripts/dso agent-batch-lifecycle.sh` preflight step. Exit 0 = environment healthy; non-zero = environment issues found. |
| **Accepted values** | Any shell command string (e.g., `bash scripts/check-local-env.sh --quiet`) |
| **Default** | Absent — env check step skipped |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `commands.syntax_check`

| | |
|---|---|
| **Description** | Syntax check command run by `validate.sh` as a parallel lint step. When absent, `validate.sh` falls back to `make syntax-check`. Use `true` (no-op) to skip syntax checking on projects without a dedicated syntax step. |
| **Accepted values** | Any shell command string (e.g., `make syntax-check`, `true`) |
| **Default** | `make syntax-check` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh` | # shim-exempt: plugin path in config documentation, not an invocation

---

### `commands.lint_ruff`

| | |
|---|---|
| **Description** | Ruff linter command run by `validate.sh` as a parallel lint step. When absent, `validate.sh` falls back to `make lint-ruff`. Use this key to override the default ruff invocation (e.g., to restrict to specific paths or add `--select` flags). |
| **Accepted values** | Any shell command string (e.g., `ruff check ${CLAUDE_PLUGIN_ROOT}/scripts/*.py tests/**/*.py`, `make lint-ruff`) | # shim-exempt: plugin path in config documentation example, not an invocation
| **Default** | `make lint-ruff` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh` | # shim-exempt: plugin path in config documentation, not an invocation

---

### `commands.lint_mypy`

| | |
|---|---|
| **Description** | MyPy type-check command run by `validate.sh` as a parallel lint step. When absent, `validate.sh` falls back to `make lint-mypy`. Use `true` (no-op) to skip MyPy on projects that do not use type annotations. |
| **Accepted values** | Any shell command string (e.g., `mypy src/`, `make lint-mypy`, `true`) |
| **Default** | `make lint-mypy` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh` | # shim-exempt: plugin path in config documentation, not an invocation

---

### `jira.project`

| | |
|---|---|
| **Description** | Jira project key used by `.claude/scripts/dso ticket sync`. The `JIRA_PROJECT` environment variable takes precedence over this value. |
| **Accepted values** | Jira project key string (e.g., `DIG`, `MYPROJ`) |
| **Default** | No default — required when using `.claude/scripts/dso ticket sync` |
| **Used by** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync`, `.claude/scripts/dso jira-reset-sync.sh`, `.claude/scripts/dso reset-tickets.sh` | # shim-exempt: internal implementation references in config documentation

---

### `issue_tracker.search_cmd`

| | |
|---|---|
| **Description** | Command to search for existing tickets by substring. Used by `hooks/lib/pre-bash-functions.sh` (commit-failure-tracker) to detect duplicate tickets. |
| **Accepted values** | Any shell command string (e.g., `grep -rl`, `.claude/scripts/dso ticket list --filter`) |
| **Default** | `grep -rl` |
| **Used by** | `hooks/lib/pre-bash-functions.sh` |

---

### `design.system_name`

| | |
|---|---|
| **Description** | Name and version of the design system used by the project. |
| **Accepted values** | String (e.g., `USWDS 3.x`, `Material UI 5`, `None (custom)`) |
| **Default** | Absent — skill falls back to generic guidance |
| **Used by** | Skills: `/dso:onboarding`, `/dso:design-review`; Agent: `dso:ui-designer` (dispatched by `/dso:preplanning` Phase H Step 7) |

---

### `design.component_library`

| | |
|---|---|
| **Description** | Component library identifier used for adapter selection in design skills and component lookup. |
| **Accepted values** | `uswds`, `material`, `bootstrap`, `chakra`, `custom` |
| **Default** | Absent |
| **Used by** | Agent: `dso:ui-designer` (dispatched by `/dso:preplanning` Phase H Step 7) |

---

### `design.template_engine`

| | |
|---|---|
| **Description** | Template engine used for rendering UI components. Used by dso:ui-designer for adapter selection via resolve-stack-adapter.sh. |
| **Accepted values** | `jinja2`, `react`, `vue`, `svelte`, `handlebars` |
| **Default** | Absent |
| **Used by** | Agent: `dso:ui-designer` (dispatched by `/dso:preplanning` Phase H Step 7) |

---

### `design.design_notes_path`

| | |
|---|---|
| **Description** | Path to the project's North Star design document, relative to repo root. |
| **Accepted values** | Relative file path (e.g., `.claude/design-notes.md`, `docs/design-notes.md`) |
| **Default** | `.claude/design-notes.md` |
| **Used by** | Skills: `/dso:design-review`, `/dso:onboarding` |

---

### `design.manifest_patterns`

| | |
|---|---|
| **Description** | Glob patterns for design manifest files. Used by `.claude/scripts/dso verify-baseline-intent.sh` to locate design manifests for baseline intent checks. Repeatable key. |
| **Accepted values** | Glob pattern strings relative to repo root |
| **Default** | `designs/*/manifest.md`, `designs/*/brief.md` |
| **Used by** | `.claude/scripts/dso verify-baseline-intent.sh` |

---

### `design.figma_pat`

| | |
|---|---|
| **Description** | Personal Access Token for Figma REST API. Used by `figma-auth.sh` to authenticate pull-back requests. Read from this config key; `FIGMA_PAT` environment variable takes precedence if set. Do not commit actual PAT values — use the `FIGMA_PAT` env var or a `.gitignore`-d local config override instead. |
| **Accepted values** | Figma PAT string (typically prefixed `figd_`); optional when `FIGMA_PAT` env var is set |
| **Default** | Absent — `FIGMA_PAT` env var is the fallback; missing PAT produces a clear error with configuration instructions |
| **Used by** | `scripts/figma-auth.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `design.figma_staleness_days`

| | |
|---|---|
| **Description** | Number of days after which a story tagged `design:awaiting_import` is considered stale. When the tag age exceeds this threshold, `/dso:sprint` appends a `⚠️ STALE (>N days)` warning to that story's dashboard line. Requires `design.figma_collaboration=true` to be meaningful. |
| **Accepted values** | Positive integer (number of days) |
| **Default** | `7` |
| **Used by** | `/dso:sprint` (story dashboard display, Phase B) |

---

## Planning

### `planning.external_dependency_block_enabled`

| | |
|---|---|
| **Description** | When `true`, skills emit an External Dependencies block and pause for user confirmation on manual-step dependencies. When `false` (default), the shape heuristic never fires and all four skills behave identically to the pre-feature baseline. |
| **Accepted values** | `true` / `false` |
| **Default** | `false` |
| **Used by** | `/dso:brainstorm` (Phase A Gate shape heuristic + block renderer), `/dso:preplanning` (block reader + story generator), `/dso:implementation-plan` (tag guard), `/dso:sprint` (manual-pause handshake) |

---

### `planning.verification_command_timeout_seconds`

| | |
|---|---|
| **Description** | Maximum time in seconds to wait for a `verification_command` to complete during `/dso:sprint`'s manual-pause handshake. If the command does not exit within this window, the handshake is treated as unverified. |
| **Accepted values** | Positive integer (seconds) |
| **Default** | `30` |
| **Used by** | `/dso:sprint` (manual-pause handshake `verification_command` execution) |

---

### `visual.baseline_directory`

| | |
|---|---|
| **Description** | Path to the visual baseline snapshots directory, relative to repo root. Used for baseline intent checks. Note: differs from `merge.visual_baseline_path`, which is used by `merge-to-main.sh`. |
| **Accepted values** | Relative directory path (e.g., `app/tests/e2e/snapshots/`) |
| **Default** | Absent — baseline intent check skipped |
| **Used by** | `.claude/scripts/dso verify-baseline-intent.sh` |

---

### `database.ensure_cmd`

| | |
|---|---|
| **Description** | Command to start the database. Used by `agent-batch-lifecycle.sh` preflight `--start-db`. |
| **Accepted values** | Any shell command string (e.g., `make db-start`, `docker compose up -d db`) |
| **Default** | Absent — DB start step skipped |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `database.status_cmd`

| | |
|---|---|
| **Description** | Command to check database status. Exit 0 = running, non-zero = stopped. |
| **Accepted values** | Any shell command string (e.g., `make db-status`, `pg_isready -h localhost`) |
| **Default** | Absent — DB status check skipped |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `database.port_cmd`

| | |
|---|---|
| **Description** | Command to resolve the database port for the current worktree. Receives worktree name as `$1` and port type as `$2`. Used for port conflict detection. |
| **Accepted values** | Any shell command string (e.g., `echo 5432`) |
| **Default** | Absent |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `database.base_port`

| | |
|---|---|
| **Description** | Base database port number. Worktree-specific ports are derived by adding an offset to this value. |
| **Accepted values** | Integer (e.g., `5432`) |
| **Default** | `5432` |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `worktree.post_create_cmd`

| | |
|---|---|
| **Description** | Command to run after creating a new worktree (relative to repo root). When absent, post-create phase is skipped. |
| **Accepted values** | Any shell command string (e.g., `./scripts/worktree-setup-env.sh`) |
| **Default** | Absent — skipped |
| **Used by** | `.claude/scripts/dso worktree-create.sh` |

---

### `worktree.service_start_cmd`

| | |
|---|---|
| **Description** | Command to run before launching Claude Code (e.g., start background services). Used by `.claude/scripts/dso claude-safe` pre-launch phase. When absent, service startup step is skipped. |
| **Accepted values** | Any shell command string (e.g., `make start`, `docker compose up -d`) |
| **Default** | Absent — skipped |
| **Used by** | `.claude/scripts/dso claude-safe` (pre-launch phase) |

---

### `worktree.python_version`

| | |
|---|---|
| **Description** | Python version for worktree environment setup. Used by `.claude/scripts/dso worktree-setup-env.sh` to find the correct Python binary. When absent, falls back to any `python3` on PATH. |
| **Accepted values** | Version string matching `<major>.<minor>` (e.g., `3.13`, `3.12`) |
| **Default** | Absent — falls back to `python3` |
| **Used by** | `.claude/scripts/dso worktree-setup-env.sh` (when present) |

---

### `worktree.branch_pattern`

| | |
|---|---|
| **Description** | Git branch naming pattern for worktree validation and cleanup. Used to identify branches created by worktree workflows during automated cleanup. |
| **Accepted values** | Branch name pattern (e.g., `worktree-*`) |
| **Default** | Absent — cleanup uses default heuristics |
| **Used by** | `scripts/worktree-cleanup.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `worktree.max_age_hours`

| | |
|---|---|
| **Description** | Maximum age in hours for automatic worktree cleanup. Worktrees older than this threshold are candidates for removal. Overridden by `AGE_HOURS` env var. |
| **Accepted values** | Positive integer |
| **Default** | `12` |
| **Used by** | `scripts/worktree-cleanup.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `worktree.isolation_enabled`

| | |
|---|---|
| **Description** | When `true`, orchestrators running inside a worktree session pass `isolation: "worktree"` to each Agent/Task dispatch, giving each sub-agent its own sandboxed working directory. When `false` or absent, sub-agents share the orchestrator's working directory (legacy shared-directory mode). Affects `/dso:sprint`, `/dso:fix-bug`, and `/dso:debug-everything` sub-agent dispatch. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `/dso:sprint`, `/dso:fix-bug`, `/dso:debug-everything`, `skills/shared/prompts/worktree-dispatch.md` |

---

### `infrastructure.container_prefix`

| | |
|---|---|
| **Description** | Docker container name prefix for worktree-specific containers. Used to discover and clean up containers belonging to deleted worktrees. |
| **Accepted values** | String prefix (e.g., `myapp-postgres-worktree-`) |
| **Default** | Absent |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `infrastructure.compose_project`

| | |
|---|---|
| **Description** | Docker Compose project name prefix for worktree-specific stacks. The worktree directory name is appended. |
| **Accepted values** | String prefix (e.g., `myapp-db-`) |
| **Default** | Absent |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `infrastructure.db_container`

| | |
|---|---|
| **Description** | Exact Docker container name for the database. Used by `.claude/scripts/dso check-local-env.sh` for container health checks. When absent, DB container check is skipped. |
| **Accepted values** | Exact container name string (e.g., `myapp-postgres`) |
| **Default** | Absent — container check skipped |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `infrastructure.db_container_patterns`

| | |
|---|---|
| **Description** | Partial Docker container name patterns to match when the exact `db_container` name is not found. Checked in order; first match wins. Repeatable key. |
| **Accepted values** | Partial container name strings |
| **Default** | Absent |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `infrastructure.required_tools`

| | |
|---|---|
| **Description** | CLI tools that must be present in PATH. `check-local-env.sh` fails if any are missing. Repeatable key. |
| **Accepted values** | Tool names (e.g., `jq`, `git`, `curl`, `docker`) |
| **Default** | `jq`, `git`, `curl` |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `infrastructure.optional_tools`

| | |
|---|---|
| **Description** | CLI tools that are helpful but not required. `check-local-env.sh` emits a warning (not a failure) if any are missing. Repeatable key. |
| **Accepted values** | Tool names (e.g., `shasum`, `pg_isready`) |
| **Default** | `shasum` |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `infrastructure.db_port`

| | |
|---|---|
| **Description** | Port for the database health check. Overrides the `DB_PORT` environment variable. |
| **Accepted values** | Integer port number (e.g., `5432`) |
| **Default** | `5432` (or `DB_PORT` env var if set) |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `infrastructure.app_port`

| | |
|---|---|
| **Description** | Port for the application health check. Overrides the `APP_PORT` environment variable. |
| **Accepted values** | Integer port number (e.g., `3000`) |
| **Default** | `3000` (or `APP_PORT` env var if set) |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `infrastructure.health_timeout`

| | |
|---|---|
| **Description** | Timeout in seconds for HTTP health checks. |
| **Accepted values** | Integer number of seconds (e.g., `5`) |
| **Default** | `5` |
| **Used by** | `.claude/scripts/dso check-local-env.sh` |

---

### `infrastructure.app_base_port`

| | |
|---|---|
| **Description** | Base application port number. Worktree-specific ports are derived by adding an offset. |
| **Accepted values** | Integer (e.g., `3000`, `8000`) |
| **Default** | `3000` |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `infrastructure.compose_files`

| | |
|---|---|
| **Description** | Docker Compose files to shut down on session exit. Used by `.claude/scripts/dso claude-safe` post-exit Docker cleanup. When absent or Docker is not on PATH, cleanup is skipped silently. Repeatable key. |
| **Accepted values** | Relative paths to Compose files (e.g., `docker-compose.yml`) |
| **Default** | Absent — cleanup skipped |
| **Used by** | `.claude/scripts/dso claude-safe` (post-exit phase) |

---

### `infrastructure.compose_db_file`

| | |
|---|---|
| **Description** | Docker Compose file specifically for database services. Used by worktree cleanup to tear down database containers. When absent but `infrastructure.compose_project` or `infrastructure.container_prefix` is set, a partial-config warning is emitted and Docker cleanup is skipped. |
| **Accepted values** | Relative path to a Compose file (e.g., `docker-compose.db.yml`) |
| **Default** | Absent — Docker DB cleanup skipped |
| **Used by** | `scripts/worktree-cleanup.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `session.usage_check_cmd`

| | |
|---|---|
| **Description** | Command to check session context window usage. Exit 0 = usage IS high (>90%); non-zero = normal. Used by `agent-batch-lifecycle.sh` pre-check and context-check subcommands. |
| **Accepted values** | Any shell command string (e.g., `$HOME/.claude/check-session-usage.sh`) |
| **Default** | Absent — usage checks skipped |
| **Used by** | `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `session.artifact_prefix`

| | |
|---|---|
| **Description** | Prefix for `/tmp` artifact directories (e.g., `myproject-test-artifacts`). When absent, derived from `basename(git repo root) + -test-artifacts`. |
| **Accepted values** | String prefix without spaces |
| **Default** | Derived from repo name |
| **Used by** | `.claude/scripts/dso worktree-create.sh`, `hooks/lib/deps.sh` (`get_artifacts_dir`) |

---

### `checks.script_write_scan_dir`

| | |
|---|---|
| **Description** | Directory to scan for coupling-lint violations. When absent, the script-writes check is skipped entirely. |
| **Accepted values** | Directory path (e.g., `.`) |
| **Default** | Absent — check skipped |
| **Used by** | `.claude/scripts/dso validate.sh` |

---

### `checks.assertion_density_cmd`

| | |
|---|---|
| **Description** | Command to run assertion density analysis on test files. When absent, assertion_coverage is scored null in retro reviews. |
| **Accepted values** | Any shell command string (e.g., `python3 scripts/check_assertion_density.py`) |
| **Default** | Absent — scored null |
| **Used by** | `/dso:sprint` retro review |

---

### `review.max_resolution_attempts`

| | |
|---|---|
| **Description** | Maximum number of autonomous fix/defend attempts the review resolution loop makes before escalating to the user. Controls the Autonomous Resolution Loop in REVIEW-WORKFLOW.md, test-failure delegation in COMMIT-WORKFLOW.md and TEST-FAILURE-DISPATCH.md, and the oscillation-check safety bounds. |
| **Accepted values** | Positive integer |
| **Default** | `5` |
| **Used by** | `REVIEW-WORKFLOW.md` (Autonomous Resolution Loop), `COMMIT-WORKFLOW.md` (Steps 1, 1.5), `TEST-FAILURE-DISPATCH.md`, `/dso:oscillation-check` |

---

### `review.minor_findings_create_tickets`

| | |
|---|---|
| **Description** | Controls whether the post-pass findings inspection block in REVIEW-WORKFLOW.md auto-files `minor` and `suggestion` severity findings as bug tickets. Default is fail-closed — minor findings are surfaced as PR comments only and do not become standalone tickets. Auto-filing without opt-in produced the deferred-nitpick treadmill: tickets that sit at pri=3/4 indefinitely and burn triage cost without ever being acted on (bugs 57b9, 9726, 5329). Set to `true` only when the project has process discipline to triage and close minor-finding tickets promptly. |
| **Accepted values** | `true` \| `false` (any other value or absence is treated as `false`) |
| **Default** | `false` |
| **Used by** | `scripts/should-create-minor-finding-tickets.sh` (the gate consulted by `REVIEW-WORKFLOW.md` post-pass inspection) | # shim-exempt: internal implementation reference in config documentation

---

### `review.behavioral_patterns`

| | |
|---|---|
| **Description** | Semicolon-delimited glob list of file patterns the review complexity classifier treats as behavioral (full scoring weight). Files matching these patterns receive higher blast_radius and critical_path scores, making them more likely to route to standard or deep review tiers. |
| **Accepted values** | Semicolon-delimited glob patterns (e.g., `skills/**;hooks/**`) |
| **Default** | Absent — classifier uses built-in heuristics only |
| **Used by** | `scripts/review-complexity-classifier.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `review.size_upgrade_lines`

| | |
|---|---|
| **Description** | Minimum number of scorable added lines in a diff that triggers a tier upgrade to deep review. When a non-merge diff meets or exceeds this threshold, the classifier sets `size_action=upgrade`, which causes ci-llm-review-runner.sh (shim in S3+; delegates to `python3 -m dso_ci_review.runner`) to route to the deep tier regardless of the score-based selected tier. This mirrors the local `/dso:review` Step 3b REVIEW_AGENT_OVERRIDE behavior. |
| **Accepted values** | Positive integer. Values of `0` are valid (every diff triggers upgrade). Non-numeric values are ignored and the default applies. |
| **Default** | `300` |
| **Used by** | `scripts/review-complexity-classifier.sh`, `scripts/ci-llm-review-runner.sh` (shim in S3+; delegates to `python3 -m dso_ci_review.runner`) | # shim-exempt: internal implementation reference in config documentation

---

### `review.size_warn_lines`

| | |
|---|---|
| **Description** | Minimum number of scorable added lines in a diff that triggers a SIZE_WARNING log on stderr. When a non-merge diff meets or exceeds this threshold, the classifier sets `size_action=warn` and emits `SIZE_WARNING: <N>` to stderr. The runner does not upgrade the tier on `warn` — the warning is informational only. |
| **Accepted values** | Positive integer. Must be greater than `review.size_upgrade_lines` for the thresholds to have distinct effects. Non-numeric values are ignored and the default applies. |
| **Default** | `600` |
| **Used by** | `scripts/review-complexity-classifier.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `review.huge_diff_file_threshold`

| | |
|---|---|
| **Description** | Minimum number of changed files in a diff that activates the large-refactor review path. When a diff meets or exceeds this threshold, review routing switches to the extended large-diff workflow instead of the standard deep-tier path. |
| **Accepted values** | Positive integer. Values of `0` or negative are a validation error and will halt review dispatch with an error message. |
| **Default** | `20` |

---

### `review.context_aug.soft_cap`

| | |
|---|---|
| **Description** | Per-call soft cap on context-augmentation turns in the CI review dispatch loop. At this turn count the dispatcher issues a first nudge asking the reviewer to finalize findings; a second nudge fires at `soft_cap+3`; the loop fails-closed at `soft_cap+4` (single critical finding recorded). Applies to standard, deep, and overlay tiers only — light tier is always single-shot and ignores this key. Can be overridden per-call via the `soft_cap` parameter of `dispatch_review()`. |
| **Accepted values** | Positive integer |
| **Default** | `15` (module constant `CONTEXT_AUG_SOFT_CAP` in `scripts/dso_ci_review/dispatch.py`) |
| **Used by** | `scripts/dso_ci_review/dispatch.py` (`dispatch_review()`) | # shim-exempt: internal implementation reference in config documentation

---

### `review.context_aug.max_file_bytes`

| | |
|---|---|
| **Description** | Per-file size cap for the `read_files` context-request action. Files larger than this limit are read up to the cap and a truncation marker is appended to inform the reviewer that content is incomplete. Enforced by `execute_read_files()`. |
| **Accepted values** | Positive integer (bytes) |
| **Default** | `262144` (256 KB — hardcoded in `scripts/dso_ci_review/context_request.py`) |
| **Used by** | `scripts/dso_ci_review/context_request.py` (`execute_read_files()`) | # shim-exempt: internal implementation reference in config documentation

---

### `review.context_aug.grep_timeout_seconds`

| | |
|---|---|
| **Description** | Wall-clock timeout for the `grep` context-request action. Prevents runaway pattern matching (ReDoS) from stalling the augmentation loop. On timeout the handler returns `timed_out: true` and the turn is treated as producing no output. |
| **Accepted values** | Positive integer (seconds) |
| **Default** | `5` (constant `_GREP_DEFAULT_TIMEOUT_SECONDS` in `scripts/dso_ci_review/context_request.py`) |
| **Used by** | `scripts/dso_ci_review/context_request.py` (`execute_grep()`) | # shim-exempt: internal implementation reference in config documentation

---

### `review.context_aug.contract_version`

| | |
|---|---|
| **Description** | Version of the CI Review Context-Request Contract implemented by the dispatcher. Unversioned requests default to version 1 for backward compatibility. Currently unversioned in `dso-config.conf` — this key is reserved for future use when a breaking schema change requires version negotiation. |
| **Accepted values** | Positive integer (currently only `1` is defined) |
| **Default** | `1` (see `${CLAUDE_PLUGIN_ROOT}/docs/contracts/ci-review-context-request.md` §Schema Evolution) |
| **Used by** | `scripts/dso_ci_review/context_request.py` (parser; version 1 baseline) | # shim-exempt: internal implementation reference in config documentation

---

### `debug.max_fix_validate_cycles`

| | |
|---|---|
| **Description** | Maximum number of fix→validate cycles the `/dso:debug-everything` validation loop runs before stopping and reporting remaining open bugs. One cycle = Bug-Fix Mode pass over all open tickets followed by a Validation Mode diagnostic scan. When set to `0`, the validation loop is skipped entirely and execution proceeds directly to Phase J after Bug-Fix Mode. Values `> 10` are capped at `10` with a warning. Non-numeric values default to `3` with a warning. |
| **Accepted values** | Non-negative integer (0–10; values above 10 are capped) |
| **Default** | `3` |
| **Used by** | `/dso:debug-everything` (Validation Mode inner loop) |

---

### `debug.intent_search_budget`

| | |
|---|---|
| **Description** | Maximum number of tool calls the intent search sub-agent (Intent Gate) may use when scanning for bug intent signals in open tickets and recent commit history. Controls the bounded search budget for Intent Gate before it must emit a result. Non-numeric values default to `20` with a warning. |
| **Accepted values** | Positive integer |
| **Default** | `20` |
| **Used by** | `/dso:debug-everything` (Intent Gate intent search sub-agent) |

---

### `debug.gha_scan_enabled`

| | |
|---|---|
| **Description** | Controls whether Phase A (GitHub Actions pre-scan) runs in `/dso:debug-everything`. When `false`, the GHA scan is skipped entirely — no sub-agent is dispatched and no ticket operations are performed. When absent or `true`, the scan proceeds (subject to `debug.gha_workflows` being non-empty). |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `/dso:debug-everything` (Phase A — GHA pre-scan) |

---

### `debug.gha_workflows`

| | |
|---|---|
| **Description** | Comma-separated list of GitHub Actions workflow file names to scan for CI failures in Phase A of `/dso:debug-everything`. Each value must match the file name exactly (e.g., `ci.yml`). When absent or empty, the GHA scan is skipped with the message `"GHA scan skipped: no workflows configured"`. |
| **Accepted values** | Comma-separated list of workflow file names |
| **Default** | (empty — scan skipped when absent) |
| **Used by** | `/dso:debug-everything` (Phase A — GHA pre-scan) |

---

### `scope_drift.enabled`

| | |
|---|---|
| **Description** | When true, `/dso:fix-bug` runs the scope-drift reviewer (`dso:scope-drift-reviewer`) at Phase F Step 1 after fix verification. When false, Phase F Step 1 is skipped. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `/dso:fix-bug` (Phase F Step 1 scope-drift review) |

---

### `preplanning.interactive`

| | |
|---|---|
| **Description** | Controls whether `/dso:preplanning` runs in interactive mode (pauses at user-facing checkpoints) or non-interactive mode (auto-applies or skips all checkpoints for automated/CI contexts). When absent, preplanning defaults to `true` (interactive) — preserving the behavior of projects that existed before this key was introduced. |
| **Type** | boolean |
| **Accepted values** | `true` (interactive — pause at all checkpoints and wait for user input); `false` (non-interactive — auto-apply or skip all checkpoints) |
| **Default** | `true` when absent |
| **Used by** | `/dso:preplanning` (all 7 interactive checkpoints) |

**Checkpoint behavior table** — how each checkpoint behaves when `preplanning.interactive=false`:

| Checkpoint | Interactive behavior | Non-interactive fallback |
|---|---|---|
| CP1 — No epic-id provided | Prompts user to supply an epic ID | Exits immediately with `INTERACTIVITY_DEFERRED` error |
| CP2 — Escalation policy | Asks user to choose escalation policy | Defaults to "Escalate when blocked" |
| CP3 — Scope clarification | Pauses for user to clarify scope | Exits immediately with `INTERACTIVITY_DEFERRED` error |
| CP4 — Reconciliation approval | Presents diff for user approval before applying changes | Auto-applies changes; `in_progress` child story deletions are logged and skipped (not deleted) |
| CP5 — Story dashboard | Presents story dashboard summary to user | Suppresses dashboard presentation; continues silently |
| CP6 — Final approval | Waits for explicit user approval before proceeding | Skips approval gate; proceeds automatically |
| CP7 — UI-designer checkpoints | Pauses at each ui-designer dispatch checkpoint | Uses `INTERACTIVITY_DEFERRED` paths in the ui-designer dispatch protocol |

**Migration note for existing projects:**

Before this key existed, `/dso:preplanning` always ran interactively. With the key **absent**, preplanning continues to default to `true` (interactive) — there is **no behavior change** for existing projects that do not set this key.

- To explicitly preserve interactive behavior: add `preplanning.interactive=true` to `.claude/dso-config.conf`
- To enable non-interactive / automated mode: add `preplanning.interactive=false` to `.claude/dso-config.conf`

**KNOWN_KEYS registration note:**

When adding `preplanning.interactive` to a new host project's `dso-config.conf`, also add `preplanning.interactive` to the `KNOWN_KEYS` array in `validate-config.sh` to prevent CI breakage on unknown-key validation. DSO's own `KNOWN_KEYS` registration was completed in story d481-3e6c.

---

### `brainstorm.max_interaction_cycles`

| Key | Type | Default | Description |
|---|---|---|---|
| `brainstorm.max_interaction_cycles` | integer | 2 | Maximum number of cross-epic interaction re-scans allowed after practitioner resolves an ambiguity or conflict. When absent, defaults to 2. |

After each resolution of an AMBIGUITY or CONFLICT cross-epic signal, brainstorm re-runs the cross-epic scan to check for remaining interactions. This key bounds how many re-scans can occur before brainstorm presents any remaining unresolved signals to the practitioner and asks whether to proceed.

| | |
|---|---|
| **Accepted values** | Positive integer |
| **Default** | `2` |
| **Used by** | `/dso:brainstorm` (cross-epic interaction re-scan loop) |

---

### `brainstorm.enforce_entry_gate`

| | |
|---|---|
| **Description** | When `true`, the `pre-enterplanmode.sh` PreToolUse hook blocks EnterPlanMode unless a brainstorm sentinel file exists at `$ARTIFACTS_DIR/brainstorm-sentinel`. Non-feature workflows (fix-bug, debug-everything, sprint, implementation-plan, preplanning, resolve-conflicts, architect-foundation, retro) are exempt via `$ARTIFACTS_DIR/active-skill-context`. Set to `false` to disable the gate entirely. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `hooks/lib/session-misc-functions.sh` (`pre-enterplanmode.sh` entry gate) |

---

### `brainstorm.max_feasibility_cycles`

| | |
|---|---|
| **Description** | Maximum number of feasibility-reviewer re-evaluation cycles brainstorm runs when the epic scrutiny pipeline returns a `FEASIBILITY_GAP`. After each gap annotation, brainstorm re-enters its understanding loop; this key bounds how many times that loop can repeat before brainstorm presents the unresolved gap to the user and stops. |
| **Accepted values** | Positive integer |
| **Default** | `2` |
| **Used by** | `/dso:brainstorm` (epic scrutiny pipeline feasibility loop, Phase 2) |

---

### `brainstorm.ui_keywords`

**Type**: string (comma-separated keywords)
**Default**: built-in UI surface lexicon; see `skills/brainstorm/prompts/ui-keyword-trigger.md` for the authoritative default keyword list
**Override semantics**: REPLACES the default lexicon entirely (not merged). Set this to restrict or expand detection to project-specific UI keywords.
**Example**: `brainstorm.ui_keywords=form,wizard,panel,chart,grid`
**Used by**: Phase 1 Gate Step 1.5 (UI Intent Detection) in brainstorm SKILL.md

---

### `merge.strategy`

| | |
|---|---|
| **Description** | Controls which merge flow `merge-to-main.sh` executes. `direct` runs the direct git merge/push flow. `pr` creates a GitHub PR and waits for CI before merging. |
| **Accepted values** | `direct` \| `pr` |
| **Default** | `direct` |
<!-- REVIEW-DEFENSE: merge-to-main-direct.sh and merge-to-main-pr.sh are created in task d5cb-c871 which has a direct dependency on this task (bed3-e2af). This is a GREEN documentation-first task per TDD sequencing. -->
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (dispatcher routes to `merge-to-main-direct.sh` or `merge-to-main-pr.sh` based on this value) |

**Example**: `merge.strategy=pr`

**Default selection**: `create-dso-app.sh` installer writes `direct` as the initial default for new projects. `/dso:onboarding` Phase 3 Step 2b.1 may override with the user's choice.

---

### `enforcement.strategy`

| | |
|---|---|
| **Description** | Controls where enforcement hooks run. `local` — enforcement hooks run on local commits (git pre-commit); `ci` — local enforcement hooks are skipped (enforcement deferred to CI); `both` — enforcement runs on both local commits and in CI. |
| **Accepted values** | `local` \| `ci` \| `both` |
| **Default** | `local` |
<!-- REVIEW-DEFENSE: enforcement-gate.sh was implemented and committed in story 5177-ec04 in the session branch. This worktree was dispatched before that commit landed; the file exists and will be present after harvest. -->
| **Used by** | `hooks/lib/enforcement-gate.sh` (consumed by `pre-commit-review-gate.sh`, `pre-commit-test-gate.sh`, `pre-commit-test-quality-gate.sh`, `hooks/lib/review-gate-bypass-sentinel.sh` (PreToolUse Layer 2)) |

**Example**: `enforcement.strategy=local`

---

### `hooks.compliance_verifier.enabled`

| | |
|---|---|
| **Description** | Enables or disables the pre-commit compliance verifier gate. When `true` (default), the gate runs on every local commit and checks that required review, test, and lint steps have been recorded as completed before allowing the commit to proceed. When `false`, the gate exits 0 immediately with no checks. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `hooks/pre-commit-compliance-verifier.sh` |

**`enforcement.strategy=ci` interaction**: When `enforcement.strategy=ci`, the compliance verifier gate is skipped locally (enforcement is deferred to CI). In this mode, the individual steps checked by the gate — `test`, `format`, `lint`, `classifier-dispatch`, and `reviewer-record` — should be written with `skip` markers (via `commit-step.sh skip <step> "enforcement.strategy=ci"`) so the gate does not block commits that are intentionally deferring to CI enforcement.

**Example**: `hooks.compliance_verifier.enabled=true`

---

## Ruleset Provisioning Knobs

The following are CLI flags accepted by `${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/provision-ruleset.sh`. They are NOT `dso-config.conf` keys — they are passed as command-line arguments when provisioning the GitHub Ruleset. Each flag has a default that matches the prior hardcoded behavior so existing invocations remain backward compatible. # shim-exempt: internal implementation references in config documentation

### `--bypass-actor-policy`

| | |
|---|---|
| **Description** | Bypass mode applied to the `bypass_actors` entry on the Ruleset. `always` allows admins to bypass at any time; `pull_request_only` restricts the bypass window to pull-request flows. Setting a non-default value requires an admin token (script exits 1 if `gh auth status` does not report admin scope). |
| **Accepted values** | `always` \| `pull_request_only` |
| **Default** | `always` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/provision-ruleset.sh` | # shim-exempt: internal implementation references in config documentation

**Example**: `provision-ruleset.sh --bypass-actor-policy=pull_request_only`

---

### `--require-conversation-resolution`

| | |
|---|---|
| **Description** | Maps to the `required_review_thread_resolution` parameter on the Ruleset's `pull_request` rule. When `true`, GitHub requires every PR review thread to be marked resolved before merge. |
| **Accepted values** | `true` \| `false` (also `1`/`0`, `yes`/`no`) |
| **Default** | `false` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/provision-ruleset.sh` | # shim-exempt: internal implementation references in config documentation

**Example**: `provision-ruleset.sh --require-conversation-resolution=true`

---

### `--request-copilot-review`

| | |
|---|---|
| **Description** | When `true`, the script records the preference in dry-run output and the success summary. GitHub does not currently expose Copilot code review configuration via the Rulesets API — the flag is a documented placeholder for future automation when API support lands. |
| **Accepted values** | `true` \| `false` |
| **Default** | `false` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/provision-ruleset.sh` | # shim-exempt: internal implementation references in config documentation

**Example**: `provision-ruleset.sh --request-copilot-review=true`

---

### `--dismiss-stale-approvals-on-push`

| | |
|---|---|
| **Description** | Maps to the `dismiss_stale_reviews_on_push` parameter on the Ruleset's `pull_request` rule. When `true`, GitHub dismisses prior approvals when new commits are pushed to the PR branch. |
| **Accepted values** | `true` \| `false` |
| **Default** | `false` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/provision-ruleset.sh` | # shim-exempt: internal implementation references in config documentation

**Example**: `provision-ruleset.sh --dismiss-stale-approvals-on-push=true`

---

### `--required-approvals`

| | |
|---|---|
| **Description** | Maps to the `required_approving_review_count` parameter on the Ruleset's `pull_request` rule. Sets the minimum number of approving reviews required before a PR can be merged. |
| **Accepted values** | Non-negative integer |
| **Default** | `1` |
| **Used by** | `${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/provision-ruleset.sh` | # shim-exempt: internal implementation references in config documentation

**Example**: `provision-ruleset.sh --required-approvals=2`

---

### `merge.visual_baseline_path`

| | |
|---|---|
| **Description** | Path to visual baseline snapshot directory, relative to repo root. When absent, `merge-to-main.sh` skips the baseline intent check. |
| **Accepted values** | Relative directory path (e.g., `app/tests/e2e/snapshots/`) |
| **Default** | Absent — check skipped |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` |

---

### `merge.ci_workflow_name`

> **Deprecated** — use [`ci.workflow_name`](#ciworkflow_name) instead. When `ci.workflow_name` is set, `merge.ci_workflow_name` is ignored. When only `merge.ci_workflow_name` is present, `merge-to-main.sh` falls back to it and logs the following deprecation warning to stderr:
> ```
> DEPRECATION WARNING: merge.ci_workflow_name is deprecated — migrate to ci.workflow_name in dso-config.conf
> ```
> Migrate by moving the value to `ci.workflow_name` and removing this key.

| | |
|---|---|
| **Description** | (**Deprecated**) GitHub Actions workflow name for `gh workflow run`. Used for post-push CI trigger recovery. Superseded by `ci.workflow_name`, which is checked first. When absent (and `ci.workflow_name` is also absent), the CI trigger recovery step is skipped. |
| **Accepted values** | Exact workflow name string matching the `name:` field in your `.github/workflows/` YAML (e.g., `CI`, `Build and Test`) |
| **Default** | Absent — step skipped |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (ci_trigger phase — fallback only when `ci.workflow_name` is absent) |

**Migration:** Replace `merge.ci_workflow_name=<value>` with `ci.workflow_name=<value>` in `dso-config.conf`. No other changes required.

---

### `merge.message_exclusion_pattern`

| | |
|---|---|
| **Description** | Regex pattern for filtering commits when composing the merge message. Passed to `grep -vE`. |
| **Accepted values** | Extended regex string |
| **Default** | `^chore: post-merge cleanup` |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` |

---

### `merge.pr_poll_interval_seconds`

| | |
|---|---|
| **Description** | How often the PR-mode merge loop polls CI check conclusions for the open PR. Lower values increase responsiveness at the cost of GitHub API call volume. Only consulted when `merge.strategy=pr`. |
| **Accepted values** | Positive integer (seconds) |
| **Default** | `30` |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (PR-mode `_phase_poll`) |

**Example**: `merge.pr_poll_interval_seconds=15` (default: `merge.pr_poll_interval_seconds=30`)

---

### `merge.pr_max_wait_seconds`

| | |
|---|---|
| **Description** | Maximum time the PR-mode merge loop will wait for CI completion before exiting non-zero with the PR URL. Prevents indefinite spin on a permanently broken required check. Only consulted when `merge.strategy=pr`. |
| **Accepted values** | Positive integer (seconds) |
| **Default** | `3600` |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (PR-mode `_phase_poll`) |

**Example**: `merge.pr_max_wait_seconds=7200` (default: `merge.pr_max_wait_seconds=3600`)

---

### `merge.pr_max_thread_dispatches`

| | |
|---|---|
| **Description** | Maximum number of LLM dispatches the thread-resolution loop (`_phase_resolve_threads`) will issue across all threads before escalating. Prevents runaway LLM calls when threads keep re-opening. Only consulted when `merge.strategy=pr`. |
| **Accepted values** | Positive integer |
| **Default** | `10` |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (PR-mode `_phase_resolve_threads`) |

**Example**: `merge.pr_max_thread_dispatches=20` (default: `merge.pr_max_thread_dispatches=10`)

---

### `merge.pr_thread_resolution_max_wait_seconds`

| | |
|---|---|
| **Description** | Wall-clock cap for the thread-resolution loop (`_phase_resolve_threads`). If threads remain unresolved after this many seconds, the loop escalates rather than waiting indefinitely. Only consulted when `merge.strategy=pr`. |
| **Accepted values** | Positive integer (seconds) |
| **Default** | `1800` |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (PR-mode `_phase_resolve_threads`) |

**Example**: `merge.pr_thread_resolution_max_wait_seconds=3600` (default: `merge.pr_thread_resolution_max_wait_seconds=1800`)

---

### `merge.pr_thread_quiet_window_seconds`

| | |
|---|---|
| **Description** | Minimum quiet period (no new unresolved threads) required before `_phase_resolve_threads` considers all threads settled and returns success. Prevents premature exit when review bots post follow-up threads after a short delay. Only consulted when `merge.strategy=pr`. |
| **Accepted values** | Positive integer (seconds) |
| **Default** | `120` |
| **Used by** | `.claude/scripts/dso merge-to-main.sh` (PR-mode `_phase_resolve_threads`) |

**Example**: `merge.pr_thread_quiet_window_seconds=60` (default: `merge.pr_thread_quiet_window_seconds=120`)

---

### `staging.url`

| | |
|---|---|
| **Description** | Base URL of the staging environment. When absent, all staging sub-agents are skipped. |
| **Accepted values** | Full URL string (e.g., `https://staging.example.com`) |
| **Default** | Absent — staging checks skipped |
| **Used by** | Validate-work skill, `.claude/scripts/dso staging-smoke-test.sh` |

---

### `staging.deploy_check`

| | |
|---|---|
| **Description** | Path to a script or prompt file for checking deploy status. `.sh` = executed as shell; `.md` = read as prompt for staging sub-agent. Exit contract: 0 = healthy, 1 = unhealthy, 2 = deploying (retry later). |
| **Accepted values** | Relative path to `.sh` or `.md` file |
| **Default** | Absent — deploy check skipped |
| **Used by** | Validate-work skill |

---

### `staging.test`

| | |
|---|---|
| **Description** | Path to a script or prompt file for running smoke/acceptance tests against staging. `.sh` = executed as shell (exit 0 = all passed); `.md` = read as prompt. |
| **Accepted values** | Relative path to `.sh` or `.md` file |
| **Default** | Absent — staging tests skipped |
| **Used by** | Validate-work skill |

---

### `staging.routes`

| | |
|---|---|
| **Description** | Comma-separated list of URL paths to health-check on the staging URL (e.g., `/,/upload,/history`). |
| **Accepted values** | Comma-separated path list |
| **Default** | `/` |
| **Used by** | Validate-work skill, `.claude/scripts/dso staging-smoke-test.sh` |

---

### `staging.health_path`

| | |
|---|---|
| **Description** | URL path for the primary health endpoint on the staging environment. |
| **Accepted values** | URL path string (e.g., `/health`, `/api/health`) |
| **Default** | `/health` |
| **Used by** | Validate-work skill, `.claude/scripts/dso staging-smoke-test.sh` |

---

### `persistence.source_patterns`

| | |
|---|---|
| **Description** | Literal substring patterns (grep -F) for identifying persistence/data-layer source files. Used by the persistence coverage check to verify that data-layer code has corresponding integration tests. Repeatable key. |
| **Accepted values** | File path substrings (e.g., `src/core/data_store.py`, `src/adapters/db/`) |
| **Default** | Absent — persistence coverage check skipped |
| **Used by** | `scripts/check-persistence-coverage.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `persistence.test_patterns`

| | |
|---|---|
| **Description** | Extended regex patterns (grep -E) for identifying persistence integration test files. Paired with `persistence.source_patterns` to validate coverage. Repeatable key. |
| **Accepted values** | Extended regex patterns (e.g., `tests/integration/.*test_.*_db_roundtrip`) |
| **Default** | Absent — persistence coverage check skipped |
| **Used by** | `scripts/check-persistence-coverage.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `skills.playwright_debug_reference`

| | |
|---|---|
| **Description** | Path to the project-specific playwright-debug reference file, relative to repo root. Read by the `/dso:playwright-debug` skill for framework-specific symptom tables, code patterns, and worked examples. When absent, the skill uses generic inline fallback guidance. |
| **Accepted values** | Relative file path (e.g., `docs/playwright-debug-reference.md`) |
| **Default** | Absent — skill uses generic guidance |
| **Used by** | `/dso:playwright-debug` skill |

---

### `tickets.prefix`

| | |
|---|---|
| **Description** | Ticket ID prefix used when generating new ticket IDs. When absent, the v3 ticket system derives the prefix from the project directory name. |
| **Accepted values** | Short string without spaces (e.g., `dso`, `my-project`) |
| **Default** | Derived from repo directory name |
| **Used by** | `.claude/scripts/dso ticket` (v3 ticket dispatcher), `scripts/ticket-reducer.py` | # shim-exempt: internal implementation reference in config documentation

---

### `tickets.directory`

| | |
|---|---|
| **Description** | Directory where ticket markdown files are stored, relative to repo root. |
| **Accepted values** | Relative directory path |
| **Default** | `.tickets` |
| **Used by** | `.claude/scripts/dso ticket` (v3 ticket dispatcher), `scripts/ticket-reducer.py`, `hooks/check-validation-failures.sh` | # shim-exempt: internal implementation references in config documentation

---

### `tickets.sync.jira_project_key`

| | |
|---|---|
| **Description** | Jira project key for .claude/scripts/dso ticket sync. Only needed when using `.claude/scripts/dso ticket sync` with Jira. Superseded by `jira.project` — prefer `jira.project` for new configurations. |
| **Accepted values** | Jira project key string (e.g., `DTL`, `MYPROJ`) |
| **Default** | Absent |
| **Used by** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` | # shim-exempt: internal implementation references in config documentation

---

### `tickets.sync.bidirectional_comments`

| | |
|---|---|
| **Description** | Enable bidirectional comment sync between local tickets and Jira. When true, comments added locally are pushed to Jira and vice versa. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` | # shim-exempt: internal implementation references in config documentation

---

### `ticket.display_mode`

| | |
|---|---|
| **Description** | Controls how ticket IDs are displayed in CLI output and skill files. |
| **Accepted values** | `auto` (default) — cascade: jira_key → alias → short → canonical (most human-friendly form); `canonical` — full 16-hex ID: `xxxx-xxxx-xxxx-xxxx`; `alias` — adj-noun-noun alias from CREATE event `data.alias` (falls back to `canonical` if absent); `short` — shortest unambiguous prefix >= 4 hex chars (falls back to `canonical` if ambiguous). Unrecognized values fall back to `auto` with a warning. |
| **Default** | `auto` |
| **Used by** | `.claude/scripts/dso ticket` (display formatting) |

**Example:**

```ini
ticket.display_mode=alias
```

---

### `version.file_path`

| | |
|---|---|
| **Description** | Path to the file that holds this project's semver string, relative to repo root. When absent, `.claude/scripts/dso bump-version.sh` skips version bumping entirely. Supported formats: `.json` → reads/writes the `version` key; `.toml` → reads/writes the `version` field; plaintext/no extension → single semver line (entire file content). Written by `/dso:onboarding` Phase 3 Step 2b using `project-detect.sh` `version_files` output: when one file is detected, the path is written automatically; when two or more are detected, the user is shown a numbered selection dialogue to choose the canonical version file; when none are detected, the key is omitted with an explanatory comment. |
| **Accepted values** | Relative file path |
| **Default** | Absent — version bumping skipped |
| **Used by** | `.claude/scripts/dso bump-version.sh`, `/dso:onboarding` (Phase 3 config generation) |

---

### `monitoring.tool_errors`

| | |
|---|---|
| **Description** | Enable tool error tracking and auto-ticket creation. |
| **Default** | Absent (disabled) |
| **Valid values** | `true` (enabled) or absent/any non-true value (disabled) |
| **Behavior when `true`** | `hook_track_tool_errors()` tracks errors to `~/.claude/tool-error-counter.json` and `sweep_tool_errors()` creates tickets when a category reaches 50 occurrences |
| **Behavior when absent/false** | Both functions return 0 immediately with no side effects |
| **Used by** | `hooks/lib/session-misc-functions.sh` (`hook_track_tool_errors`), `hooks/track-tool-errors.sh`, `scripts/end-session/error-sweep.sh` (`sweep_tool_errors`) |

---

### `dso.plugin_root`

| | |
|---|---|
| **Description** | Absolute path to the DSO plugin root directory. Written automatically by `.claude/scripts/dso dso-setup.sh`. Used by the `.claude/scripts/dso` shim in host projects when `CLAUDE_PLUGIN_ROOT` is not set. |
| **Accepted values** | Absolute directory path |
| **Default** | Set by `dso-setup.sh` |
| **Used by** | `.claude/scripts/dso` shim (host projects) |

---

### `checkpoint.marker_file`

| | |
|---|---|
| **Description** | Name of the marker file written to the repo root before a pre-compaction auto-save checkpoint commit. When the marker file is present at `pre-all` hook time, the hook skips its enforcement checks and allows the checkpoint commit to proceed unimpeded. Written by `/dso:onboarding` as `.checkpoint-pending-rollback`. |
| **Accepted values** | File name (no path separators; written relative to repo root) |
| **Default** | `.checkpoint-pending-rollback` |
| **Used by** | `hooks/lib/pre-all-functions.sh` (checkpoint bypass detection) |

---

### `clarity_check.pass_threshold`

| | |
|---|---|
| **Description** | Minimum clarity score (integer) for a ticket to pass the heuristic clarity gate in `ticket-clarity-check.sh`. Tickets scoring below this value are flagged as unclear. Valid range: 1 or higher (the script enforces a minimum of 1). |
| **Accepted values** | Positive integer (e.g., `5`) |
| **Default** | `5` |
| **Used by** | `scripts/ticket-clarity-check.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `implementation_plan.approach_resolution`

| | |
|---|---|
| **Description** | Controls how the `dso:approach-decision-maker` agent resolves competing implementation proposals. In `autonomous` mode the agent selects the best proposal without user input and proceeds directly to task drafting. In `interactive` mode the proposals are presented to the user who makes the final selection before task drafting begins. |
| **Accepted values** | `autonomous`, `interactive` |
| **Default** | `autonomous` |
| **Used by** | `/dso:implementation-plan` (proposal resolution loop, Phase 1 Step 2) |

---

### `model.haiku`

| | |
|---|---|
| **Description** | Canonical model ID for the haiku agent tier. Used by `resolve-model-id.sh` to look up the model string passed to Agent/Task dispatches. Override to pin to a specific model version or substitute a different model for the haiku tier. |
| **Accepted values** | Anthropic model ID string (e.g., `claude-haiku-4-5-20251001`) |
| **Default** | No built-in default — **required** when any haiku-tier agent is dispatched |
| **Used by** | `scripts/resolve-model-id.sh`, `scripts/enrich-file-impact.sh`, `scripts/semantic-conflict-check.py` | # shim-exempt: internal implementation references in config documentation

---

### `model.sonnet`

| | |
|---|---|
| **Description** | Canonical model ID for the sonnet agent tier. Used by `resolve-model-id.sh` to look up the model string passed to Agent/Task dispatches. Override to pin to a specific model version or substitute a different model for the sonnet tier. |
| **Accepted values** | Anthropic model ID string (e.g., `claude-sonnet-4-6`) |
| **Default** | No built-in default — **required** when any sonnet-tier agent is dispatched |
| **Used by** | `scripts/resolve-model-id.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `model.opus`

| | |
|---|---|
| **Description** | Canonical model ID for the opus agent tier. Used by `resolve-model-id.sh` to look up the model string passed to Agent/Task dispatches. Override to pin to a specific model version or substitute a different model for the opus tier. |
| **Accepted values** | Anthropic model ID string (e.g., `claude-opus-4-6`) |
| **Default** | No built-in default — **required** when any opus-tier agent is dispatched |
| **Used by** | `scripts/resolve-model-id.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `model.provider`

| | |
|---|---|
| **Description** | CI LLM provider for `python3 -m dso_ci_review.runner`. Controls which provider's API is called during CI review. |
| **Accepted values** | `anthropic` \| `openai` |
| **Default** | `anthropic` |
| **Example** | `model.provider=anthropic` or `model.provider=openai` |
| **Used by** | `python3 -m dso_ci_review.runner` (via `CI_REVIEW_PROVIDER` env var) | # shim-exempt: internal implementation reference in config documentation

---

### `model.light`

| | |
|---|---|
| **Description** | Model ID used for light-tier CI review (when `dso_ci_review.runner` is invoked with `tier=light`). |
| **Accepted values** | Provider model ID string |
| **Default** | `claude-haiku-4-5-20251001` (Anthropic) / `gpt-5.4-nano` (OpenAI) |
| **Used by** | `python3 -m dso_ci_review.runner` (via `DSO_CI_REVIEW_MODEL` env var) | # shim-exempt: internal implementation reference in config documentation

---

### `model.standard`

| | |
|---|---|
| **Description** | Model ID used for standard-tier CI review (when `dso_ci_review.runner` is invoked with `tier=standard`). |
| **Accepted values** | Provider model ID string |
| **Default** | `claude-sonnet-4-6` (Anthropic) / `gpt-5.4` (OpenAI) |
| **Used by** | `python3 -m dso_ci_review.runner` (via `DSO_CI_REVIEW_MODEL` env var) | # shim-exempt: internal implementation reference in config documentation

---

### `model.deep`

| | |
|---|---|
| **Description** | Model ID used for deep-tier CI review (opus-class) (when `dso_ci_review.runner` is invoked with `tier=deep`). |
| **Accepted values** | Provider model ID string |
| **Default** | `claude-opus-4-7` (Anthropic) / `gpt-5.5` (OpenAI) |
| **Used by** | `python3 -m dso_ci_review.runner` (via `DSO_CI_REVIEW_MODEL` env var) | # shim-exempt: internal implementation reference in config documentation

---

### `ci_review.provider`

| | |
|---|---|
| **Description** | Primary LLM provider for the CI LLM review pipeline. Controls which provider is used when `CI_REVIEW_PROVIDER` env var is not set. Resolution order: `CI_REVIEW_PROVIDER` env var → `ci_review.provider` config key → `model.provider` config key → default `anthropic`. |
| **Accepted values** | `anthropic`, `openai` |
| **Default** | `anthropic` |
| **Used by** | `python3 -m dso_ci_review.runner` (via `dso_ci_review.providers.config.get_provider`) | # shim-exempt: internal implementation reference in config documentation

---

### `ci_review.provider_chain`

| | |
|---|---|
| **Description** | Comma-separated ordered list of provider names for the CI LLM review fallback chain. The first entry is the primary provider; subsequent entries are fallback targets on `RateLimitError`. Each name must be lowercase-canonical (`anthropic`, `openai`). |
| **Accepted values** | Comma-separated provider names. Supported: `anthropic`, `openai` |
| **Default** | `anthropic,openai` |
| **Used by** | `python3 -m dso_ci_review.runner` (via `dso_ci_review.providers.config.parse_provider_chain`) | # shim-exempt: internal implementation reference in config documentation

---

### `DSO_LLM_MODEL` *(removed — ignored since Phase 2 provider abstraction)*

`DSO_LLM_MODEL` was an early environment variable used to override the CI review model ID.
It is now **silently ignored** — setting it has no effect on which model is used.

**Migration**: Use `model.light`, `model.standard`, or `model.deep` in `.claude/dso-config.conf`
to control per-tier model IDs. See [`model.light`](#modellight), [`model.standard`](#modelstandard),
and [`model.deep`](#modeldeep) above.

---

### `sprint.max_replan_cycles`

| | |
|---|---|
| **Description** | Maximum number of brainstorm→preplanning→implementation-plan cascade iterations `/dso:sprint` allows before presenting the last available plan to the user and stopping. One cycle = one full brainstorm → preplanning → implementation-plan pass. When the cap is reached the user must make a decision — the purpose is to prevent unbounded planning loops. |
| **Accepted values** | Positive integer |
| **Default** | `2` |
| **Used by** | `/dso:sprint` (cascade replan protocol), `/dso:preplanning` (escalation guard) |

---

### `suggestion.error_threshold`

| | |
|---|---|
| **Description** | Total error count (summed across all categories in `tool-error-counter.json`) that triggers a mechanical-friction suggestion at session end. When the total error count reaches or exceeds this value, the stop-hook calls `suggestion-record.sh` to record a friction observation. A typical healthy session sees 2–5 transient errors; set to a high value (e.g. `9999`) to effectively disable. |
| **Accepted values** | Positive integer |
| **Default** | `10` |
| **Used by** | `hooks/lib/session-misc-functions.sh` (stop-hook suggestion sweep) |

---

### `suggestion.timeout_threshold`

| | |
|---|---|
| **Description** | Count of timeout-category errors alone that triggers a mechanical-friction suggestion at session end. Timeouts are high-signal friction indicators. Checked independently from `suggestion.error_threshold` — either threshold reaching its value triggers a suggestion. Set to a high value (e.g. `9999`) to effectively disable. |
| **Accepted values** | Positive integer |
| **Default** | `3` |
| **Used by** | `hooks/lib/session-misc-functions.sh` (stop-hook suggestion sweep) |

---

### `test_gate.centrality_threshold`

| | |
|---|---|
| **Description** | Fan-in score above which `record-test-status.sh` escalates from the per-file associated-test path to the full test suite. When a staged source file's import fan-in exceeds this threshold the full suite runs (with no RED-marker tolerance). Set to a large value (e.g. `999999`) to always use the per-file path with RED tolerance. |
| **Accepted values** | Non-negative integer |
| **Default** | `8` |
| **Used by** | `hooks/record-test-status.sh` (centrality-aware test routing) |

---

### `test_gate.batch_threshold`

| | |
|---|---|
| **Description** | Advisory batch threshold for per-file associated-test runs. When the number of associated tests for a staged file exceeds this value, `record-test-status.sh` emits a NOTE warning that SIGURG interruption is possible and that the run is resumable via `--restart`. Does not block or change the test execution path — informational only. |
| **Accepted values** | Positive integer |
| **Default** | `20` |
| **Used by** | `hooks/record-test-status.sh` (batch advisory warning) |

---

### `test_quality.enabled`

| | |
|---|---|
| **Description** | Enables or disables the pre-commit test quality gate (`pre-commit-test-quality-gate.sh`). When `false`, the hook exits 0 immediately without running any anti-pattern checks. When absent, defaults to `true`. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `hooks/pre-commit-test-quality-gate.sh` |

---

### `test_quality.tool`

| | |
|---|---|
| **Description** | Analysis tool used by the pre-commit test quality gate for anti-pattern detection in staged test files. `bash-grep` uses a zero-dependency grep-based scanner. `semgrep` uses the rules at `${CLAUDE_PLUGIN_ROOT}/hooks/semgrep-rules/test-anti-patterns.yaml` (requires Semgrep to be installed; gate degrades gracefully to disabled if not found). `disabled` skips all checks. |
| **Accepted values** | `bash-grep`, `semgrep`, `disabled` |
| **Default** | `bash-grep` |
| **Used by** | `hooks/pre-commit-test-quality-gate.sh` |

### CI runner exemption — `check-usage.sh`

`ci-llm-review-runner.sh` (shim in S3+; delegates to `python3 -m dso_ci_review.runner`) does not invoke `check-usage.sh`. The usage throttle requires an active Claude Code OAuth session and is not available in headless CI environments. Rate-limit backoff for CI deep-tier parallel curl calls is handled via `curl --retry` / `--retry-delay` flags on each request instead.

---

## attribution

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `attribution.enabled` | boolean | `false` | When `true`, `/dso:commit` appends DSO-Agent, DSO-Skill, DSO-Model, DSO-Task, DSO-Story, DSO-Epic, Jira-Ticket, and DSO-Review-Score trailers to commit messages via `git interpret-trailers`. Requires git ≥ 2.6. |

**Notes:**
- Setting `attribution.enabled=false` after enabling stops future writes to `attribution-contributors.jsonl` but does not purge existing entries; the file can be safely deleted manually.
- Canonical query for attributed commits: `git log --format="%(trailers:key=DSO-Agent,valueonly)" -- <path>` returns agent names per commit.

---

## Section 2 — Environment Variables

These variables are consumed by DSO hooks, scripts, and skills at runtime. They supplement or override `dso-config.conf` values.

---

### `CLAUDE_PLUGIN_ROOT`

| | |
|---|---|
| **Description** | Absolute path to the DSO plugin installation directory. All hook and script path resolution begins here. When set, `read-config.sh` and all hook dispatchers prefer `$CLAUDE_PLUGIN_ROOT/.claude/dso-config.conf` over the git-root config. When not set, scripts self-locate via `$(dirname "$0")`. |
| **Required** | Recommended; auto-set by `claude plugin install`. Manually required for Option B installs if any hook references `$CLAUDE_PLUGIN_ROOT` directly. |
| **Usage context** | All hooks (`hooks/dispatchers/`, `hooks/lib/`, `hooks/auto-format.sh`), all scripts that locate plugin resources, all skills that reference plugin paths. Set in `.claude/settings.json` under `env` block for manual installs. |

---

### `DSO_ROOT`

| | |
|---|---|
| **Description** | Alias for the DSO plugin root path, resolved by the `.claude/scripts/dso` host-project shim. Resolution cascades: (1) `$CLAUDE_PLUGIN_ROOT` if set → use as `DSO_ROOT`; (2) `dso.plugin_root` from `dso-config.conf`; (3) exit with error. Exported by the shim so that hooks and scripts sourcing it in `--lib` mode can use `$DSO_ROOT` to locate plugin resources without depending on `CLAUDE_PLUGIN_ROOT`. |
| **Required** | Not set directly — resolved by the shim |
| **Usage context** | `.claude/scripts/dso` shim in host projects |

---

### `JIRA_URL`

| | |
|---|---|
| **Description** | Base URL of the Jira instance (e.g., `https://myorg.atlassian.net`). Used by `scripts/bridge-outbound.py` when adding remote links to Jira issues. | # shim-exempt: internal implementation reference
| **Required** | Required for `.claude/scripts/dso ticket sync` remote-link features |
| **Usage context** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand, remote link creation) | # shim-exempt: internal implementation references in config documentation

---

### `JIRA_USER`

| | |
|---|---|
| **Description** | Jira username (email address) for API authentication. Used with `JIRA_API_TOKEN` via HTTP Basic Auth. |
| **Required** | Required for `.claude/scripts/dso ticket sync` remote-link features |
| **Usage context** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand) | # shim-exempt: internal implementation references in config documentation

---

### `JIRA_API_TOKEN`

| | |
|---|---|
| **Description** | Jira API token for authentication. Generate at https://id.atlassian.com/manage-profile/security/api-tokens. Used with `JIRA_USER` via HTTP Basic Auth. |
| **Required** | Required for `.claude/scripts/dso ticket sync` remote-link features |
| **Usage context** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand) | # shim-exempt: internal implementation references in config documentation

---

### `JIRA_PROJECT`

| | |
|---|---|
| **Description** | Jira project key (e.g., `DIG`). Takes precedence over `jira.project` in `dso-config.conf`. Required by `.claude/scripts/dso ticket sync` unless `jira.project` is configured. |
| **Required** | Required for `.claude/scripts/dso ticket sync` unless `jira.project` is set in config |
| **Usage context** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync`, `.claude/scripts/dso jira-reset-sync.sh`, `.claude/scripts/dso reset-tickets.sh` | # shim-exempt: internal implementation references in config documentation

---

### `BRIDGE_ENV_ID`

| | |
|---|---|
| **Description** | Required non-empty UUID identifying this repo's bridge environment. Both the outbound and inbound bridges fail-fast on startup when this variable is empty or unset. Also drives BRIDGE_ALERT migration semantics: the first run after `BRIDGE_ENV_ID` transitions from empty emits a one-shot alert. Provision with: `gh variable set BRIDGE_ENV_ID --body "$(python3 -c 'import uuid; print(uuid.uuid4())')"` |
| **Type** | GitHub repo variable (set via `gh variable set`) |
| **Required** | Required — bridges will not start without it |
| **Default** | None |
| **Usage context** | `scripts/bridge/bridge-outbound.py`, `scripts/bridge/bridge-inbound.py` | # shim-exempt: internal implementation references in config documentation

---

### `BRIDGE_USER_MAP`

| | |
|---|---|
| **Description** | Optional JSON object mapping contributor email addresses (case-insensitive) to Jira account IDs for outbound assignee resolution. When `handle_create_event` cannot find the commit author's email in this map, it emits BRIDGE_ALERT and calls `unassign_issue()`. Example: `{"eng@example.com": "5b10ac8d82e05b22cc7d4ef5"}`. |
| **Type** | Environment variable (JSON string) |
| **Required** | Optional — defaults to `{}` (all contributors fall through to BRIDGE_ALERT + unassigned path) |
| **Default** | `{}` |
| **Usage context** | `scripts/bridge/bridge-outbound.py` | # shim-exempt: internal implementation reference in config documentation

---

### `ARTIFACTS_DIR`

| | |
|---|---|
| **Description** | Path to the session-scoped artifacts directory (`/tmp/workflow-plugin-<hash>`). Holds test status files, review state, validation state, telemetry, and diagnostic logs. Resolved by `hooks/lib/deps.sh:get_artifacts_dir()` using a hash of the repo root. Can be overridden by `WORKFLOW_PLUGIN_ARTIFACTS_DIR` for test isolation. |
| **Required** | Set automatically by `get_artifacts_dir()` — do not set manually |
| **Usage context** | `hooks/record-review.sh`, `hooks/pre-commit-review-gate.sh`, `hooks/check-validation-failures.sh`, `.claude/scripts/dso write-reviewer-findings.sh`, `.claude/scripts/dso health-check.sh`, `.claude/scripts/dso write-test-status.sh` |

---

### `WORKFLOW_PLUGIN_ARTIFACTS_DIR`

| | |
|---|---|
| **Description** | Override for the artifacts directory path. When set, `get_artifacts_dir()` returns this value instead of computing the hash-based path. Used in tests for directory isolation. |
| **Required** | Optional — testing/CI override only |
| **Usage context** | `hooks/lib/deps.sh` (`get_artifacts_dir`), `hooks/pre-commit-review-gate.sh` |

---

### `WORKFLOW_CONFIG_FILE`

| | |
|---|---|
| **Description** | Exact path to a `dso-config.conf` file. When set, `.claude/scripts/dso read-config.sh` uses this file instead of auto-discovering via `CLAUDE_PLUGIN_ROOT` or git root. Highest priority in config resolution. Used for test isolation. |
| **Required** | Optional — testing/CI override only |
| **Usage context** | `.claude/scripts/dso read-config.sh` |

---

### `WORKFLOW_CONFIG`

| | |
|---|---|
| **Description** | Alternative path override for `dso-config.conf`. Used by `.claude/scripts/dso check-local-env.sh` and `.claude/scripts/dso agent-batch-lifecycle.sh` for test isolation. Functionally similar to `WORKFLOW_CONFIG_FILE` but consumed by different scripts. |
| **Required** | Optional — testing override only |
| **Usage context** | `.claude/scripts/dso check-local-env.sh`, `.claude/scripts/dso agent-batch-lifecycle.sh` |

---

### `APP_PORT`

| | |
|---|---|
| **Description** | Application port for health checks. Overridden by `infrastructure.app_port` in config if that key is set. |
| **Required** | Optional |
| **Default** | `3000` |
| **Usage context** | `.claude/scripts/dso check-local-env.sh` |

---

### `DB_PORT`

| | |
|---|---|
| **Description** | Database port for health checks. Overridden by `infrastructure.db_port` in config if that key is set. |
| **Required** | Optional |
| **Default** | `5432` |
| **Usage context** | `.claude/scripts/dso check-local-env.sh` |

---

### `DB_CONTAINER`

| | |
|---|---|
| **Description** | Docker container name for the database. Overridden by `infrastructure.db_container` in config if that key is set. |
| **Required** | Optional — DB container check skipped when unset |
| **Usage context** | `.claude/scripts/dso check-local-env.sh` |

---

### `STAGING_URL`

| | |
|---|---|
| **Description** | Base URL of the staging environment. Can also be passed as the first positional argument to `.claude/scripts/dso staging-smoke-test.sh`. When absent, the smoke test exits with an error. |
| **Required** | Required when running `.claude/scripts/dso staging-smoke-test.sh` directly |
| **Usage context** | `.claude/scripts/dso staging-smoke-test.sh` |

---

### `HEALTH_PATH`

| | |
|---|---|
| **Description** | URL path for the staging health endpoint. Used by `.claude/scripts/dso staging-smoke-test.sh`. |
| **Required** | Optional |
| **Default** | `/health` |
| **Usage context** | `.claude/scripts/dso staging-smoke-test.sh` |

---

### `ROUTES`

| | |
|---|---|
| **Description** | Comma-separated URL paths to check against the staging URL. Used by `.claude/scripts/dso staging-smoke-test.sh`. |
| **Required** | Optional |
| **Default** | `/` |
| **Usage context** | `.claude/scripts/dso staging-smoke-test.sh` |

---

### `TICKETS_DIR`

| | |
|---|---|
| **Description** | Path to the ticket files directory. Overrides the `tickets.directory` config value when set. |
| **Required** | Optional — overrides config or default (`.tickets`) |
| **Usage context** | `hooks/check-validation-failures.sh` |

---

### `TICKETS_DIR_OVERRIDE`

| | |
|---|---|
| **Description** | Test-only injection point for the tickets directory path. Used by `hooks/lib/pre-bash-functions.sh` (commit-failure-tracker) to allow test isolation. |
| **Required** | Optional — testing override only |
| **Usage context** | `hooks/lib/pre-bash-functions.sh` |

---

### `LOCKPICK_WORKTREE_DIR`

| | |
|---|---|
| **Description** | Override for the worktree parent directory. When set, `.claude/scripts/dso worktree-create.sh` places new worktrees here instead of the default (`<repo-parent>/<repo-name>-worktrees`). Also superseded by the `--dir=` flag. |
| **Required** | Optional |
| **Usage context** | `.claude/scripts/dso worktree-create.sh` |

---

### `DSO_TICKET_LEGACY`

| | |
|---|---|
| **Description** | Routes ticket CLI operations to legacy per-op `.sh` subprocess scripts instead of the bash-native `ticket-lib-api.sh` sourced library. Set to `1` to enable legacy mode. When unset (the default), the dispatcher uses `ticket-lib-api.sh` for all subcommand calls. Use this flag when debugging a suspected regression in the bash-native path or when rolling back temporarily. Do not use as a permanent workaround — file a bug ticket instead. |
| **Default** | Unset (uses `ticket-lib-api.sh` library path) |
| **Value** | `=1` to enable legacy subprocess mode |
| **Required** | Optional — debugging/rollback only |
| **Usage context** | `.claude/scripts/dso ticket` dispatcher, `ticket-lib-api.sh` (checked inside each library function) |

---

### `TK_SYNC_SKIP_WORKTREE_PUSH`

| | |
|---|---|
| **Description** | When set to `1`, suppresses the worktree push step during `.claude/scripts/dso ticket sync`. Used internally by `.claude/scripts/dso reset-tickets.sh` when doing a bulk sync to prevent duplicate push operations. |
| **Required** | Internal — set and unset by `.claude/scripts/dso reset-tickets.sh` |
| **Usage context** | `scripts/bridge-outbound.py`, `scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand), `.claude/scripts/dso reset-tickets.sh` | # shim-exempt: internal implementation references in config documentation

---

### `JIRA_PROJECT_OVERRIDE`

| | |
|---|---|
| **Description** | Test-only override for the Jira project key. Consumed by `.claude/scripts/dso reset-tickets.sh` before falling back to `dso-config.conf`. |
| **Required** | Optional — testing override only |
| **Usage context** | `.claude/scripts/dso reset-tickets.sh` |

---

### `SEARCH_CMD`

| | |
|---|---|
| **Description** | Override for the ticket search command used by `hooks/lib/pre-bash-functions.sh` (commit-failure-tracker). When set, takes precedence over `issue_tracker.search_cmd` from config. Used in tests. |
| **Required** | Optional — testing override only |
| **Usage context** | `hooks/lib/pre-bash-functions.sh` |

---

### `preconditions.inference_review.rate_rationale`

| | |
|---|---|
| **Description** | Percentage (0–100) of `rationale_only` decisions that trigger an inference challenge during preconditions review. A value of `0` disables inference challenges for rationale-only decisions entirely; `100` challenges every one. No floor is enforced — any integer 0–100 is valid. |
| **Default** | `20` |
| **Value** | Integer 0–100 |
| **Required** | Optional |
| **Usage context** | `${CLAUDE_PLUGIN_ROOT}/hooks/lib/preconditions-validator-lib.sh`, inference-challenge mode of `dso:red-team-reviewer` |

---

### `preconditions.inference_review.rate_high_stakes`

| | |
|---|---|
| **Description** | Percentage (0–100) of `high_stakes` decisions that trigger an inference challenge during preconditions review. High-stakes decisions affect `gate_verdicts` or `workflow_completion_checklist` fields and can silently corrupt workflow state if inferred incorrectly. **Minimum floor is 100** — values below 100 are rejected by `preconditions-validator-lib.sh` at validation time with the error `minimum floor 100`. |
| **Default** | `100` |
| **Value** | Integer 100 only (floor-enforced) |
| **Required** | Optional — when absent, behavior defaults to always challenge high-stakes decisions |
| **Usage context** | `${CLAUDE_PLUGIN_ROOT}/hooks/lib/preconditions-validator-lib.sh`, inference-challenge mode of `dso:red-team-reviewer` |

---

> **Note**: The PRECONDITIONS degradation channel and ack mechanism (`check-unacked-degradations.sh`, `validate-ack-rationale.sh`, `preconditions-ack.sh`, `check-precondition-emit.sh`) introduce no new configuration keys; behavior is configured via `TICKETS_TRACKER_DIR` env var (existing) and `DSO_TICKETS_TRACKER_DIR` env var (existing override pattern).

