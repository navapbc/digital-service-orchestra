# Configuration Reference

This document is the authoritative reference for all `workflow-config.conf` keys and
environment variables consumed by DSO hooks, scripts, and skills.

---

## Table of Contents

- [Section 1 — workflow-config.conf Keys](#section-1--workflow-configconf-keys)
- [Section 2 — Environment Variables](#section-2--environment-variables)

---

## Section 1 — workflow-config.conf Keys

`workflow-config.conf` is an optional flat `KEY=VALUE` file placed at the project root
(or at `$CLAUDE_PLUGIN_ROOT/workflow-config.conf`). Keys use dot-notation for grouping.
List values use repeated keys (one value per line). Parsed by `scripts/read-config.sh`
using `grep`/`cut` — no Python dependency required.

**Config resolution order** (handled by `scripts/read-config.sh`):
1. `WORKFLOW_CONFIG_FILE` env var if set (exact path — highest priority, for test isolation)
2. `$CLAUDE_PLUGIN_ROOT/workflow-config.conf` if `CLAUDE_PLUGIN_ROOT` is set
3. `$(git rev-parse --show-toplevel)/workflow-config.conf` (project root — most common)

Schema: `docs/workflow-config-schema.json`

---

### `version`

| | |
|---|---|
| **Description** | Config schema version (semver). Must be present. Increment minor when adding new keys. |
| **Accepted values** | `<major>.<minor>.<patch>` (e.g., `1.0.0`) |
| **Default** | No default — **required** |
| **Used by** | `scripts/validate-config.sh` |

---

### `stack`

| | |
|---|---|
| **Description** | Explicitly declares the project stack. When absent, `scripts/detect-stack.sh` auto-detects from marker files: `pyproject.toml` → `python-poetry`; `package.json` → `node-npm`; `Cargo.toml` → `rust-cargo`; `go.mod` → `golang`; `Makefile` → `convention-based`. |
| **Accepted values** | `python-poetry`, `node-npm`, `rust-cargo`, `golang`, `convention-based` |
| **Default** | Auto-detected |
| **Used by** | `scripts/detect-stack.sh`, all skills that resolve commands |

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
| **Description** | Display name of the fast-gate CI job. Checked first on any failure for early exit. Must match the `name:` field in your CI workflow file exactly. |
| **Accepted values** | String matching the CI job name |
| **Default** | `Fast Gate` |
| **Used by** | `scripts/ci-status.sh` |

---

### `ci.fast_fail_job`

| | |
|---|---|
| **Description** | Display name of the job whose `timeout-minutes` defines the end of the fast-fail polling phase. Must match the `name:` field in your CI workflow file exactly. |
| **Accepted values** | String matching the CI job name |
| **Default** | Same as `ci.fast_gate_job` |
| **Used by** | `scripts/ci-status.sh` |

---

### `ci.test_ceil_job`

| | |
|---|---|
| **Description** | Display name of the job whose `timeout-minutes` defines the end of the test polling phase. Must match the `name:` field in your CI workflow file exactly. |
| **Accepted values** | String matching the CI job name |
| **Default** | `Unit Tests` |
| **Used by** | `scripts/ci-status.sh` |

---

### `ci.integration_workflow`

| | |
|---|---|
| **Description** | GitHub Actions workflow name for integration test status checks. Used to poll the integration workflow separately from the main CI workflow. When absent, integration workflow status checks are skipped. |
| **Accepted values** | Exact workflow name string (e.g., `Integration Tests`) |
| **Default** | Absent — integration checks skipped |
| **Used by** | `scripts/ci-status.sh`, validate-work skill |

---

### `commands.test`

| | |
|---|---|
| **Description** | Full test suite command. |
| **Accepted values** | Any shell command string (e.g., `make test`, `npm test`) |
| **Default** | Stack-derived (e.g., `poetry run pytest` for `python-poetry`) |
| **Used by** | Skills: `/dso:sprint`, `/dso:tdd-workflow`, `/dso:debug-everything` |

---

### `commands.lint`

| | |
|---|---|
| **Description** | Linter command. |
| **Accepted values** | Any shell command string (e.g., `make lint`, `npm run lint`) |
| **Default** | Stack-derived |
| **Used by** | Skills: `/dso:sprint`, `/dso:tdd-workflow`, validate-work |

---

### `commands.format`

| | |
|---|---|
| **Description** | Auto-formatter command — modifies files in place. |
| **Accepted values** | Any shell command string (e.g., `make format`, `cargo fmt`) |
| **Default** | Stack-derived |
| **Used by** | `hooks/auto-format.sh`, skills |

---

### `commands.format_check`

| | |
|---|---|
| **Description** | Formatting check command — fails if files need reformatting, does not modify files. |
| **Accepted values** | Any shell command string (e.g., `make format-check`, `cargo fmt --check`) |
| **Default** | Stack-derived |
| **Used by** | `scripts/validate.sh`, pre-commit hooks |

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
| **Used by** | Skills: `/dso:tdd-workflow`, `/dso:debug-everything` |

---

### `commands.test_e2e`

| | |
|---|---|
| **Description** | End-to-end test command. Typically slower, may require external services. |
| **Accepted values** | Any shell command string (e.g., `make test-e2e`, `playwright test`) |
| **Default** | Absent — E2E tests skipped when not set |
| **Used by** | `scripts/validate.sh`, validate-work skill |

---

### `commands.test_visual`

| | |
|---|---|
| **Description** | Visual regression test command. Compares screenshots against baselines. |
| **Accepted values** | Any shell command string |
| **Default** | Absent — visual tests skipped when not set |
| **Used by** | `scripts/validate.sh`, validate-work skill |

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
| **Description** | Project-specific environment check command. Invoked by `scripts/check-local-env.sh` after generic checks. Exit 0 = all checks passed; non-zero = failure. |
| **Accepted values** | Any shell command string (e.g., `make env-check-app`) |
| **Default** | Absent — project-specific checks skipped |
| **Used by** | `scripts/check-local-env.sh` |

---

### `commands.env_check_cmd`

| | |
|---|---|
| **Description** | Full environment check command invoked by `scripts/agent-batch-lifecycle.sh` preflight step. Exit 0 = environment healthy; non-zero = environment issues found. |
| **Accepted values** | Any shell command string (e.g., `bash scripts/check-local-env.sh --quiet`) |
| **Default** | Absent — env check step skipped |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `jira.project`

| | |
|---|---|
| **Description** | Jira project key used by `tk sync`. The `JIRA_PROJECT` environment variable takes precedence over this value. |
| **Accepted values** | Jira project key string (e.g., `DIG`, `MYPROJ`) |
| **Default** | No default — required when using `tk sync` |
| **Used by** | `scripts/tk`, `scripts/jira-reset-sync.sh`, `scripts/reset-tickets.sh` |

---

### `issue_tracker.search_cmd`

| | |
|---|---|
| **Description** | Command to search for existing tickets by substring. Used by `hooks/lib/pre-bash-functions.sh` (commit-failure-tracker) to detect duplicate tickets. |
| **Accepted values** | Any shell command string (e.g., `grep -rl`, `tk search`) |
| **Default** | `grep -rl` |
| **Used by** | `hooks/lib/pre-bash-functions.sh` |

---

### `issue_tracker.create_cmd`

| | |
|---|---|
| **Description** | Command to create a new tracking issue. Used when a validation failure has no existing ticket. |
| **Accepted values** | Any shell command string (e.g., `tk create`, `gh issue create`) |
| **Default** | `tk create` |
| **Used by** | `scripts/check-validation-failures.sh`, `hooks/lib/pre-bash-functions.sh` |

---

### `design.system_name`

| | |
|---|---|
| **Description** | Name and version of the design system used by the project. |
| **Accepted values** | String (e.g., `USWDS 3.x`, `Material UI 5`, `None (custom)`) |
| **Default** | Absent — skill falls back to generic guidance |
| **Used by** | Skills: `/dso:design-onboarding`, `/dso:design-review`, `/dso:design-wireframe` |

---

### `design.component_library`

| | |
|---|---|
| **Description** | Component library identifier used for adapter selection in design skills and component lookup. |
| **Accepted values** | `uswds`, `material`, `bootstrap`, `chakra`, `custom` |
| **Default** | Absent |
| **Used by** | Skills: `/dso:design-wireframe` |

---

### `design.template_engine`

| | |
|---|---|
| **Description** | Template engine used for rendering UI components. Used by design-wireframe for adapter selection. |
| **Accepted values** | `jinja2`, `react`, `vue`, `svelte`, `handlebars` |
| **Default** | Absent |
| **Used by** | Skills: `/dso:design-wireframe` |

---

### `design.design_notes_path`

| | |
|---|---|
| **Description** | Path to the project's North Star design document, relative to repo root. |
| **Accepted values** | Relative file path (e.g., `DESIGN_NOTES.md`, `docs/DESIGN_NOTES.md`) |
| **Default** | `DESIGN_NOTES.md` |
| **Used by** | Skills: `/dso:design-review`, `/dso:design-onboarding` |

---

### `design.manifest_patterns`

| | |
|---|---|
| **Description** | Glob patterns for design manifest files. Used by `scripts/verify-baseline-intent.sh` to locate design manifests for baseline intent checks. Repeatable key. |
| **Accepted values** | Glob pattern strings relative to repo root |
| **Default** | `designs/*/manifest.md`, `designs/*/brief.md` |
| **Used by** | `scripts/verify-baseline-intent.sh` |

---

### `visual.baseline_directory`

| | |
|---|---|
| **Description** | Path to the visual baseline snapshots directory, relative to repo root. Used for baseline intent checks. Note: differs from `merge.visual_baseline_path`, which is used by `merge-to-main.sh`. |
| **Accepted values** | Relative directory path (e.g., `app/tests/e2e/snapshots/`) |
| **Default** | Absent — baseline intent check skipped |
| **Used by** | `scripts/verify-baseline-intent.sh` |

---

### `database.ensure_cmd`

| | |
|---|---|
| **Description** | Command to start the database. Used by `agent-batch-lifecycle.sh` preflight `--start-db`. |
| **Accepted values** | Any shell command string (e.g., `make db-start`, `docker compose up -d db`) |
| **Default** | Absent — DB start step skipped |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `database.status_cmd`

| | |
|---|---|
| **Description** | Command to check database status. Exit 0 = running, non-zero = stopped. |
| **Accepted values** | Any shell command string (e.g., `make db-status`, `pg_isready -h localhost`) |
| **Default** | Absent — DB status check skipped |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `database.port_cmd`

| | |
|---|---|
| **Description** | Command to resolve the database port for the current worktree. Receives worktree name as `$1` and port type as `$2`. Used for port conflict detection. |
| **Accepted values** | Any shell command string (e.g., `echo 5432`) |
| **Default** | Absent |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `database.base_port`

| | |
|---|---|
| **Description** | Base database port number. Worktree-specific ports are derived by adding an offset to this value. |
| **Accepted values** | Integer (e.g., `5432`) |
| **Default** | `5432` |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `worktree.post_create_cmd`

| | |
|---|---|
| **Description** | Command to run after creating a new worktree (relative to repo root). When absent, post-create phase is skipped. |
| **Accepted values** | Any shell command string (e.g., `./scripts/worktree-setup-env.sh`) |
| **Default** | Absent — skipped |
| **Used by** | `scripts/worktree-create.sh` |

---

### `worktree.service_start_cmd`

| | |
|---|---|
| **Description** | Command to run before launching Claude Code (e.g., start background services). Used by `scripts/claude-safe` pre-launch phase. When absent, service startup step is skipped. |
| **Accepted values** | Any shell command string (e.g., `make start`, `docker compose up -d`) |
| **Default** | Absent — skipped |
| **Used by** | `scripts/claude-safe` (pre-launch phase) |

---

### `worktree.python_version`

| | |
|---|---|
| **Description** | Python version for worktree environment setup. Used by `scripts/worktree-setup-env.sh` to find the correct Python binary. When absent, falls back to any `python3` on PATH. |
| **Accepted values** | Version string matching `<major>.<minor>` (e.g., `3.13`, `3.12`) |
| **Default** | Absent — falls back to `python3` |
| **Used by** | `scripts/worktree-setup-env.sh` (when present) |

---

### `infrastructure.container_prefix`

| | |
|---|---|
| **Description** | Docker container name prefix for worktree-specific containers. Used to discover and clean up containers belonging to deleted worktrees. |
| **Accepted values** | String prefix (e.g., `myapp-postgres-worktree-`) |
| **Default** | Absent |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `infrastructure.compose_project`

| | |
|---|---|
| **Description** | Docker Compose project name prefix for worktree-specific stacks. The worktree directory name is appended. |
| **Accepted values** | String prefix (e.g., `myapp-db-`) |
| **Default** | Absent |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `infrastructure.db_container`

| | |
|---|---|
| **Description** | Exact Docker container name for the database. Used by `scripts/check-local-env.sh` for container health checks. When absent, DB container check is skipped. |
| **Accepted values** | Exact container name string (e.g., `myapp-postgres`) |
| **Default** | Absent — container check skipped |
| **Used by** | `scripts/check-local-env.sh` |

---

### `infrastructure.db_container_patterns`

| | |
|---|---|
| **Description** | Partial Docker container name patterns to match when the exact `db_container` name is not found. Checked in order; first match wins. Repeatable key. |
| **Accepted values** | Partial container name strings |
| **Default** | Absent |
| **Used by** | `scripts/check-local-env.sh` |

---

### `infrastructure.required_tools`

| | |
|---|---|
| **Description** | CLI tools that must be present in PATH. `check-local-env.sh` fails if any are missing. Repeatable key. |
| **Accepted values** | Tool names (e.g., `jq`, `git`, `curl`, `docker`) |
| **Default** | `jq`, `git`, `curl` |
| **Used by** | `scripts/check-local-env.sh` |

---

### `infrastructure.optional_tools`

| | |
|---|---|
| **Description** | CLI tools that are helpful but not required. `check-local-env.sh` emits a warning (not a failure) if any are missing. Repeatable key. |
| **Accepted values** | Tool names (e.g., `shasum`, `pg_isready`) |
| **Default** | `shasum` |
| **Used by** | `scripts/check-local-env.sh` |

---

### `infrastructure.db_port`

| | |
|---|---|
| **Description** | Port for the database health check. Overrides the `DB_PORT` environment variable. |
| **Accepted values** | Integer port number (e.g., `5432`) |
| **Default** | `5432` (or `DB_PORT` env var if set) |
| **Used by** | `scripts/check-local-env.sh` |

---

### `infrastructure.app_port`

| | |
|---|---|
| **Description** | Port for the application health check. Overrides the `APP_PORT` environment variable. |
| **Accepted values** | Integer port number (e.g., `3000`) |
| **Default** | `3000` (or `APP_PORT` env var if set) |
| **Used by** | `scripts/check-local-env.sh` |

---

### `infrastructure.health_timeout`

| | |
|---|---|
| **Description** | Timeout in seconds for HTTP health checks. |
| **Accepted values** | Integer number of seconds (e.g., `5`) |
| **Default** | `5` |
| **Used by** | `scripts/check-local-env.sh` |

---

### `infrastructure.app_base_port`

| | |
|---|---|
| **Description** | Base application port number. Worktree-specific ports are derived by adding an offset. |
| **Accepted values** | Integer (e.g., `3000`, `8000`) |
| **Default** | `3000` |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `infrastructure.compose_files`

| | |
|---|---|
| **Description** | Docker Compose files to shut down on session exit. Used by `scripts/claude-safe` post-exit Docker cleanup. When absent or Docker is not on PATH, cleanup is skipped silently. Repeatable key. |
| **Accepted values** | Relative paths to Compose files (e.g., `docker-compose.yml`) |
| **Default** | Absent — cleanup skipped |
| **Used by** | `scripts/claude-safe` (post-exit phase) |

---

### `session.usage_check_cmd`

| | |
|---|---|
| **Description** | Command to check session context window usage. Exit 0 = usage IS high (>90%); non-zero = normal. Used by `agent-batch-lifecycle.sh` pre-check and context-check subcommands. |
| **Accepted values** | Any shell command string (e.g., `$HOME/.claude/check-session-usage.sh`) |
| **Default** | Absent — usage checks skipped |
| **Used by** | `scripts/agent-batch-lifecycle.sh` |

---

### `session.artifact_prefix`

| | |
|---|---|
| **Description** | Prefix for `/tmp` artifact directories (e.g., `myproject-test-artifacts`). When absent, derived from `basename(git repo root) + -test-artifacts`. |
| **Accepted values** | String prefix without spaces |
| **Default** | Derived from repo name |
| **Used by** | `scripts/worktree-create.sh`, `hooks/lib/deps.sh` (`get_artifacts_dir`) |

---

### `checks.script_write_scan_dir`

| | |
|---|---|
| **Description** | Directory to scan for coupling-lint violations. When absent, the script-writes check is skipped entirely. |
| **Accepted values** | Directory path (e.g., `.`) |
| **Default** | Absent — check skipped |
| **Used by** | `scripts/validate.sh` |

---

### `checks.assertion_density_cmd`

| | |
|---|---|
| **Description** | Command to run assertion density analysis on test files. When absent, assertion_coverage is scored null in retro reviews. |
| **Accepted values** | Any shell command string (e.g., `python3 scripts/check_assertion_density.py`) |
| **Default** | Absent — scored null |
| **Used by** | `/dso:sprint` retro review |

---

### `merge.visual_baseline_path`

| | |
|---|---|
| **Description** | Path to visual baseline snapshot directory, relative to repo root. When absent, `merge-to-main.sh` skips the baseline intent check. |
| **Accepted values** | Relative directory path (e.g., `app/tests/e2e/snapshots/`) |
| **Default** | Absent — check skipped |
| **Used by** | `scripts/merge-to-main.sh` |

---

### `merge.ci_workflow_name`

| | |
|---|---|
| **Description** | GitHub Actions workflow name for `gh workflow run`. Used for post-push CI trigger recovery. When absent, this recovery step is skipped. |
| **Accepted values** | Exact workflow name string (e.g., `CI`, `Build and Test`) |
| **Default** | Absent — step skipped |
| **Used by** | `scripts/merge-to-main.sh` |

---

### `merge.message_exclusion_pattern`

| | |
|---|---|
| **Description** | Regex pattern for filtering commits when composing the merge message. Passed to `grep -vE`. |
| **Accepted values** | Extended regex string |
| **Default** | `^chore: post-merge cleanup` |
| **Used by** | `scripts/merge-to-main.sh` |

---

### `staging.url`

| | |
|---|---|
| **Description** | Base URL of the staging environment. When absent, all staging sub-agents are skipped. |
| **Accepted values** | Full URL string (e.g., `https://staging.example.com`) |
| **Default** | Absent — staging checks skipped |
| **Used by** | Validate-work skill, `scripts/staging-smoke-test.sh` |

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
| **Used by** | Validate-work skill, `scripts/staging-smoke-test.sh` |

---

### `staging.health_path`

| | |
|---|---|
| **Description** | URL path for the primary health endpoint on the staging environment. |
| **Accepted values** | URL path string (e.g., `/health`, `/api/health`) |
| **Default** | `/health` |
| **Used by** | Validate-work skill, `scripts/staging-smoke-test.sh` |

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
| **Description** | Ticket ID prefix used when generating new ticket IDs. When absent, `tk` derives the prefix from the project directory name. |
| **Accepted values** | Short string without spaces (e.g., `dso`, `my-project`) |
| **Default** | Derived from repo directory name |
| **Used by** | `scripts/tk` |

---

### `tickets.directory`

| | |
|---|---|
| **Description** | Directory where ticket markdown files are stored, relative to repo root. |
| **Accepted values** | Relative directory path |
| **Default** | `.tickets` |
| **Used by** | `scripts/tk`, `scripts/orphaned-tasks.sh`, `hooks/check-validation-failures.sh` |

---

### `tickets.sync.jira_project_key`

| | |
|---|---|
| **Description** | Jira project key for ticket sync. Only needed when using `tk sync` with Jira. Superseded by `jira.project` — prefer `jira.project` for new configurations. |
| **Accepted values** | Jira project key string (e.g., `DTL`, `MYPROJ`) |
| **Default** | Absent |
| **Used by** | `scripts/tk` (sync subcommand) |

---

### `tickets.sync.bidirectional_comments`

| | |
|---|---|
| **Description** | Enable bidirectional comment sync between local tickets and Jira. When true, comments added locally are pushed to Jira and vice versa. |
| **Accepted values** | `true`, `false` |
| **Default** | `true` |
| **Used by** | `scripts/tk` (sync subcommand) |

---

### `checkpoint.marker_file`

| | |
|---|---|
| **Description** | Filename (not path) of the marker file written after a pre-compaction auto-save commit. Used by `hooks/pre-compact-checkpoint.sh`. |
| **Accepted values** | Filename string (e.g., `.checkpoint-pending-rollback`) |
| **Default** | `.checkpoint-pending-rollback` |
| **Used by** | `hooks/pre-compact-checkpoint.sh` |

---

### `checkpoint.commit_label`

| | |
|---|---|
| **Description** | Git commit message for pre-compaction auto-save commits. |
| **Accepted values** | Commit message string |
| **Default** | `checkpoint: auto-save` |
| **Used by** | `hooks/pre-compact-checkpoint.sh` |

---

### `version.file_path`

| | |
|---|---|
| **Description** | Path to the file that holds this project's semver string, relative to repo root. When absent, `scripts/bump-version.sh` skips version bumping entirely. Supported formats: `.json` → reads/writes the `version` key; `.toml` → reads/writes the `version` field; plaintext/no extension → single semver line (entire file content). |
| **Accepted values** | Relative file path |
| **Default** | Absent — version bumping skipped |
| **Used by** | `scripts/bump-version.sh` |

---

### `dso.plugin_root`

| | |
|---|---|
| **Description** | Absolute path to the DSO plugin root directory. Written automatically by `scripts/dso-setup.sh`. Used by the `.claude/scripts/dso` shim in host projects when `CLAUDE_PLUGIN_ROOT` is not set. |
| **Accepted values** | Absolute directory path |
| **Default** | Set by `dso-setup.sh` |
| **Used by** | `.claude/scripts/dso` shim (host projects) |

---

## Section 2 — Environment Variables

These variables are consumed by DSO hooks, scripts, and skills at runtime. They supplement or override `workflow-config.conf` values.

---

### `CLAUDE_PLUGIN_ROOT`

| | |
|---|---|
| **Description** | Absolute path to the DSO plugin installation directory. All hook and script path resolution begins here. When set, `read-config.sh` and all hook dispatchers prefer `$CLAUDE_PLUGIN_ROOT/workflow-config.conf` over the git-root config. When not set, scripts self-locate via `$(dirname "$0")`. |
| **Required** | Recommended; auto-set by `claude plugin install`. Manually required for Option B installs if any hook references `$CLAUDE_PLUGIN_ROOT` directly. |
| **Usage context** | All hooks (`hooks/dispatchers/`, `hooks/lib/`, `hooks/auto-format.sh`, `hooks/pre-compact-checkpoint.sh`), all scripts that locate plugin resources, all skills that reference plugin paths. Set in `.claude/settings.json` under `env` block for manual installs. |

---

### `DSO_ROOT`

| | |
|---|---|
| **Description** | Alias for the DSO plugin root path, resolved by the `.claude/scripts/dso` host-project shim. Resolution cascades: (1) `$CLAUDE_PLUGIN_ROOT` if set → use as `DSO_ROOT`; (2) `dso.plugin_root` from `workflow-config.conf`; (3) exit with error. Exported by the shim so that hooks and scripts sourcing it in `--lib` mode can use `$DSO_ROOT` to locate plugin resources without depending on `CLAUDE_PLUGIN_ROOT`. |
| **Required** | Not set directly — resolved by the shim |
| **Usage context** | `.claude/scripts/dso` shim in host projects |

---

### `JIRA_URL`

| | |
|---|---|
| **Description** | Base URL of the Jira instance (e.g., `https://myorg.atlassian.net`). Used by `scripts/tk` when adding remote links to Jira issues. |
| **Required** | Required for `tk sync` remote-link features |
| **Usage context** | `scripts/tk` (sync subcommand, remote link creation) |

---

### `JIRA_USER`

| | |
|---|---|
| **Description** | Jira username (email address) for API authentication. Used with `JIRA_API_TOKEN` via HTTP Basic Auth. |
| **Required** | Required for `tk sync` remote-link features |
| **Usage context** | `scripts/tk` (sync subcommand) |

---

### `JIRA_API_TOKEN`

| | |
|---|---|
| **Description** | Jira API token for authentication. Generate at https://id.atlassian.com/manage-profile/security/api-tokens. Used with `JIRA_USER` via HTTP Basic Auth. |
| **Required** | Required for `tk sync` remote-link features |
| **Usage context** | `scripts/tk` (sync subcommand) |

---

### `JIRA_PROJECT`

| | |
|---|---|
| **Description** | Jira project key (e.g., `DIG`). Takes precedence over `jira.project` in `workflow-config.conf`. Required by `tk sync` unless `jira.project` is configured. |
| **Required** | Required for `tk sync` unless `jira.project` is set in config |
| **Usage context** | `scripts/tk`, `scripts/jira-reset-sync.sh`, `scripts/reset-tickets.sh` |

---

### `ARTIFACTS_DIR`

| | |
|---|---|
| **Description** | Path to the session-scoped artifacts directory (`/tmp/workflow-plugin-<hash>`). Holds test status files, review state, validation state, telemetry, and diagnostic logs. Resolved by `hooks/lib/deps.sh:get_artifacts_dir()` using a hash of the repo root. Can be overridden by `WORKFLOW_PLUGIN_ARTIFACTS_DIR` for test isolation. |
| **Required** | Set automatically by `get_artifacts_dir()` — do not set manually |
| **Usage context** | `hooks/record-review.sh`, `hooks/pre-commit-review-gate.sh`, `hooks/check-validation-failures.sh`, `scripts/write-reviewer-findings.sh`, `scripts/health-check.sh`, `scripts/write-test-status.sh` |

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
| **Description** | Exact path to a `workflow-config.conf` file. When set, `scripts/read-config.sh` uses this file instead of auto-discovering via `CLAUDE_PLUGIN_ROOT` or git root. Highest priority in config resolution. Used for test isolation. |
| **Required** | Optional — testing/CI override only |
| **Usage context** | `scripts/read-config.sh` |

---

### `WORKFLOW_CONFIG`

| | |
|---|---|
| **Description** | Alternative path override for `workflow-config.conf`. Used by `scripts/check-local-env.sh` and `scripts/agent-batch-lifecycle.sh` for test isolation. Functionally similar to `WORKFLOW_CONFIG_FILE` but consumed by different scripts. |
| **Required** | Optional — testing override only |
| **Usage context** | `scripts/check-local-env.sh`, `scripts/agent-batch-lifecycle.sh` |

---

### `APP_PORT`

| | |
|---|---|
| **Description** | Application port for health checks. Overridden by `infrastructure.app_port` in config if that key is set. |
| **Required** | Optional |
| **Default** | `3000` |
| **Usage context** | `scripts/check-local-env.sh` |

---

### `DB_PORT`

| | |
|---|---|
| **Description** | Database port for health checks. Overridden by `infrastructure.db_port` in config if that key is set. |
| **Required** | Optional |
| **Default** | `5432` |
| **Usage context** | `scripts/check-local-env.sh` |

---

### `DB_CONTAINER`

| | |
|---|---|
| **Description** | Docker container name for the database. Overridden by `infrastructure.db_container` in config if that key is set. |
| **Required** | Optional — DB container check skipped when unset |
| **Usage context** | `scripts/check-local-env.sh` |

---

### `STAGING_URL`

| | |
|---|---|
| **Description** | Base URL of the staging environment. Can also be passed as the first positional argument to `scripts/staging-smoke-test.sh`. When absent, the smoke test exits with an error. |
| **Required** | Required when running `scripts/staging-smoke-test.sh` directly |
| **Usage context** | `scripts/staging-smoke-test.sh` |

---

### `HEALTH_PATH`

| | |
|---|---|
| **Description** | URL path for the staging health endpoint. Used by `scripts/staging-smoke-test.sh`. |
| **Required** | Optional |
| **Default** | `/health` |
| **Usage context** | `scripts/staging-smoke-test.sh` |

---

### `ROUTES`

| | |
|---|---|
| **Description** | Comma-separated URL paths to check against the staging URL. Used by `scripts/staging-smoke-test.sh`. |
| **Required** | Optional |
| **Default** | `/` |
| **Usage context** | `scripts/staging-smoke-test.sh` |

---

### `TICKETS_DIR`

| | |
|---|---|
| **Description** | Path to the ticket files directory. Overrides the `tickets.directory` config value when set. |
| **Required** | Optional — overrides config or default (`.tickets`) |
| **Usage context** | `hooks/check-validation-failures.sh`, `scripts/orphaned-tasks.sh` |

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
| **Description** | Override for the worktree parent directory. When set, `scripts/worktree-create.sh` places new worktrees here instead of the default (`<repo-parent>/<repo-name>-worktrees`). Also superseded by the `--dir=` flag. |
| **Required** | Optional |
| **Usage context** | `scripts/worktree-create.sh` |

---

### `LOCKPICK_DISABLE_PRECOMPACT`

| | |
|---|---|
| **Description** | When set to any non-empty value, disables the pre-compaction checkpoint hook entirely. Useful in CI environments or when the checkpoint behavior is not desired. |
| **Required** | Optional |
| **Usage context** | `hooks/pre-compact-checkpoint.sh` |

---

### `CLAUDE_SESSION_ID`

| | |
|---|---|
| **Description** | Current Claude Code session identifier. Injected by Claude Code into hook environments. Used by `hooks/pre-compact-checkpoint.sh` for telemetry attribution. |
| **Required** | Set automatically by Claude Code — do not set manually |
| **Usage context** | `hooks/pre-compact-checkpoint.sh` (telemetry) |

---

### `CLAUDE_PARENT_SESSION_ID`

| | |
|---|---|
| **Description** | Parent session identifier when running inside a sub-agent. Injected by Claude Code. Used by `hooks/pre-compact-checkpoint.sh` for telemetry to track parent/child session relationships. |
| **Required** | Set automatically by Claude Code — do not set manually |
| **Usage context** | `hooks/pre-compact-checkpoint.sh` (telemetry) |

---

### `CLAUDE_CONTEXT_WINDOW_TOKENS`

| | |
|---|---|
| **Description** | Current number of tokens used in the context window. Injected by Claude Code into pre-compact hook environments. Used for telemetry. |
| **Required** | Set automatically by Claude Code — do not set manually |
| **Usage context** | `hooks/pre-compact-checkpoint.sh` (telemetry) |

---

### `CLAUDE_CONTEXT_WINDOW_LIMIT`

| | |
|---|---|
| **Description** | Maximum token limit for the current context window. Injected by Claude Code into pre-compact hook environments. Used for telemetry. |
| **Required** | Set automatically by Claude Code — do not set manually |
| **Usage context** | `hooks/pre-compact-checkpoint.sh` (telemetry) |

---

### `TK_SYNC_SKIP_WORKTREE_PUSH`

| | |
|---|---|
| **Description** | When set to `1`, suppresses the worktree push step during `tk sync`. Used internally by `scripts/reset-tickets.sh` when doing a bulk sync to prevent duplicate push operations. |
| **Required** | Internal — set and unset by `scripts/reset-tickets.sh` |
| **Usage context** | `scripts/tk` (sync subcommand), `scripts/reset-tickets.sh` |

---

### `JIRA_PROJECT_OVERRIDE`

| | |
|---|---|
| **Description** | Test-only override for the Jira project key. Consumed by `scripts/reset-tickets.sh` before falling back to `workflow-config.conf`. |
| **Required** | Optional — testing override only |
| **Usage context** | `scripts/reset-tickets.sh` |

---

### `SEARCH_CMD`

| | |
|---|---|
| **Description** | Override for the ticket search command used by `hooks/lib/pre-bash-functions.sh` (commit-failure-tracker). When set, takes precedence over `issue_tracker.search_cmd` from config. Used in tests. |
| **Required** | Optional — testing override only |
| **Usage context** | `hooks/lib/pre-bash-functions.sh` |

---

### `CREATE_CMD`

| | |
|---|---|
| **Description** | Override for the ticket create command used by `hooks/lib/pre-bash-functions.sh` (commit-failure-tracker). When set, takes precedence over `issue_tracker.create_cmd` from config. Used in tests. |
| **Required** | Optional — testing override only |
| **Usage context** | `hooks/lib/pre-bash-functions.sh` |
