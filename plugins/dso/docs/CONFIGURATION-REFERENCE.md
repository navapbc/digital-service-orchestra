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
| **Used by** | `plugins/dso/hooks/lib/config-paths.sh`, `plugins/dso/scripts/validate.sh`, `plugins/dso/scripts/agent-batch-lifecycle.sh`, `plugins/dso/scripts/retro-gather.sh` | # shim-exempt: internal implementation references in config documentation

---

### `paths.src_dir`

| | |
|---|---|
| **Description** | Source code directory, relative to `paths.app_dir`. Used for file impact analysis and auto-format scope. |
| **Accepted values** | Relative directory path (e.g., `src`, `lib`) |
| **Default** | `src` |
| **Used by** | `plugins/dso/hooks/lib/config-paths.sh`, `plugins/dso/scripts/sprint-next-batch.sh` | # shim-exempt: internal implementation references in config documentation

---

### `paths.test_dir`

| | |
|---|---|
| **Description** | Test directory, relative to `paths.app_dir`. Used for test file discovery, snapshot paths, and file impact analysis. |
| **Accepted values** | Relative directory path (e.g., `tests`, `test`) |
| **Default** | `tests` |
| **Used by** | `plugins/dso/hooks/lib/config-paths.sh`, `plugins/dso/scripts/sprint-next-batch.sh` | # shim-exempt: internal implementation references in config documentation

---

### `paths.test_unit_dir`

| | |
|---|---|
| **Description** | Unit test directory, relative to `paths.app_dir`. Used for targeted test discovery when distinguishing unit from integration tests. |
| **Accepted values** | Relative directory path (e.g., `tests/unit`) |
| **Default** | Absent — falls back to `paths.test_dir` |
| **Used by** | `plugins/dso/scripts/sprint-next-batch.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `interpreter.python_venv`

| | |
|---|---|
| **Description** | Path to the Python virtual environment interpreter, relative to the repo root. Used to locate the correct Python binary for running scripts and tests. |
| **Accepted values** | Relative file path (e.g., `app/.venv/bin/python3`, `.venv/bin/python3`) |
| **Default** | `app/.venv/bin/python3` |
| **Used by** | `plugins/dso/hooks/lib/config-paths.sh`, `plugins/dso/scripts/sprint-next-batch.sh` | # shim-exempt: internal implementation references in config documentation

---

### `format.extensions`

| | |
|---|---|
| **Description** | File extensions to process via the auto-format PostToolUse hook. Repeatable key (one extension per line). |
| **Accepted values** | `.py`, `.ts`, `.tsx`, etc. |
| **Default** | `.py` |
| **Used by** | `plugins/dso/hooks/auto-format.sh` |

---

### `format.source_dirs`

| | |
|---|---|
| **Description** | Directories to restrict auto-format processing to, relative to repo root. Repeatable key (one directory per line). |
| **Accepted values** | Relative or absolute directory paths |
| **Default** | `app/src`, `app/tests` |
| **Used by** | `plugins/dso/hooks/auto-format.sh` |

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
| **Description** | GitHub Actions workflow filename for integration test status checks. Used to poll the integration workflow separately from the main CI workflow. When absent, integration workflow status checks are skipped. Distinct from `ci.workflow_name`: `ci.workflow_name` is the primary CI workflow for `merge-to-main.sh` trigger recovery; `ci.integration_workflow` is the integration test workflow polled by `/dso:sprint` Phase 6 and `ci-status.sh`. They may reference the same file or different ones. Written by `/dso:onboarding` Phase 3 Step 2b using a confidence-gated selection: when `project-detect.sh` returns `ci_workflow_confidence=high` with a single detected workflow, the value is written automatically; when confidence is low or multiple workflows are detected, the user is shown a numbered selection dialogue to identify which workflow serves which purpose. |
| **Accepted values** | Exact workflow name string (e.g., `Integration Tests`) |
| **Default** | Absent — integration checks skipped |
| **Used by** | `.claude/scripts/dso ci-status.sh`, validate-work skill, `/dso:onboarding` (Phase 3 config generation) |

---

### `commands.test`

| | |
|---|---|
| **Description** | Full test suite command. |
| **Accepted values** | Any shell command string (e.g., `make test`, `npm test`) |
| **Default** | Stack-derived (e.g., `poetry run pytest` for `python-poetry`) |
| **Used by** | Skills: `/dso:sprint`, `/dso:fix-bug`, `/dso:debug-everything` |

---

### `commands.lint`

| | |
|---|---|
| **Description** | Linter command. |
| **Accepted values** | Any shell command string (e.g., `make lint`, `npm run lint`) |
| **Default** | Stack-derived |
| **Used by** | Skills: `/dso:sprint`, `/dso:fix-bug`, validate-work |

---

### `commands.format`

| | |
|---|---|
| **Description** | Auto-formatter command — modifies files in place. |
| **Accepted values** | Any shell command string (e.g., `make format`, `cargo fmt`) |
| **Default** | Stack-derived |
| **Used by** | `plugins/dso/hooks/auto-format.sh`, skills |

---

### `commands.format_check`

| | |
|---|---|
| **Description** | Formatting check command — fails if files need reformatting, does not modify files. |
| **Accepted values** | Any shell command string (e.g., `make format-check`, `cargo fmt --check`) |
| **Default** | Stack-derived |
| **Used by** | `.claude/scripts/dso validate.sh`, pre-commit hooks |

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
| **Description** | Command to run changed integration/E2E tests before committing. When absent, Step 1.5 of the commit workflow is skipped. |
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

### `jira.project`

| | |
|---|---|
| **Description** | Jira project key used by `.claude/scripts/dso ticket sync`. The `JIRA_PROJECT` environment variable takes precedence over this value. |
| **Accepted values** | Jira project key string (e.g., `DIG`, `MYPROJ`) |
| **Default** | No default — required when using `.claude/scripts/dso ticket sync` |
| **Used by** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync`, `.claude/scripts/dso jira-reset-sync.sh`, `.claude/scripts/dso reset-tickets.sh` | # shim-exempt: internal implementation references in config documentation

