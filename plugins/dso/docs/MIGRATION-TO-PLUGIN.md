# Migration Guide: Switching from Embedded .claude/ Workflow to Digital Service Orchestra Plugin

## Overview

### What Changes

This migration moves the Claude Code workflow infrastructure from project-embedded files
to the standalone Digital Service Orchestra plugin:

| Component | Before (embedded) | After (plugin) |
|-----------|-------------------|----------------|
| Hooks | `.claude/hooks/` | `hooks/` |
| Skills | `.claude/skills/` | `skills/` |
| Scripts | `scripts/` (workflow-specific) | `scripts/` |
| Workflows | `.claude/workflows/` | `docs/workflows/` |
| CLAUDE.md | Manually maintained | Plugin-generated preamble + project sections |
| Config | Hardcoded paths | `.claude/dso-config.conf` at project root |

### What Stays

The following are **not** touched by this migration:

- Project-specific CLAUDE.md content (architecture, team rules, domain knowledge)
- Existing ticket issues, sprints, and epics
- Application source code (`app/src/`, `app/tests/`)
- Project-specific scripts that are not part of the workflow infrastructure
- `.env` files and secrets

---

## Before You Start

1. **Confirm your tests pass**:
   ```bash
   make test-unit-only
   ```
   If tests are failing, fix them before migrating. The migration does not touch app code,
   but a broken baseline makes it harder to distinguish migration issues from pre-existing ones.

2. **Commit or stash any in-progress changes**:
   ```bash
   git status
   # If there are uncommitted changes:
   git stash push -m "pre-plugin-migration stash"
   ```

3. **Note your current branch or worktree**:
   ```bash
   git branch --show-current
   pwd
   ```
   Keep this handy in case you need to rollback.

---

## Step-by-Step Migration

### Step 1: Install the Plugin

Clone the Digital Service Orchestra plugin to a stable location outside your project directory:

```bash
git clone https://github.com/navapbc/digital-service-orchestra /path/to/digital-service-orchestra
```

Recommended locations:
- `~/tools/digital-service-orchestra` (user-level, shared across projects)
- Adjacent to the project repo, e.g., `../digital-service-orchestra`

Run the setup script from the plugin directory to install the DSO shim and write
`dso.plugin_root` to `.claude/dso-config.conf`:

```bash
bash /path/to/digital-service-orchestra/${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/dso-setup.sh [TARGET_REPO] # shim-exempt: bootstrap installer, run before shim exists
```

`TARGET_REPO` defaults to your current git repo root when omitted. The script:
- Installs the `.claude/scripts/dso` shim (which resolves the plugin root automatically)
- Writes `dso.plugin_root=/path/to/digital-service-orchestra` to `.claude/dso-config.conf`
- Copies or merges `.pre-commit-config.yaml` and `.github/workflows/ci.yml`

The shim reads `dso.plugin_root` from `.claude/dso-config.conf` to resolve `CLAUDE_PLUGIN_ROOT`
automatically — no manual environment variable configuration required.

### Step 2: Create dso-config.conf

Copy the example config into your project's `.claude/` directory:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/docs/dso-config.example.conf" ./.claude/dso-config.conf
```

Open `.claude/dso-config.conf` and fill in the values for your project. At minimum:

```conf
version=1.0.0

# Set the detected stack (or let detect-stack.sh auto-detect by omitting this)
stack=python-poetry

format.extensions=.py
format.source_dirs=app/src
format.source_dirs=app/tests

commands.test=make test
commands.lint=make lint
commands.format=make format
commands.format_check=make format-check
commands.validate=./scripts/validate.sh --ci
commands.test_unit=make test-unit-only
commands.test_e2e=make test-e2e
commands.test_visual=make test-visual
```

See `${CLAUDE_PLUGIN_ROOT}/docs/workflow-config-schema.json` for the full schema reference.

### Step 3: Remove Embedded Workflow Files

Once the plugin is wired up, the embedded copies in `.claude/` are redundant. Remove them:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)

# Remove embedded workflow infrastructure
rm -rf "${REPO_ROOT}/.claude/hooks/"
rm -rf "${REPO_ROOT}/.claude/skills/"
rm -rf "${REPO_ROOT}/.claude/workflows/"
```

