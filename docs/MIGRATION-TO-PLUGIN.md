# Migration Guide: Switching from Embedded .claude/ Workflow to lockpick-workflow Plugin

## Overview

### What Changes

This migration moves the Claude Code workflow infrastructure from project-embedded files
to the standalone `lockpick-workflow` plugin:

| Component | Before (embedded) | After (plugin) |
|-----------|-------------------|----------------|
| Hooks | `.claude/hooks/` | `lockpick-workflow/hooks/` |
| Skills | `.claude/skills/` | `lockpick-workflow/skills/` |
| Scripts | `scripts/` (workflow-specific) | `lockpick-workflow/scripts/` |
| Workflows | `.claude/workflows/` | `lockpick-workflow/docs/workflows/` |
| CLAUDE.md | Manually maintained | Plugin-generated preamble + project sections |
| Config | Hardcoded paths | `workflow-config.conf` at project root |

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

Clone the `lockpick-workflow` plugin to a stable location outside your project directory:

```bash
git clone https://github.com/lockpick/lockpick-workflow /path/to/lockpick-workflow
```

Recommended locations:
- `~/tools/lockpick-workflow` (user-level, shared across projects)
- Adjacent to the project repo, e.g., `../lockpick-workflow`

Set `CLAUDE_PLUGIN_ROOT` in your project's `.claude/settings.json` so all hooks and
skills resolve paths correctly:

```json
{
  "env": {
    "CLAUDE_PLUGIN_ROOT": "/path/to/lockpick-workflow"
  },
  "hooks": { ... }
}
```

Replace `/path/to/lockpick-workflow` with the actual absolute path where you cloned the plugin.

Update each hook command to reference the plugin location. The pattern changes from:

```
cd "$(git rev-parse --show-toplevel)" && .claude/hooks/run-hook.sh .claude/hooks/<hook>.sh
```

to:

```
cd "$(git rev-parse --show-toplevel)" && "${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/<hook>.sh"
```

### Step 2: Create workflow-config.conf

Copy the example config into your project root:

```bash
cp "${CLAUDE_PLUGIN_ROOT}/docs/workflow-config.example.conf" ./workflow-config.conf
```

Open `workflow-config.conf` and fill in the values for your project. At minimum:

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
commands.validate=./lockpick-workflow/scripts/validate.sh --ci
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

- `.claude/settings.json` (edit this to add the `env` block, but do not delete it)
- `.claude/docs/` (project-specific documentation, not part of the plugin)
- Any custom project files you added to `.claude/`

**Do not remove** project-level scripts that are not part of the workflow infrastructure
(e.g., `scripts/validate.sh`, `scripts/ci-status.sh`). Only the workflow plugin scripts
(auto-format, review-gate, etc.) move to the plugin.

### Step 4: Regenerate CLAUDE.md

The plugin can generate a standard workflow preamble for your CLAUDE.md. Run:

```
/generate-claude-md
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
   /init
   ```
   This should detect your stack and confirm `CLAUDE_PLUGIN_ROOT` is set.

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
`get_artifacts_dir()` (in `lockpick-workflow/hooks/lib/deps.sh`) detects the old
directory and copies its contents to the new location.

For full details on the state directory change — including the derivation algorithm,
idempotency guarantees, and in-flight session behavior — see:

```
lockpick-workflow/docs/MIGRATION.md
```

---

## Rollback

If you need to revert to the embedded workflow:

1. **Restore `.claude/` from git history**:
   ```bash
   git checkout HEAD~1 -- .claude/hooks/ .claude/skills/ .claude/workflows/
   ```
   Adjust `HEAD~1` to the commit before you made migration changes.

2. **Remove `CLAUDE_PLUGIN_ROOT` from `.claude/settings.json`**:
   ```json
   {
     "env": {}
   }
   ```

3. **Revert hook commands** in `.claude/settings.json` back to the `.claude/hooks/` prefix pattern.

4. **Restart the Claude Code session** to pick up the restored embedded hooks.

5. **Delete `workflow-config.conf`** if you do not want it in the project root.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `CLAUDE_PLUGIN_ROOT: unbound variable` | `env` block missing from `settings.json` | Add `"env": { "CLAUDE_PLUGIN_ROOT": "/path/..." }` |
| Hook fires but cannot find `deps.sh` | Wrong `CLAUDE_PLUGIN_ROOT` path | Verify path with `echo $CLAUDE_PLUGIN_ROOT` in a Bash hook |
| `/init` says stack not detected | Missing `workflow-config.conf` or no marker files | Run from project root; ensure `pyproject.toml` or `package.json` exists |
| Tests fail after migration | Unrelated pre-existing failures | Check `git diff HEAD~1` to confirm no app code was changed |
| `run-hook.sh: No such file` | `CLAUDE_PLUGIN_ROOT` not set in hook command | Recheck `settings.json` hook commands to use `${CLAUDE_PLUGIN_ROOT}/hooks/run-hook.sh` |
