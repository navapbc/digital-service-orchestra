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
bash /path/to/digital-service-orchestra/${CLAUDE_PLUGIN_ROOT}/scripts/dso-setup.sh /path/to/your-project # shim-exempt: bootstrap installer, run before shim exists
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
| `.tickets-tracker/` initialized | Run `.claude/scripts/dso ticket init` from the repo root (see `scripts/ticket-init.sh`) | # shim-exempt: internal implementation path in parenthetical reference
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

## Artifact Version Stamps

DSO embeds a version stamp in each artifact it installs into your project. These stamps let DSO detect which artifacts are out of date after you upgrade the plugin.

### Stamp format

| Artifact | Format | Example |
|----------|--------|---------|
| `.claude/scripts/dso` (shim) | `# dso-version: <version>` (comment line after shebang) | `# dso-version: 1.2.0` |
| `.claude/dso-config.conf` | `# dso-version: <version>` (comment line) | `# dso-version: 1.2.0` |
| `.pre-commit-config.yaml` | `x-dso-version: <version>` (top-level YAML key) | `x-dso-version: 1.2.0` |
| `.github/workflows/ci.yml` | `x-dso-version: <version>` (top-level YAML key) | `x-dso-version: 1.2.0` |

**Text artifacts** (shell scripts, config files): the stamp is a `# dso-version: <version>` comment.
It is inserted after the first line (shebang) if absent, or updated in-place if already present.

**YAML artifacts** (`.pre-commit-config.yaml`, `ci.yml`): the stamp is an `x-dso-version: <version>` key.
It is prepended as the first line if absent, or updated in-place if already present.

Stamps are idempotent — re-running `dso-setup.sh` on an already-stamped file updates the version
without adding duplicate lines.

### Legacy artifacts

An artifact with no stamp (`# dso-version:` or `x-dso-version:`) was installed before version
stamping was introduced. DSO classifies these as **legacy**. Legacy artifacts receive a one-time
migration notice at session start (see below); after running `dso update-artifacts`, stamps are
added and the notice is cleared.

---

## Session-Start Artifact Notifications

DSO checks artifact version stamps at the start of each Claude Code session via the
`check-artifact-versions.sh` hook. When any installed artifact is stale or legacy, a single
notice is printed to the terminal:

```
DSO artifacts out of date — stale: shim (.claude/scripts/dso) — legacy (no version stamp): pre-commit (.pre-commit-config.yaml). Run: dso update-artifacts
```

### When it fires

- **Stale**: an artifact has a stamp, but it does not match the current plugin version (the plugin
  was upgraded since the artifact was last updated).
- **Legacy**: an artifact exists but has no stamp (installed before stamping was introduced).
  This is a one-time notice — after running `dso update-artifacts`, the stamp is added and the
  notice will no longer appear for that artifact.

### When it is silent

- All artifacts are current (stamps match the plugin version).
- The check ran within the last 24 hours for the same plugin version (cache hit).
- The hook is running inside the DSO plugin source repository itself (not a host project).

### 24-hour cache

After each check, the hook writes `.claude/dso-artifact-check-cache` (a `KEY=VALUE` file with
`VERSION` and `TIMESTAMP` fields). On subsequent session starts, if the cached version matches
the plugin version and the cache is less than 24 hours old, the full stamp comparison is skipped
and no notice is emitted. This prevents repetitive messages within a single workday.

The cache file is automatically added to `.gitignore` by `dso-setup.sh` — it is a local
per-machine file and should not be committed.

### Plugin source repo guard

When Claude Code is opened from within the DSO plugin repository itself, the hook detects that
the plugin directory is inside the current repo root and silently exits. There are no installed
host-project artifacts to check in the plugin source tree.

---

## Keeping Artifacts Up to Date

### Prerequisite: sync the plugin first

Before updating artifacts, ensure the plugin itself is current. If DSO is managed as a Claude
Code plugin, run:

```bash
claude plugin sync
```

This pulls the latest plugin version into the plugin cache. `dso update-artifacts` reads the
plugin version from the updated plugin cache when determining which version to stamp artifacts
with. Skipping this step means artifacts will be stamped with the old plugin version.

### dso update-artifacts

After syncing the plugin (or pulling the plugin repository), update installed artifacts in your
host project:

```bash
.claude/scripts/dso update-artifacts
```

This command:
1. Reads the current plugin version from the plugin's `plugin.json`
2. Compares version stamps on each installed artifact against the plugin version
3. For stale or legacy artifacts, applies the appropriate merge strategy:
   - **Shim** (`.claude/scripts/dso`): overwritten with the latest template and re-stamped
   - **Config** (`.claude/dso-config.conf`): merged additively — new keys from the plugin
     template are appended; existing keys are preserved
   - **Pre-commit** (`.pre-commit-config.yaml`): hook entries merged — new DSO hooks added;
     user hooks preserved
   - **CI workflow** (`.github/workflows/ci.yml`): merged — new DSO steps added; user steps
     preserved
4. Updates the version stamp on each successfully updated artifact

#### Success output

Per-artifact status lines are written to stderr:

```
[update-artifacts] Shim updated: .claude/scripts/dso (version: 1.2.0)
[update-artifacts] Config merged: .claude/dso-config.conf (version: 1.2.0)
[update-artifacts] Pre-commit merged: .pre-commit-config.yaml (version: 1.2.0)
[update-artifacts] CI workflow merged: .github/workflows/ci.yml (version: 1.2.0)
```

If an artifact is already at the current version, it is reported as current and skipped:

```
[update-artifacts] Shim already current (version: 1.2.0)
```

#### Conflict output (exit 2)

When an artifact has a conflicting value that cannot be merged automatically (for example, a
config key present in both the host project and the plugin template with different values, and
that key is listed in `--conflict-keys`), `dso update-artifacts` exits with code 2 and writes
a JSON object to stdout:

```json
{
  "artifact": ".claude/dso-config.conf",
  "conflict_ours": "<base64-encoded host file content>",
  "conflict_theirs": "<base64-encoded plugin template content>"
}
```

The `conflict_ours` and `conflict_theirs` fields are base64-encoded file contents. Decode with
`base64 -d` (Linux) or `base64 -D` (macOS) to inspect the conflicting content and resolve
manually. After resolving, re-run `dso update-artifacts`.

Exit code summary:

| Exit code | Meaning |
|-----------|---------|
| `0` | All artifacts are current or were successfully updated |
| `1` | Fatal error (missing required files, no git repo) |
| `2` | Unresolvable conflict — JSON written to stdout |

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

After any version bump (patch, minor, or major), run `dso update-artifacts` to bring installed
host-project artifacts in sync with the new plugin version.

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
git checkout -- ${CLAUDE_PLUGIN_ROOT}/scripts/ ${CLAUDE_PLUGIN_ROOT}/hooks/ # shim-exempt: git reset command for file recovery, not a script invocation
```

**File permissions**: Ensure hook scripts are executable after cloning:

```bash
chmod +x /path/to/digital-service-orchestra/${CLAUDE_PLUGIN_ROOT}/scripts/* # shim-exempt: bootstrap file permission fix, run before shim is installed
chmod +x /path/to/digital-service-orchestra/${CLAUDE_PLUGIN_ROOT}/hooks/*.sh
```

**PATH**: The WSL `PATH` may not include `/home/<user>/.local/bin` where `pip`-installed tools
(including `pre-commit`) land. Add it to your `~/.bashrc`:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**GNU coreutils**: Available by default on Ubuntu/Debian. If `timeout` is missing:
`sudo apt-get install coreutils`.
