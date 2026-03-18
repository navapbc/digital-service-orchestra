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
bash /path/to/digital-service-orchestra/scripts/dso-setup.sh /path/to/your-project
```

This script:
1. Installs the `.claude/scripts/dso` shim into your project (used by hooks and scripts to locate the plugin)
2. Writes `dso.plugin_root=<plugin-path>` to your project's `workflow-config.conf`

The `dso.plugin_root` key tells the shim where the plugin lives when `CLAUDE_PLUGIN_ROOT` is not set as an
environment variable. See [dso.plugin_root in the Configuration Reference](CONFIGURATION-REFERENCE.md#dsoplugin_root).

### Step 3 — Copy example configuration files

Copy the pre-commit config and workflow-config.conf template (skip any that already exist):

```bash
# Pre-commit hook configuration (skip if .pre-commit-config.yaml already exists)
cp $CLAUDE_PLUGIN_ROOT/examples/pre-commit-config.example.yaml .pre-commit-config.yaml

# Workflow config (skip if workflow-config.conf already exists)
cp $CLAUDE_PLUGIN_ROOT/docs/workflow-config.example.conf workflow-config.conf
```

If `CLAUDE_PLUGIN_ROOT` is not set, replace it with the absolute path to the plugin directory.

Edit `workflow-config.conf` to match your project. All keys are optional except `version` — omitted
keys fall back to stack-detected defaults. See [Configuration Reference](CONFIGURATION-REFERENCE.md).

### Step 4 — Install pre-commit hooks

```bash
pre-commit install
pre-commit install --hook-type pre-push
```

This activates both commit-time and push-time hook stages.

### Step 5 — Invoke /dso:init

Open a Claude Code session in your project and run:

```
/dso:init
```

`/dso:init` interactively validates your setup, detects or confirms your project stack,
and reports which commands will be used for `test`, `lint`, `format`, etc. It is the canonical
entry point for completing and verifying onboarding.

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
2. **`dso.plugin_root` in workflow-config.conf** — written automatically by `dso-setup.sh`.
   Used by the `.claude/scripts/dso` shim when `CLAUDE_PLUGIN_ROOT` is not set.

For most setups, `dso-setup.sh` handles this automatically and no manual configuration is needed.

---

## Key Configuration Summary

`workflow-config.conf` is a flat `KEY=VALUE` file at your project root. All keys are optional
except `version`. Below are the most commonly needed keys for initial setup:

| Key | What it does |
|-----|-------------|
| `version` | Config schema version (required, e.g. `1.0.0`) |
| `stack` | Project stack (`python-poetry`, `node-npm`, `rust-cargo`, `golang`, `convention-based`). Auto-detected if absent. |
| `commands.test` | Full test suite command (default: stack-derived) |
| `commands.lint` | Linter command (default: stack-derived) |
| `commands.format` | Auto-formatter command (default: stack-derived) |
| `dso.plugin_root` | Absolute path to DSO plugin. Written by `dso-setup.sh`; rarely set manually. |
| `jira.project` | Jira project key for `tk sync` (e.g. `DIG`) |

For the full key reference including staging, CI, design, infrastructure, and worktree keys,
see **[docs/CONFIGURATION-REFERENCE.md](CONFIGURATION-REFERENCE.md)**.

### Required environment variables for Jira sync

| Variable | Description |
|----------|-------------|
| `JIRA_URL` | Base URL of your Jira instance (e.g. `https://myorg.atlassian.net`) |
| `JIRA_USER` | Jira account email address |
| `JIRA_API_TOKEN` | Jira API token (generate at https://id.atlassian.com/manage-profile/security/api-tokens) |

These are only required when using `tk sync`. For the full environment variable reference, see
**[docs/CONFIGURATION-REFERENCE.md — Section 2](CONFIGURATION-REFERENCE.md#section-2--environment-variables)**.

---

## Optional Dependencies

### acli (Atlassian CLI)

`acli` enables Jira ticket management from the command line as part of `tk sync` remote link
creation workflows. It is not required for core DSO functionality.

Install:
```bash
# macOS
brew install acli

# Linux / WSL
# Download from https://acli.atlassian.com and add to PATH
```

### PyYAML

PyYAML is only required if your project uses the legacy YAML config format
(`workflow-config.yaml`). The recommended format is the flat KEY=VALUE `workflow-config.conf`
which has no Python dependency beyond stdlib.

Install if needed:
```bash
pip install PyYAML
# or
pip3 install PyYAML
```

---

## Optional Agent Plugins

DSO works standalone with `general-purpose` agents for all task categories. Installing optional
Claude Code plugins adds specialized agents that are automatically discovered:

| Plugin | Enhancement |
|--------|-------------|
| **feature-dev** | Code review (`code-reviewer`), architecture exploration (`code-explorer`, `code-architect`) |
| **error-debugging** | Error pattern detection (`error-detective`), structured debugging (`debugger`) |
| **playwright** | Browser automation for visual regression testing and staging verification |

When a plugin is not installed, DSO falls back to `general-purpose` with a category-specific
prompt. No manual configuration is required.

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
any required updates to `workflow-config.conf` or `.claude/settings.json`.

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
`dso.plugin_root` is set in `workflow-config.conf` (written by `dso-setup.sh`), or set
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
git checkout -- scripts/ hooks/
```

**File permissions**: Ensure hook scripts are executable after cloning:

```bash
chmod +x /path/to/digital-service-orchestra/scripts/*
chmod +x /path/to/digital-service-orchestra/hooks/*.sh
```

**PATH**: The WSL `PATH` may not include `/home/<user>/.local/bin` where `pip`-installed tools
(including `pre-commit`) land. Add it to your `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**GNU coreutils**: Available by default on Ubuntu/Debian. If `timeout` is missing:
`sudo apt-get install coreutils`.