**Keep** the following `.claude/` files — they are project-specific:

- `.claude/settings.json` (do not delete it; no manual env configuration is required for plugin path resolution)
- `.claude/docs/` (project-specific documentation, not part of the plugin)
- Any custom project files you added to `.claude/`

**Do not remove** project-level scripts that are not part of the workflow infrastructure.
Only the workflow plugin scripts (auto-format, review-gate, validate, etc.) move to the plugin;
they are now invoked via `.claude/scripts/dso <script-name>`.

### Step 4: Regenerate CLAUDE.md

The plugin can generate a standard workflow preamble for your CLAUDE.md. Run:

```
/dso:generate-claude-md
```

This produces a preamble block covering:
- Quick Reference (validate, test, lint commands)
- Critical Rules (Never Do These / Always Do These)
- Multi-agent orchestration rules

After generation, merge the preamble with your project-specific CLAUDE.md content:

1. Keep the plugin-generated preamble at the top.
2. Append project-specific sections below (Architecture, Domain, Team Rules).
3. Do not duplicate content that the plugin already covers.

### Step 5: Verify

1. **Restart the Claude Code session** to reload the updated settings and hooks.

2. **Confirm plugin is active** by running:
   ```
   /dso:init
   ```
   This should detect your stack and confirm the DSO shim is resolving the plugin root
   from `dso.plugin_root` in `.claude/dso-config.conf`.

3. **Confirm tests still pass**:
   ```bash
   make test-unit-only
   ```

4. **Trigger a hook** to confirm hooks fire correctly. For example, edit a `.py` file —
   the auto-format PostToolUse hook should fire without errors.

---

## State Directory Migration

The hook state directory was renamed as part of the plugin extraction. The old
lockpick-specific path `/tmp/lockpick-test-artifacts-<worktree>/` is replaced
by a hash-based path `/tmp/workflow-plugin-<16-char-hash>/`.

This migration is **automatic**. On the first hook invocation after upgrading,
`get_artifacts_dir()` (in `hooks/lib/deps.sh`) detects the old
directory and copies its contents to the new location.

For full details on the state directory change — including the derivation algorithm,
idempotency guarantees, and in-flight session behavior — see:

```
docs/MIGRATION.md
```

---

## Rollback

If you need to revert to the embedded workflow:

1. **Restore `.claude/` from git history**:
   ```bash
   git checkout HEAD~1 -- .claude/hooks/ .claude/skills/ .claude/workflows/
   ```
   Adjust `HEAD~1` to the commit before you made migration changes.

2. **Remove `dso.plugin_root` from `.claude/dso-config.conf`** (or delete the file entirely).

3. **Revert hook commands** in `.claude/settings.json` back to the `.claude/hooks/` prefix pattern.

4. **Restart the Claude Code session** to pick up the restored embedded hooks.

5. **Delete `.claude/dso-config.conf`** if you do not want it in the project.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `CLAUDE_PLUGIN_ROOT: unbound variable` | `dso.plugin_root` missing from `.claude/dso-config.conf` | Re-run `dso-setup.sh` or manually add `dso.plugin_root=/path/to/digital-service-orchestra` to `.claude/dso-config.conf` |
| Hook fires but cannot find `deps.sh` | Wrong `dso.plugin_root` path in `.claude/dso-config.conf` | Verify path: `grep dso.plugin_root .claude/dso-config.conf` and confirm the directory exists |
| `/dso:init` says stack not detected | Missing `.claude/dso-config.conf` or no marker files | Run from project root; ensure `pyproject.toml` or `package.json` exists |
| Tests fail after migration | Unrelated pre-existing failures | Check `git diff HEAD~1` to confirm no app code was changed |
| `run-hook.sh: No such file` | DSO shim not installed or `dso.plugin_root` not set | Re-run `bash ${CLAUDE_PLUGIN_ROOT}/scripts/onboarding/dso-setup.sh` to install the shim and write `dso.plugin_root` | # shim-exempt: bootstrap installer invocation in troubleshooting table
