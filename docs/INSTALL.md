# Installation Guide — Digital Service Orchestra

Digital Service Orchestra is a Claude Code plugin that provides workflow infrastructure
skills and hooks for software development projects.

---

## Prerequisites

- **Claude Code** >= 1.0.0 (the `claude` CLI)
- **bash** >= 4.0
- **GNU coreutils** — provides `gtimeout` (macOS) / `timeout` (Linux), used by
  workflow scripts for command timeouts. Install on macOS: `brew install coreutils`
- **python3** with PyYAML installed — only required if using the legacy YAML
  config format. The recommended `workflow-config.conf` format (flat KEY=VALUE)
  requires no Python dependency.

---

## Installation

### Option A — Git-based (recommended)

```bash
claude plugin install github:navapbc/digital-service-orchestra
```

This clones the plugin into Claude Code's plugin directory and registers it
automatically.

### Option B — Manual

```bash
git clone https://github.com/navapbc/digital-service-orchestra.git /path/to/digital-service-orchestra
```

Then register the plugin in your project's `.claude/settings.json` (see
Required Configuration below).

---

## Path Resolution

Hooks in this plugin use `${CLAUDE_PLUGIN_ROOT}` to locate bundled scripts.

**`claude plugin install` (Option A):** Claude Code sets `CLAUDE_PLUGIN_ROOT`
automatically to the plugin's installation directory. No configuration needed.

**Manual git clone (Option B):** `run-hook.sh` self-locates via
`$(dirname "$0")` when `CLAUDE_PLUGIN_ROOT` is unset, so no manual
configuration is needed in most cases. If any hook script references
`$CLAUDE_PLUGIN_ROOT` directly (outside of `run-hook.sh`), add an `env` block
to your `.claude/settings.json`:

```json
{
  "env": {
    "CLAUDE_PLUGIN_ROOT": "/absolute/path/to/digital-service-orchestra"
  }
}
```

---

## Optional: workflow-config.conf

The plugin auto-detects common project stacks (Python/Poetry, Node/npm,
Rust/Cargo, Go) without any configuration. For custom commands or explicit
stack overrides, create a `workflow-config.conf` at your project root:

```bash
cp /path/to/digital-service-orchestra/docs/workflow-config.example.conf workflow-config.conf
```

Edit the file to match your project's commands. All keys are optional —
omitted keys fall back to stack-detected defaults. The format is flat
KEY=VALUE with dot-notation for nesting (no Python dependency required).

Schema reference: `docs/workflow-config-schema.json`

Supported stack values: `python-poetry`, `node-npm`, `rust-cargo`, `golang`,
`convention-based`

Auto-detection markers:
- `pyproject.toml` → `python-poetry`
- `package.json` → `node-npm`
- `Cargo.toml` → `rust-cargo`
- `go.mod` → `golang`
- `Makefile` (fallback) → `convention-based`

---

## Verify Installation

After setting `CLAUDE_PLUGIN_ROOT`, run the `/dso:init` skill inside a Claude Code
session:

```
/dso:init
```

The `/dso:init` skill validates your setup by:
1. Confirming `CLAUDE_PLUGIN_ROOT` is set and points to a valid plugin directory
2. Detecting or reading the project stack
3. Reporting which commands will be used for `test`, `lint`, `format`, etc.

Expected output: a summary table of detected commands and a confirmation that
hooks are registered. If `CLAUDE_PLUGIN_ROOT` is not set or points to the
wrong location, `/dso:init` will report an error with remediation steps.

---

## validate-work Configuration

The `/dso:validate-work` skill runs comprehensive project health checks across five
domains: local validation, CI status, issue health, staging deployment, and
staging environment tests.

### Staging Keys

All staging configuration lives under the `staging.*` keys in
`workflow-config.conf`. All keys are optional — when `staging.url` is absent,
all staging sub-agents are skipped with the message "SKIPPED (staging not
configured)".

| Key | Type | Description |
|-----|------|-------------|
| `url` | string | Base URL of the staging environment (e.g. `https://staging.example.com`). Required for any staging checks to run. |
| `deploy_check` | string | Path to a deploy-check file (see dispatch rules below). |
| `test` | string | Path to a smoke/acceptance test file (see dispatch rules below). |
| `routes` | string | Comma-separated URL paths to health-check (e.g. `/,/upload,/health`). Default: `/`. |
| `health_path` | string | URL path for the primary health endpoint. Default: `/health`. |

