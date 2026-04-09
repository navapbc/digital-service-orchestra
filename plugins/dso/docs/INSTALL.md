# Installation Guide — Digital Service Orchestra

Digital Service Orchestra (DSO) is a Claude Code plugin that provides workflow infrastructure,
skills, and hooks for software development projects.

---

## Prerequisites

- **Claude Code** >= 1.0.0 (the `claude` CLI)
- **bash** >= 4.0 — macOS ships bash 3.2; see [macOS note](#macos) below
- **git**
- **GNU coreutils** — provides `gtimeout` (macOS) / `timeout` (Linux), used by workflow scripts.
  Install on macOS: `brew install coreutils`
- **pre-commit** — required to activate commit hooks.
  Install: `pip install pre-commit` or `brew install pre-commit`
- **python3** — used by hooks for JSON parsing (stdlib only; no extra packages required)

---

## Installation

### Step 1 — Clone the plugin

```bash
git clone https://github.com/navapbc/digital-service-orchestra.git /path/to/digital-service-orchestra
```

> **Note — `claude plugin install` (aspirational):** The `claude plugin install github:navapbc/digital-service-orchestra`
> command is not yet supported. Use the git clone method above.

### Step 2 — Run dso-setup.sh in your host project

From the DSO plugin directory, run the setup script against your host project:

```bash
bash /path/to/digital-service-orchestra/plugins/dso/scripts/dso-setup.sh /path/to/your-project # shim-exempt: bootstrap installer, run before shim exists
```

This script:
1. Installs the `.claude/scripts/dso` shim into your project (used by hooks and scripts to locate the plugin)
2. Writes `dso.plugin_root=<plugin-path>` to your project's `.claude/dso-config.conf`

The `dso.plugin_root` key tells the shim where the plugin lives when `CLAUDE_PLUGIN_ROOT` is not set as an
environment variable. See [dso.plugin_root in the Configuration Reference](CONFIGURATION-REFERENCE.md#dsoplugin_root).

### Step 3 — Customize configuration files

`dso-setup.sh` (Step 2) already copies default `.pre-commit-config.yaml` and `.github/workflows/ci.yml`
into your project if they don't exist. This step is about reviewing and customizing them.

If you ran a manual install (without `dso-setup.sh`), copy the defaults first:

```bash
# Pre-commit hook configuration (if not already present)
cp "$CLAUDE_PLUGIN_ROOT/examples/pre-commit-config.example.yaml" .pre-commit-config.yaml

# CI workflow (if not already present)
mkdir -p .github/workflows
cp "$CLAUDE_PLUGIN_ROOT/examples/ci.example.yml" .github/workflows/ci.yml
```

Edit `.claude/dso-config.conf` to match your project. All keys are optional except `version` — omitted
keys fall back to stack-detected defaults. See [Configuration Reference](CONFIGURATION-REFERENCE.md).

### Step 4 — Install pre-commit hooks

```bash
pre-commit install
pre-commit install --hook-type pre-push
```

This activates both commit-time and push-time hook stages.

### Step 5 — Run /dso:onboarding

Open a Claude Code session in your project and run:

```
/dso:onboarding
```

`/dso:onboarding` is the primary onboarding entry point. It runs `dso-setup.sh` to install
the DSO shim, detects your project stack, walks through an interactive configuration wizard
(one question at a time) to generate `.claude/dso-config.conf`, and offers to copy starter
templates (`CLAUDE.md`, `KNOWN-ISSUES.md`). It supports a `--dryrun` flag to preview all
changes before applying them.

> **Note**: `/dso:init` is also available as a lighter alternative that validates your setup and
> reports detected commands without generating `.claude/dso-config.conf` interactively.

### Step 6 — (Optional) Run /dso:architect-foundation

After onboarding, you can scaffold enforcement infrastructure for your project:

```
/dso:architect-foundation
```

`/dso:architect-foundation` reads `.claude/project-understanding.md` (written by `/dso:onboarding`
in Step 5), uses Socratic dialogue to uncover enforcement preferences and anti-pattern risks, then
generates targeted scaffolding (pre-commit hooks, CI configuration, test infrastructure). It presents
recommendations one-at-a-time and shows diffs before overwriting existing files. Supports
`/dso:dryrun /dso:architect-foundation` to preview without changes.

> **Note**: This step is optional. It is most useful for new projects that need enforcement
> scaffolding (linting, formatting, test gates) set up from scratch.

---

## Path Resolution

DSO hooks and scripts locate plugin resources via two mechanisms, in order:

1. **`CLAUDE_PLUGIN_ROOT` environment variable** — highest priority. Set this in your
   `.claude/settings.json` `env` block if needed:
   ```json
   {
     "env": {
       "CLAUDE_PLUGIN_ROOT": "/absolute/path/to/digital-service-orchestra"
     }
   }
   ```
2. **`dso.plugin_root` in dso-config.conf** — written automatically by `dso-setup.sh`.
   Used by the `.claude/scripts/dso` shim when `CLAUDE_PLUGIN_ROOT` is not set.

For most setups, `dso-setup.sh` handles this automatically and no manual configuration is needed.

---

## Key Configuration Summary

`dso-config.conf` is a flat `KEY=VALUE` file at `.claude/dso-config.conf` in your project root. All keys are optional
except `version`. Below are the most commonly needed keys for initial setup:

| Key | Default | What it does |
|-----|---------|-------------|
| `version` | required | Config schema version (required, e.g. `1.0.0`) |
| `stack` | auto-detected | Project stack (`python-poetry`, `node-npm`, `rust-cargo`, `golang`, `convention-based`). Auto-detected if absent. |
| `commands.test` | stack-derived | Full test suite command |
| `commands.lint` | stack-derived | Linter command |
| `commands.format` | stack-derived | Auto-formatter command |
| `dso.plugin_root` | set by `dso-setup.sh` | Absolute path to DSO plugin. Written by `dso-setup.sh`; rarely set manually. |
| `ci.workflow_name` | absent | GitHub Actions workflow name for post-push CI trigger recovery (e.g. `CI`). Preferred over deprecated `merge.ci_workflow_name`. |
| `jira.project` | absent | Jira project key for `.claude/scripts/dso ticket sync` (e.g. `DIG`) |
| `monitoring.tool_errors` | absent (disabled) | Set to `true` to enable tool error tracking and auto-ticket creation |
| `model.haiku` | absent | Canonical model ID for the haiku tier (e.g. `claude-haiku-4-5-20251001`). Read by `resolve-model-id.sh`. |
| `model.sonnet` | absent | Canonical model ID for the sonnet tier (e.g. `claude-sonnet-4-6-20260320`). Read by `resolve-model-id.sh`. |
| `model.opus` | absent | Canonical model ID for the opus tier (e.g. `claude-opus-4-6`). Read by `resolve-model-id.sh`. |

### Updating model IDs

When Anthropic releases a new Claude model version, update all references in one step:

1. Edit `.claude/dso-config.conf` — set `model.haiku`, `model.sonnet`, and `model.opus` to the new model IDs
2. Verify with `.claude/scripts/dso check-model-id-lint.sh` — confirms no stale hardcoded model IDs remain

API-calling scripts (`enrich-file-impact.sh`, `semantic-conflict-check.py`) read model IDs at runtime via `resolve-model-id.sh` — no manual edits needed beyond the config file.

For the full key reference including staging, CI, design, infrastructure, and worktree keys,
see **[docs/CONFIGURATION-REFERENCE.md](CONFIGURATION-REFERENCE.md)**.

### Required environment variables for Jira sync

| Variable | Description |
|----------|-------------|
| `JIRA_URL` | Base URL of your Jira instance (e.g. `https://myorg.atlassian.net`) |
| `JIRA_USER` | Jira account email address |
| `JIRA_API_TOKEN` | Jira API token (generate at https://id.atlassian.com/manage-profile/security/api-tokens) |

These are only required when using `.claude/scripts/dso ticket sync`. For the full environment variable reference, see
**[docs/CONFIGURATION-REFERENCE.md — Section 2](CONFIGURATION-REFERENCE.md#section-2--environment-variables)**.

---

## Optional Dependencies

### acli (Atlassian CLI)

`acli` enables Jira ticket management from the command line as part of `.claude/scripts/dso ticket sync` remote link
creation workflows. It is not required for core DSO functionality.

Install:
```bash
# macOS
brew install acli

# Linux / WSL
# Download from https://acli.atlassian.com and add to PATH
```

### PyYAML

PyYAML is only required if your project uses the legacy YAML config format (`workflow-config.yaml`);
the recommended `dso-config.conf` format (flat KEY=VALUE) has no Python dependency beyond stdlib.

Install if needed:
```bash
pip install PyYAML
# or
pip3 install PyYAML
```

---

## Optional Plugins — Agent Enhancements

DSO works standalone with `general-purpose` agents for all task categories. Installing optional
Claude Code plugins adds specialized agents that are automatically discovered:

| Plugin | Enhancement |
|--------|-------------|
| **feature-dev** | Code review (`code-reviewer`), architecture exploration (`code-explorer`, `code-architect`) |
| **error-debugging** | Error pattern detection (`error-detective`), structured debugging (`debugger`); enhances INTERMEDIATE investigation in `/dso:fix-bug` |
| **playwright** | Browser automation for visual regression testing and staging verification via `@playwright/cli` (`npm install --save-dev @playwright/cli`) |

When a plugin is not installed, DSO falls back to `general-purpose` with a category-specific
prompt. No manual configuration is required.

---

## .claude/scripts/dso ticket sync Prerequisites

`.claude/scripts/dso ticket sync` syncs the tickets branch with a shared remote using a split-phase protocol
(fetch → lock → merge → unlock → push). It requires the following setup before first use:

| Requirement | How to satisfy |
|---|---|
| `.tickets-tracker/` initialized | Run `.claude/scripts/dso ticket init` from the repo root (see `plugins/dso/scripts/ticket-init.sh`) | # shim-exempt: internal implementation path in parenthetical reference
| `origin` remote configured | `git -C .tickets-tracker remote add origin <url>` |
| `tickets` branch exists in remote | `git -C .tickets-tracker push origin tickets:tickets` (on first environment only) |

If `.tickets-tracker/` has not been initialized, `.claude/scripts/dso ticket sync` exits with:
```
error: ticket tracker not initialized (.tickets-tracker/ not found)
```

If `origin` is not configured, it exits with:
```
error: origin remote not configured in <tracker_dir>
```

See [contracts/ticket-sync-events-contract.md](contracts/ticket-sync-events-contract.md) for
the full protocol specification including phase timeouts, lock scope, and retry behavior.

---

## Git Hooks and CI

After running `pre-commit install` (Step 4), the plugin's hooks are active. The example
configurations in `examples/` are starting points — customize to match your project:

- **Pre-commit hooks**: `examples/pre-commit-config.example.yaml`
- **GitHub Actions CI**: `examples/ci.example.yml` → copy to `.github/workflows/ci.yml`

See `docs/PRE-COMMIT-TIMEOUT-WRAPPER.md` for the timeout wrapper interface.

---

## Upgrade

```bash
cd /path/to/digital-service-orchestra
git pull
```

No configuration migration is required for patch or minor version bumps
(e.g., `0.1.0` → `0.1.1` or `0.2.0`).

For major version bumps (e.g., `0.x` → `1.0`), check `CHANGELOG.md` for breaking changes and
any required updates to `.claude/dso-config.conf` or `.claude/settings.json`.

---

## Troubleshooting

### macOS

**bash version too old**: macOS ships bash 3.2 at `/bin/bash`. DSO requires bash >= 4.0.

```bash
brew install bash
# Verify: bash --version
```

The DSO scripts use `#!/bin/sh` where possible and `#!/usr/bin/env bash` with bash 4+ features
only where required. If you see `syntax error near unexpected token` in a hook, confirm your
`PATH` places the Homebrew bash first.

**GNU coreutils not installed**: Scripts that use `gtimeout` will fail silently or with
`command not found`.

```bash
brew install coreutils
# Adds gtimeout, gstat, gdate etc. to /usr/local/bin or /opt/homebrew/bin
```

**pre-commit not found**: If `pre-commit install` fails with "command not found":

```bash
brew install pre-commit
# or: pip3 install pre-commit
```

**CLAUDE_PLUGIN_ROOT not set**: If hooks report "cannot find plugin resources", confirm
`dso.plugin_root` is set in `.claude/dso-config.conf` (written by `dso-setup.sh`), or set
`CLAUDE_PLUGIN_ROOT` explicitly in `.claude/settings.json`.

### Linux

**timeout command**: Linux ships with GNU `timeout` from coreutils (no extra install needed).
If missing: `sudo apt-get install coreutils` (Debian/Ubuntu) or `sudo yum install coreutils`.

**bash version**: Most modern Linux distributions ship bash >= 4.0. Verify with `bash --version`.

**python3**: Required for hook JSON parsing. Install with your package manager if absent:
`sudo apt-get install python3` or `sudo yum install python3`.

### WSL / Ubuntu

**Line endings**: If scripts were checked out with Windows line endings (`\r\n`), hooks will fail
with `bad interpreter: No such file or directory`. Fix:

```bash
cd /path/to/digital-service-orchestra
git config core.autocrlf false
git checkout -- plugins/dso/scripts/ plugins/dso/hooks/ # shim-exempt: git reset command for file recovery, not a script invocation
```

**File permissions**: Ensure hook scripts are executable after cloning:

```bash
chmod +x /path/to/digital-service-orchestra/plugins/dso/scripts/* # shim-exempt: bootstrap file permission fix, run before shim is installed
chmod +x /path/to/digital-service-orchestra/plugins/dso/hooks/*.sh
```

**PATH**: The WSL `PATH` may not include `/home/<user>/.local/bin` where `pip`-installed tools
(including `pre-commit`) land. Add it to your `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**GNU coreutils**: Available by default on Ubuntu/Debian. If `timeout` is missing:
`sudo apt-get install coreutils`.