---

### `issue_tracker.search_cmd`

| | |
|---|---|
| **Description** | Command to search for existing tickets by substring. Used by `plugins/dso/hooks/lib/pre-bash-functions.sh` (commit-failure-tracker) to detect duplicate tickets. |
| **Accepted values** | Any shell command string (e.g., `grep -rl`, `.claude/scripts/dso ticket list --filter`) |
| **Default** | `grep -rl` |
| **Used by** | `plugins/dso/hooks/lib/pre-bash-functions.sh` |

---

### `design.system_name`

| | |
|---|---|
| **Description** | Name and version of the design system used by the project. |
| **Accepted values** | String (e.g., `USWDS 3.x`, `Material UI 5`, `None (custom)`) |
| **Default** | Absent — skill falls back to generic guidance |
| **Used by** | Skills: `/dso:onboarding`, `/dso:design-review`; Agent: `dso:ui-designer` (dispatched by `/dso:preplanning` Step 6) |

---

### `design.component_library`

| | |
|---|---|
| **Description** | Component library identifier used for adapter selection in design skills and component lookup. |
| **Accepted values** | `uswds`, `material`, `bootstrap`, `chakra`, `custom` |
| **Default** | Absent |
| **Used by** | Agent: `dso:ui-designer` (dispatched by `/dso:preplanning` Step 6) |

---

### `design.template_engine`