Example configuration:

```conf
staging.url=https://my-app-env-stage.us-east-2.elasticbeanstalk.com
staging.deploy_check=scripts/check-staging-deploy.sh
staging.test=scripts/smoke-test-staging.sh
staging.routes=/,/upload,/history
staging.health_path=/health
```

### .sh vs .md Dispatch Mechanism

The `deploy_check` and `test` keys each accept either a shell script (`.sh`)
or a Markdown prompt file (`.md`). The file extension determines how
validate-work uses the file:

- **`.sh` — shell script**: Executed directly. Exit codes are interpreted as:
  - `0` = healthy / all tests passed
  - `1` = unhealthy / one or more tests failed
  - `2` (deploy_check only) = deployment still in progress; staging sub-agent
    retries up to 10 times (5-minute window) before reporting NOT_READY

- **`.md` — sub-agent prompt**: Read as a prompt file for the staging
  sub-agent. Use this when the check requires judgment, browser interaction,
  or multi-step logic beyond a simple shell script.

Examples:

```conf
# Shell script dispatch
staging.deploy_check=scripts/check-staging-deploy.sh
staging.test=scripts/smoke-test-staging.sh

# Sub-agent prompt dispatch
staging.deploy_check=docs/staging-deploy-check.md
staging.test=docs/staging-test-prompt.md
```

When a key is absent, validate-work uses a built-in fallback:
- **`deploy_check` absent**: falls back to a generic HTTP health check using
  `curl` against `staging.url` + `staging.health_path`
- **`test` absent**: falls back to a tiered validation sequence (deterministic
  pre-checks → API-driven checks → Playwright) using the generic
  `staging-environment-test.md` prompt template

### Graceful Degradation

validate-work degrades gracefully when staging configuration is absent or
incomplete:

- **`staging.url` absent**: Both staging sub-agents (deploy check and staging
  test) are skipped entirely. The final report marks them as
  `SKIPPED (staging not configured)`. This is the expected state for projects
  that do not have a deployed staging environment.

- **`staging.deploy_check` absent**: Sub-Agent 4 uses the built-in generic
  HTTP health check against `staging.url` + `staging.health_path`. No custom
  deploy script is required.

- **`staging.test` absent**: Sub-Agent 5 runs the built-in generic tiered
  validation (HTTP checks, page load, basic interaction). No custom test
  script is required.

- **Non-deployment changes**: If `staging.relevance_script` is configured and
  classifies the current change as non-deployment (exit 1), staging sub-agents
  are skipped automatically with the message
  `SKIPPED (non-deployment changes only)`.

### ci.integration_workflow (Optional)

When your project runs integration tests in a separate GitHub Actions workflow,
set `ci.integration_workflow` to the workflow name:

```conf
ci.integration_workflow=Integration Tests
```

When set, validate-work's CI sub-agent polls the integration workflow
separately from the main CI workflow. When absent, integration workflow status
checks are skipped.

---

## Optional Plugins

Digital Service Orchestra works standalone with `general-purpose` agents for all task
categories. Installing optional Claude Code plugins adds specialized agents that
are automatically discovered via `discover-agents.sh` and preferred when
available:

| Plugin | Enhancement |
|--------|-------------|
| **feature-dev** | Specialized code review (`code-reviewer`), architecture exploration (`code-explorer`, `code-architect`) |
| **error-debugging** | Error pattern detection (`error-detective`), structured debugging (`debugger`) |
| **playwright** | Browser automation for visual regression testing and staging verification |

When a plugin is not installed, `discover-agents.sh` falls back to
`general-purpose` with a category-specific prompt from
`prompts/fallback/<category>.md`. No manual configuration is required — the
routing system in `agent-routing.conf` handles resolution automatically.

To install an optional plugin:

```bash
claude plugin install github:<org>/<plugin-name>
```

---

## Upgrade

```bash
cd /path/to/digital-service-orchestra
git pull
```

No configuration migration is required for patch or minor version bumps
(e.g., `0.1.0` → `0.1.1` or `0.2.0`).

For major version bumps (e.g., `0.x` → `1.0`), check `CHANGELOG.md` in the
plugin repository for breaking changes and any required updates to
`workflow-config.conf` or `.claude/settings.json`.
