# Installation Guide — lockpick-workflow

lockpick-workflow is a Claude Code plugin that provides workflow infrastructure
skills and hooks for software development projects.

---

## Prerequisites

- **Claude Code** >= 1.0.0 (the `claude` CLI)
- **bash** >= 4.0
- **python3** with PyYAML installed — required by `read-config.sh` for parsing
  `workflow-config.yaml`

  Install PyYAML if not already present:

  ```bash
  pip install pyyaml
  # or, in a Poetry project:
  poetry add --group dev pyyaml
  ```

  Alternatively, set `CLAUDE_PLUGIN_PYTHON` to a python3 binary that already
  has PyYAML installed (e.g., a project venv).

---

## Installation

### Option A — Git-based (recommended)

```bash
claude plugin install github:lockpick/lockpick-workflow
```

This clones the plugin into Claude Code's plugin directory and registers it
automatically.

### Option B — Manual

```bash
git clone https://github.com/lockpick/lockpick-workflow.git /path/to/lockpick-workflow
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
    "CLAUDE_PLUGIN_ROOT": "/absolute/path/to/lockpick-workflow"
  }
}
```

---

## Optional: workflow-config.yaml

The plugin auto-detects common project stacks (Python/Poetry, Node/npm,
Rust/Cargo, Go) without any configuration. For custom commands or explicit
stack overrides, create a `workflow-config.yaml` at your project root:

```bash
cp /path/to/lockpick-workflow/docs/workflow-config.example.yaml workflow-config.yaml
```

Edit the file to match your project's commands. All keys are optional —
omitted keys fall back to stack-detected defaults.

Schema reference: `lockpick-workflow/docs/workflow-config-schema.json`

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

After setting `CLAUDE_PLUGIN_ROOT`, run the `/init` skill inside a Claude Code
session:

```
/init
```

The `/init` skill validates your setup by:
1. Confirming `CLAUDE_PLUGIN_ROOT` is set and points to a valid plugin directory
2. Detecting or reading the project stack
3. Reporting which commands will be used for `test`, `lint`, `format`, etc.

Expected output: a summary table of detected commands and a confirmation that
hooks are registered. If `CLAUDE_PLUGIN_ROOT` is not set or points to the
wrong location, `/init` will report an error with remediation steps.

---

## Upgrade

```bash
cd /path/to/lockpick-workflow
git pull
```

No configuration migration is required for patch or minor version bumps
(e.g., `0.1.0` → `0.1.1` or `0.2.0`).

For major version bumps (e.g., `0.x` → `1.0`), check `CHANGELOG.md` in the
plugin repository for breaking changes and any required updates to
`workflow-config.yaml` or `.claude/settings.json`.