| | |
|---|---|
| **Description** | Template engine used for rendering UI components. Used by dso:ui-designer for adapter selection via resolve-stack-adapter.sh. |
| **Accepted values** | `jinja2`, `react`, `vue`, `svelte`, `handlebars` |
| **Default** | Absent |
| **Used by** | Agent: `dso:ui-designer` (dispatched by `/dso:preplanning` Step 6) |

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
| **Used by** | `plugins/dso/scripts/worktree-cleanup.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `worktree.max_age_days`

| | |
|---|---|
| **Description** | Maximum age in days for automatic worktree cleanup. Worktrees older than this threshold are candidates for removal. Overridden by `AGE_DAYS` env var. |
| **Accepted values** | Positive integer |
| **Default** | `2` |
| **Used by** | `plugins/dso/scripts/worktree-cleanup.sh` | # shim-exempt: internal implementation reference in config documentation

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
| **Used by** | `plugins/dso/scripts/worktree-cleanup.sh` | # shim-exempt: internal implementation reference in config documentation

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
| **Used by** | `.claude/scripts/dso worktree-create.sh`, `plugins/dso/hooks/lib/deps.sh` (`get_artifacts_dir`) |

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

### `review.behavioral_patterns`

| | |
|---|---|
| **Description** | Semicolon-delimited glob list of file patterns the review complexity classifier treats as behavioral (full scoring weight). Files matching these patterns receive higher blast_radius and critical_path scores, making them more likely to route to standard or deep review tiers. |
| **Accepted values** | Semicolon-delimited glob patterns (e.g., `plugins/dso/skills/**;plugins/dso/hooks/**`) |
| **Default** | Absent — classifier uses built-in heuristics only |
| **Used by** | `plugins/dso/scripts/review-complexity-classifier.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `debug.max_fix_validate_cycles`

| | |
|---|---|
| **Description** | Maximum number of fix→validate cycles the `/dso:debug-everything` validation loop runs before stopping and reporting remaining open bugs. One cycle = Bug-Fix Mode pass over all open tickets followed by a Validation Mode diagnostic scan. When set to `0`, the validation loop is skipped entirely and execution proceeds directly to Phase 8 after Bug-Fix Mode. Values `> 10` are capped at `10` with a warning. Non-numeric values default to `3` with a warning. |
| **Accepted values** | Non-negative integer (0–10; values above 10 are capped) |
| **Default** | `3` |
| **Used by** | `/dso:debug-everything` (Validation Mode inner loop) |

---

### `debug.intent_search_budget`

| | |
|---|---|
| **Description** | Maximum number of tool calls the intent search sub-agent (Gate 1a) may use when scanning for bug intent signals in open tickets and recent commit history. Controls the bounded search budget for Gate 1a before it must emit a result. Non-numeric values default to `20` with a warning. |
| **Accepted values** | Positive integer |
| **Default** | `20` |
| **Used by** | `/dso:debug-everything` (Gate 1a intent search sub-agent) |

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
| **Used by** | `plugins/dso/scripts/check-persistence-coverage.sh` | # shim-exempt: internal implementation reference in config documentation

---

### `persistence.test_patterns`

| | |
|---|---|
| **Description** | Extended regex patterns (grep -E) for identifying persistence integration test files. Paired with `persistence.source_patterns` to validate coverage. Repeatable key. |
| **Accepted values** | Extended regex patterns (e.g., `tests/integration/.*test_.*_db_roundtrip`) |
| **Default** | Absent — persistence coverage check skipped |
| **Used by** | `plugins/dso/scripts/check-persistence-coverage.sh` | # shim-exempt: internal implementation reference in config documentation

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
| **Used by** | `.claude/scripts/dso ticket` (v3 ticket dispatcher), `plugins/dso/scripts/ticket-reducer.py` | # shim-exempt: internal implementation reference in config documentation

---

### `tickets.directory`

| | |
|---|---|
| **Description** | Directory where ticket markdown files are stored, relative to repo root. |
| **Accepted values** | Relative directory path |
| **Default** | `.tickets` |
| **Used by** | `.claude/scripts/dso ticket` (v3 ticket dispatcher), `plugins/dso/scripts/ticket-reducer.py`, `plugins/dso/hooks/check-validation-failures.sh` | # shim-exempt: internal implementation references in config documentation

---

### `tickets.sync.jira_project_key`

| | |
|---|---|
| **Description** | Jira project key for .claude/scripts/dso ticket sync. Only needed when using `.claude/scripts/dso ticket sync` with Jira. Superseded by `jira.project` — prefer `jira.project` for new configurations. |
| **Accepted values** | Jira project key string (e.g., `DTL`, `MYPROJ`) |
| **Default** | Absent |
| **Used by** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` | # shim-exempt: internal implementation references in config documentation

---

### `tickets.sync.bidirectional_comments`

| | |
|---|---|
| **Description** | Enable bidirectional comment sync between local tickets and Jira. When true, comments added locally are pushed to Jira and vice versa. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` | # shim-exempt: internal implementation references in config documentation

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
| **Used by** | `plugins/dso/hooks/lib/session-misc-functions.sh` (`hook_track_tool_errors`), `plugins/dso/hooks/track-tool-errors.sh`, `plugins/dso/skills/end-session/error-sweep.sh` (`sweep_tool_errors`) |

---

### `dso.plugin_root`

| | |
|---|---|
| **Description** | Absolute path to the DSO plugin root directory. Written automatically by `.claude/scripts/dso dso-setup.sh`. Used by the `.claude/scripts/dso` shim in host projects when `CLAUDE_PLUGIN_ROOT` is not set. |
| **Accepted values** | Absolute directory path |
| **Default** | Set by `dso-setup.sh` |
| **Used by** | `.claude/scripts/dso` shim (host projects) |

---

## Section 2 — Environment Variables

These variables are consumed by DSO hooks, scripts, and skills at runtime. They supplement or override `dso-config.conf` values.

---

### `CLAUDE_PLUGIN_ROOT`

| | |
|---|---|
| **Description** | Absolute path to the DSO plugin installation directory. All hook and script path resolution begins here. When set, `read-config.sh` and all hook dispatchers prefer `$CLAUDE_PLUGIN_ROOT/.claude/dso-config.conf` over the git-root config. When not set, scripts self-locate via `$(dirname "$0")`. |
| **Required** | Recommended; auto-set by `claude plugin install`. Manually required for Option B installs if any hook references `$CLAUDE_PLUGIN_ROOT` directly. |
| **Usage context** | All hooks (`plugins/dso/hooks/dispatchers/`, `plugins/dso/hooks/lib/`, `plugins/dso/hooks/auto-format.sh`), all scripts that locate plugin resources, all skills that reference plugin paths. Set in `.claude/settings.json` under `env` block for manual installs. |

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
| **Description** | Base URL of the Jira instance (e.g., `https://myorg.atlassian.net`). Used by `plugins/dso/scripts/bridge-outbound.py` when adding remote links to Jira issues. | # shim-exempt: internal implementation reference
| **Required** | Required for `.claude/scripts/dso ticket sync` remote-link features |
| **Usage context** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand, remote link creation) | # shim-exempt: internal implementation references in config documentation

---

### `JIRA_USER`

| | |
|---|---|
| **Description** | Jira username (email address) for API authentication. Used with `JIRA_API_TOKEN` via HTTP Basic Auth. |
| **Required** | Required for `.claude/scripts/dso ticket sync` remote-link features |
| **Usage context** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand) | # shim-exempt: internal implementation references in config documentation

---

### `JIRA_API_TOKEN`

| | |
|---|---|
| **Description** | Jira API token for authentication. Generate at https://id.atlassian.com/manage-profile/security/api-tokens. Used with `JIRA_USER` via HTTP Basic Auth. |
| **Required** | Required for `.claude/scripts/dso ticket sync` remote-link features |
| **Usage context** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand) | # shim-exempt: internal implementation references in config documentation

---

### `JIRA_PROJECT`

| | |
|---|---|
| **Description** | Jira project key (e.g., `DIG`). Takes precedence over `jira.project` in `dso-config.conf`. Required by `.claude/scripts/dso ticket sync` unless `jira.project` is configured. |
| **Required** | Required for `.claude/scripts/dso ticket sync` unless `jira.project` is set in config |
| **Usage context** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync`, `.claude/scripts/dso jira-reset-sync.sh`, `.claude/scripts/dso reset-tickets.sh` | # shim-exempt: internal implementation references in config documentation

---

### `ARTIFACTS_DIR`

| | |
|---|---|
| **Description** | Path to the session-scoped artifacts directory (`/tmp/workflow-plugin-<hash>`). Holds test status files, review state, validation state, telemetry, and diagnostic logs. Resolved by `plugins/dso/hooks/lib/deps.sh:get_artifacts_dir()` using a hash of the repo root. Can be overridden by `WORKFLOW_PLUGIN_ARTIFACTS_DIR` for test isolation. |
| **Required** | Set automatically by `get_artifacts_dir()` — do not set manually |
| **Usage context** | `plugins/dso/hooks/record-review.sh`, `plugins/dso/hooks/pre-commit-review-gate.sh`, `plugins/dso/hooks/check-validation-failures.sh`, `.claude/scripts/dso write-reviewer-findings.sh`, `.claude/scripts/dso health-check.sh`, `.claude/scripts/dso write-test-status.sh` |

---

### `WORKFLOW_PLUGIN_ARTIFACTS_DIR`

| | |
|---|---|
| **Description** | Override for the artifacts directory path. When set, `get_artifacts_dir()` returns this value instead of computing the hash-based path. Used in tests for directory isolation. |
| **Required** | Optional — testing/CI override only |
| **Usage context** | `plugins/dso/hooks/lib/deps.sh` (`get_artifacts_dir`), `plugins/dso/hooks/pre-commit-review-gate.sh` |

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
| **Usage context** | `plugins/dso/hooks/check-validation-failures.sh` |

---

### `TICKETS_DIR_OVERRIDE`

| | |
|---|---|
| **Description** | Test-only injection point for the tickets directory path. Used by `plugins/dso/hooks/lib/pre-bash-functions.sh` (commit-failure-tracker) to allow test isolation. |
| **Required** | Optional — testing override only |
| **Usage context** | `plugins/dso/hooks/lib/pre-bash-functions.sh` |

---

### `LOCKPICK_WORKTREE_DIR`

| | |
|---|---|
| **Description** | Override for the worktree parent directory. When set, `.claude/scripts/dso worktree-create.sh` places new worktrees here instead of the default (`<repo-parent>/<repo-name>-worktrees`). Also superseded by the `--dir=` flag. |
| **Required** | Optional |
| **Usage context** | `.claude/scripts/dso worktree-create.sh` |

---

### `TK_SYNC_SKIP_WORKTREE_PUSH`

| | |
|---|---|
| **Description** | When set to `1`, suppresses the worktree push step during `.claude/scripts/dso ticket sync`. Used internally by `.claude/scripts/dso reset-tickets.sh` when doing a bulk sync to prevent duplicate push operations. |
| **Required** | Internal — set and unset by `.claude/scripts/dso reset-tickets.sh` |
| **Usage context** | `plugins/dso/scripts/bridge-outbound.py`, `plugins/dso/scripts/bridge-inbound.py`, `.claude/scripts/dso ticket sync` (sync subcommand), `.claude/scripts/dso reset-tickets.sh` | # shim-exempt: internal implementation references in config documentation

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
| **Description** | Override for the ticket search command used by `plugins/dso/hooks/lib/pre-bash-functions.sh` (commit-failure-tracker). When set, takes precedence over `issue_tracker.search_cmd` from config. Used in tests. |
| **Required** | Optional — testing override only |
| **Usage context** | `plugins/dso/hooks/lib/pre-bash-functions.sh` |

