# Git Worktree Guide

> **Date**: 2026-02
> **Status**: Active
> **When to read this file**: Reference when setting up parallel development environments, running multiple Claude Code sessions, or managing long-running feature branches.

---

## Overview

Git worktrees allow you to check out multiple branches of the same repository simultaneously, each in its own directory. This project uses `git worktree` commands (and the `.claude/scripts/dso worktree-create.sh` wrapper) to manage parallel development environments.

### Config-Driven Post-Create Hook

Worktree creation supports a config-driven post-create hook via `worktree.post_create_cmd` in `dso-config.conf`. After creating a worktree, the script exports `WORKTREE_PATH` and runs the configured command. This project uses it to set up Python 3.13/Poetry environments automatically:

```conf
# .claude/dso-config.conf
worktree.post_create_cmd=./scripts/worktree-setup-env.sh
```

The `.claude/scripts/dso worktree-setup-env.sh` script detects Python 3.13 (Homebrew first, then `command -v`), removes any existing `.venv`, and runs `poetry env use` + `poetry install` in the worktree's `app/` directory. If `worktree.post_create_cmd` is absent from config, the worktree is created without any post-create setup (portability guarantee for other projects using the plugin).

### When to Use Worktrees

| Scenario | Why Worktrees Help |
|----------|--------------------|
| Parallel development with multiple Claude Code sessions | Each session gets its own working directory and branch |
| Long-running feature branches | Continue other work without stashing or switching branches |
| Reviewing PRs | Check out the PR branch in a separate worktree without disrupting your current work |
| Urgent bug fixes | Spin up a hotfix worktree without losing in-progress feature work |

---

## Quick Start

### Worktree Location Conventions

This project uses three worktree location conventions depending on how the session is launched:

| Convention | Path Pattern | Created By |
|------------|-------------|------------|
| `claude-safe` (recommended for humans) | `../<repo-name>-worktrees/worktree-YYYYMMDD-HHMMSS` | `claude-safe` wrapper or `git worktree add` |
| Claude Code built-in (agents) | `.claude/worktrees/agent-<id>` | Claude Code task/sub-agent framework |
| Per-agent isolation (`isolation: worktree`) | `.claude/worktrees/agent-<task-id>-<timestamp>` | `/dso:sprint` orchestrator when `isolation: worktree` is set |

The `claude-safe` convention places worktrees **outside** the main repo to prevent Claude Code from double-loading CLAUDE.md. The Claude Code built-in convention places worktrees inside `.claude/worktrees/` within the project; these are managed automatically by the Claude Code framework and should not be edited manually.

Per-agent worktrees (see [Per-Agent Worktree Isolation](#per-agent-worktree-isolation) below) are created by the `/dso:sprint` orchestrator to give each implementation sub-agent its own isolated branch during parallel story execution.

In all cases, hooks and scripts must locate sibling files via `$CLAUDE_PLUGIN_ROOT` or `$(git rev-parse --show-toplevel)` — never via hardcoded absolute paths.

### Automatic Setup (via `claude-safe`)

The `claude-safe` wrapper script automatically handles worktree creation, Python version pinning, and dependency installation:

```bash
# From the main repo root (creates worktree, sets up Python 3.13, installs dependencies)
claude-safe
```

This creates a timestamped worktree at `../<repo-name>-worktrees/worktree-YYYYMMDD-HHMMSS` (outside the main repo, directory name derived from repo name), runs the configured `worktree.post_create_cmd` hook (which sets up Python 3.13 and installs dependencies via Poetry), and launches Claude Code in the new worktree.

Worktrees are created **outside** the main repo to prevent Claude Code from double-loading CLAUDE.md (it walks parent directories and would load the parent repo's copy too).

### Manual Setup (via `git worktree add`)

If you need to manually create a worktree with a specific name:

```bash
# From the main repo root — create worktree OUTSIDE the repo on a new branch
git worktree add ../<repo-name>-worktrees/feature-auth -b feature-auth

# Set up the dev environment in the new worktree (REQUIRED: Python 3.13)
cd ../<repo-name>-worktrees/feature-auth/app
rm -rf .venv
poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13
poetry install
.venv/bin/pre-commit install --config ../.pre-commit-config.yaml

# Start Claude Code from the worktree root
cd ..
claude
```

### Python Version Requirement

**CRITICAL**: This project requires Python 3.13 due to dependency constraints (pydantic-core 2.27.1 max version). The `claude-safe` wrapper automatically configures the correct Python version. For manual worktree setup, you MUST explicitly pin Python 3.13 before running `poetry install`.

---

## How Git Worktrees Work

When you run `git worktree add`, git:

1. Creates a new working directory in the specified path
2. Places a `.git` file in the new worktree pointing to the main repo's `.git/` directory

This means:

- **All worktrees share the same git object store** — commits made in one worktree are immediately visible in all others via `git fetch`/`git log`
- **Ticket commands (`ticket ...`) work normally from any worktree** — the ticket CLI reads from `.tickets-tracker/` (the v3 orphan branch mounted as a worktree), which is shared across all worktrees
- **Each worktree has its own branch** — changes staged or committed in one worktree do not affect others
- Only the main repo contains the actual `.git/` database; worktrees contain a pointer file

```
/Users/joeoakhart/lockpick-doc-to-logic/       ← main repo  # portability-ok
  .git/              <-- actual git database lives here
    objects/
    refs/
    ...

/Users/joeoakhart/lockpick-doc-to-logic-worktrees/  ← worktree parent (outside repo, derived from repo name)  # portability-ok
  feature-auth/
    .git             <-- file (not directory) pointing to main repo's .git/worktrees/feature-auth/
```

---

## Managing Worktrees

### Creating Worktrees

```bash
# Basic: creates worktree outside the repo on a new branch (recommended)
git worktree add ../<repo-name>-worktrees/feature-auth -b feature-auth

# With an existing branch
git worktree add ../<repo-name>-worktrees/feature-auth feature-auth

# claude-safe does this automatically with timestamped names
claude-safe
```

### Listing Worktrees

```bash
git worktree list
```

Shows all worktrees with their path, HEAD commit, and branch.

### Inspecting the Current Worktree

```bash
# Show all worktrees (includes path and branch for each)
git worktree list

# Show only the current worktree's path
git rev-parse --show-toplevel
```

### Removing Worktrees

```bash
# Safe removal (git checks for unmerged work)
git worktree remove feature-auth

# Force removal (skip safety checks)
git worktree remove feature-auth --force
```

Before removing, verify there are no uncommitted changes or unpushed commits:

```bash
cd /path/to/worktree
git status
git log @{u}.. --oneline  # commits not pushed to remote
```

---

## Running Parallel Claude Code Sessions

Each worktree can run its own independent Claude Code session. Here is what is isolated vs shared:

### Per-Worktree Setup Requirements

Each worktree needs its own:
- **Virtual environment**: Set up with the correct Python version (Python 3.13 required)
- **Pre-commit hooks**: Run `.venv/bin/pre-commit install --config ../.pre-commit-config.yaml` from `app/`
- **Docker containers**: Use different ports (see next section)

### Environment Setup

**CRITICAL**: This project requires Python 3.13. Poetry will default to the system Python (often 3.14), which is incompatible with pydantic-core 2.27.1.

**Automated setup** (recommended): The `claude-safe` wrapper script automatically configures Python 3.13 and installs dependencies when creating worktrees.

**Manual fix** (INC-022): If you created a worktree manually or see "Command not found" errors for Poetry/pytest/etc., the venv has the wrong Python version. Fix it:
```bash
cd <worktree>/app
rm -rf .venv  # Remove any auto-created venv
poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13
poetry install
```

**Verification**:
```bash
app/.venv/bin/python --version  # Should be 3.13.x, NOT 3.14.x
```

If Python 3.13 is not found at `/opt/homebrew/opt/python@3.13/bin/python3.13`, install it:
```bash
brew install python@3.13
```

Each worktree automatically has its own:
- `.mypy_cache/`
- `.pytest_cache/`
- `.ruff_cache/`
- Claude Code session state (different path = different session)

---

## Docker Port Management for Parallel Worktrees

### Automatic Port Configuration

**As of 2026-02-14**, worktrees automatically get unique Docker ports based on the worktree directory name. No manual configuration needed!

The Makefile detects if you're in a worktree (by checking if `.git` is a file) and automatically:
1. Hashes the worktree directory name to generate a consistent port offset (1-100)
2. Sets `DB_PORT` and `APP_PORT` environment variables
3. Exports these to all `docker compose` and `pytest` commands

Example:
```bash
cd /path/to/worktree-20260214-110900/app
make test  # Automatically uses DB_PORT=5469, APP_PORT=3037
```

The same worktree always gets the same ports, so you can rely on consistent behavior across sessions.

### Two Docker Compose Files

This project has two Docker Compose files with different worktree behavior:

| File | Purpose | Worktree Behavior |
|------|---------|-------------------|
| `docker-compose.yml` | Full stack (DB + app) | Fully isolated per worktree (automatic unique ports) |
| `docker-compose.db.yml` | Persistent DB only | **Shared** across all worktrees (one instance) |

**Persistent DB (`make db-start`)**: Uses a hardcoded `container_name: lockpick-postgres-dev`, so only ONE instance can run across all worktrees. All worktrees share the same persistent DB on the same port. This is by design -- the persistent DB is a shared resource.

**Full-stack Docker (`docker compose up` or `make test`)**: No hardcoded container name, and each worktree automatically gets unique ports. Multiple worktrees can run isolated stacks simultaneously.

### Manual Port Override (Optional)

If you need to manually override the automatic port assignment:

```bash
# Override the automatic ports
cd /path/to/worktree/app
DB_PORT=5500 APP_PORT=3100 docker compose up
```

This is rarely needed, as the automatic port assignment prevents conflicts in most scenarios.

---

## Shared vs Isolated Resources

| Resource | Shared or Isolated | Notes |
|----------|-------------------|-------|
| `.tickets-tracker/` (v3 orphan branch) | Shared | ticket commands read from the event-sourced orphan branch mounted as `.tickets-tracker/`; shared across all worktrees |
| `CLAUDE.md`, `.claude/` | Git-tracked | Same content on the same branch |
| `app/.venv/` | Isolated | Each worktree needs `poetry install --no-root` |
| Docker full-stack (`docker compose up`) | Isolated | Use different ports per worktree |
| Persistent DB (`make db-start`) | Shared | One instance via fixed container name; all worktrees connect to same DB |
| `.mypy_cache/` | Isolated | Per-worktree cache directory |
| `.pytest_cache/` | Isolated | Per-worktree cache directory |
| `.ruff_cache/` | Isolated | Per-worktree cache directory |
| Test artifacts (`/tmp/lockpick-test-artifacts-<worktree>/`) | Isolated | Coverage, logs, validation state per worktree |
| Claude Code sessions | Isolated | Different path = different session |
| Git branch | Isolated | Each worktree is on its own branch |
| Git staging area | Isolated | Changes staged in one worktree do not affect others |

---

## Database Migration Conflicts

### The Problem

When two worktrees each create Alembic migrations from the same `head` revision, the migration chain forks into multiple heads. This breaks `db-migrate` because Alembic doesn't know which path to follow.

```
main branch head: revision_A
                    ├── worktree-1 creates: revision_B (down_revision = A)
                    └── worktree-2 creates: revision_C (down_revision = A)
```

### Detection

Migration head conflicts are automatically detected by:
- **validate.sh** — Reports `migrate: FAIL` with head count
- **CI** — The `Migration Heads Check` job fails on PRs with multiple heads

### Prevention

**Best practice**: Coordinate migration creation across worktrees.

1. **Check existing heads before creating a migration**:
   ```bash
   make db-migrate-heads
   ```
   If this shows more than one head, resolve it before creating a new migration.

2. **Communicate with other worktrees**: If another worktree is also creating migrations, coordinate who goes first.

3. **Merge from main frequently**: Pull the latest migrations from `main` before creating new ones:
   ```bash
   git fetch origin main && git merge origin/main --no-edit
   ```

### Resolution

If you already have multiple heads:

```bash
# 1. See the current heads
make db-migrate-heads

# 2. Create a merge migration that combines both heads
make db-migrate-merge-heads

# 3. The merge migration will be created in src/db/migrations/versions/
# Review it, then commit:
git add app/src/db/migrations/versions/
git commit -m "fix: merge Alembic migration heads"
```

The merge migration is a standard Alembic file with multiple `down_revision` values that joins the forked chains back into a single head.

---

## Concurrent Session Detection

### `claude-safe` Wrapper (Recommended)

> **Script location**: canonical source is at `scripts/claude-safe`. # shim-exempt: internal implementation path, not a user-invocable shim command

Use `.claude/scripts/dso claude-safe` instead of `claude` to get automatic worktree isolation:

```bash
claude-safe          # Launch claude (auto-isolates if a session is already active)
claude-safe --resume # All claude flags pass through
```

**What it does**:
1. Checks if another Claude session is active in this directory (via `.claude-session.lock`)
2. If active → auto-creates a worktree, `cd`s into it, and launches claude there
3. If not → writes the lock, launches claude, and cleans up the lock on exit

**Setup** (add to `~/.zshrc` or `~/.bashrc`):

```bash
# Option 1: Alias — sets CLAUDE_PLUGIN_ROOT so scripts self-locate correctly
DSO_ROOT=/path/to/dso-plugin
alias claude-safe="CLAUDE_PLUGIN_ROOT=$DSO_ROOT $DSO_ROOT/scripts/claude-safe"

# Option 2: Symlink to PATH (also requires CLAUDE_PLUGIN_ROOT in your environment)
export CLAUDE_PLUGIN_ROOT=/path/to/dso-plugin
ln -s "$CLAUDE_PLUGIN_ROOT/scripts/claude-safe" ~/.local/bin/claude-safe # shim-exempt: bootstrap symlink setup, pre-shim installation
```

Replace `/path/to/digital-service-orchestra` with the absolute path where you cloned the DSO repo.

### SessionStart Hook (Fallback)

A `SessionStart` hook (`.claude/hooks/session-safety-check.sh`) provides a backup safety net. If someone runs `claude` directly (bypassing the wrapper), the hook detects the conflict, auto-creates a worktree, and blocks the session with instructions.

Configure in `.claude/settings.local.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/session-safety-check.sh"
          }
        ]
      }
    ]
  }
}
```

### Manual Override

If you need to run a second session in the main repo (e.g., for a quick check), remove the lock file:

```bash
rm .claude-session.lock
```

---

## Session Setup

Steps to run at the start of each Claude Code session, depending on context.

### Main Repo Only (skip in worktrees)

Check for stale worktrees and clean them up using the automated script:

> **Script location**: canonical source at `.claude/scripts/dso worktree-cleanup.sh`. Config-driven via `.claude/dso-config.conf` (`infrastructure.compose_db_file`, `infrastructure.compose_project`, `infrastructure.container_prefix`, `worktree.branch_pattern`, `worktree.max_age_hours`). Docker steps are skipped when `infrastructure.compose_db_file` is absent.

```bash
# Preview what would be removed (safe, no changes made)
.claude/scripts/dso worktree-cleanup.sh --dry-run

# Interactive cleanup (prompts before each removal)
.claude/scripts/dso worktree-cleanup.sh

# Remove all safe candidates without prompting
.claude/scripts/dso worktree-cleanup.sh --all --force
```

The script checks all 6 safety criteria before removing any worktree:
1. Older than 7 days
2. Branch is merged to main
3. No uncommitted changes
4. No unpushed commits
5. No stashes
6. No active Claude session

Actions are logged to `~/.claude-safe-cleanup.log`.

**Scheduled cleanup (cron/launchd)**: Set `WORKTREE_CLEANUP_ENABLED=1` to enable non-interactive mode:

```bash
WORKTREE_CLEANUP_ENABLED=1 .claude/scripts/dso worktree-cleanup.sh --non-interactive --all --force
```

### Worktree Only

**Path anchors for sub-agents in worktrees:**
- `.claude/` and `scripts/` are always at the repo root: `$(git rev-parse --show-toplevel)/.claude/`
- Memory files are NOT at `.claude/memory/` relative to CWD — compute the path with:
  ```bash
  WORKTREE_PATH=$(git rev-parse --show-toplevel)
  ENCODED=$(echo "$WORKTREE_PATH" | tr '/' '-')
  MEMORY_DIR="$HOME/.claude/projects/${ENCODED}/memory"
  ```
- Never construct `.claude/` paths relative to the working directory (`app/`, for example)

Ensure Python 3.13 venv is configured:

```bash
if [ ! -f app/.venv/bin/python ] || ! app/.venv/bin/python --version 2>&1 | grep -q "3.13"; then
  cd app && rm -rf .venv && poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13 && poetry install && cd ..
fi
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Command not found" for all Poetry/pytest tools | Wrong Python version (3.14 instead of 3.13). Fix: `cd app && rm -rf .venv && poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13 && poetry install` |
| `poetry install` fails with "requires Python <3.14" | Same as above: Pin Python 3.13 explicitly before running `poetry install` |
| Port conflict on Docker startup (full-stack) | **Should not happen** - automatic port assignment prevents this. If it occurs, check that you're running `make test` (not raw `docker compose up`), which ensures ports are set. Manual override: `DB_PORT=<port> APP_PORT=<port> docker compose up` |
| Port conflict with persistent DB (`make db-start`) | The persistent DB is shared (one instance for all worktrees). If another worktree already started it, just use the existing instance. Or stop it first: `make db-stop` |
| `ticket` commands fail in worktree | Verify `.tickets-tracker/` is accessible: `ls $(git rev-parse --show-toplevel)/.tickets-tracker/` — it should be present as the v3 orphan branch worktree |
| Pre-commit hooks not working | Re-run `.venv/bin/pre-commit install --config ../.pre-commit-config.yaml` from `app/` |
| Disk space running low | Each worktree with venv takes ~500MB+; remove unused worktrees with `git worktree remove <name>` |
| "Not a git repository" error | Ensure you are inside the worktree directory, not a parent |
| Worktree branch already checked out | Each branch can only be checked out in one worktree at a time; use `-b <new-branch>` to create a new branch: `git worktree add ../<repo-name>-worktrees/feature-auth -b feature-auth` |
| `make db-start` fails: container name conflict | The persistent DB uses a fixed container name; only one instance can run. Stop the existing one first with `make db-stop`, or share the existing DB across worktrees |
| `validate.sh` reports multiple migration heads | Two worktrees created migrations from the same base. Run `make db-migrate-merge-heads` to create a merge migration. See "Database Migration Conflicts" section above |

---

## Complete Worktree Lifecycle Example

This shows the full flow from creation to cleanup.

### 1. Create the Worktree

```bash
# From main repo root — creates worktree outside repo on a new branch
git worktree add ../<repo-name>-worktrees/feature-auth -b feature-auth-redesign
```

**Branch naming tip**: Use dash-separated names (e.g., `feature-auth-redesign`) rather than slash-separated names (e.g., `feature/auth-redesign`) to ensure CI triggers on direct pushes. CI patterns like `feature-*` match dashes but not slashes. Slash-separated branches still trigger CI via pull requests to `main`.

### 2. Set Up the Dev Environment

```bash
cd ../<repo-name>-worktrees/feature-auth/app
rm -rf .venv
poetry env use /opt/homebrew/opt/python@3.13/bin/python3.13
poetry install
.venv/bin/pre-commit install --config ../.pre-commit-config.yaml
```

### 3. Start Working

```bash
cd /Users/joeoakhart/lockpick-doc-to-logic-worktrees/feature-auth  # portability-ok
claude
```

Work normally -- write code, run tests, commit. Ticket commands work as usual. Prefer scoped filters (`--parent=`, `--status=`, `--type=`) or `ticket ready --epic=<id>` over bare `ticket list`, which dumps the entire tracker into context:

```bash
# Narrow to unblocked work under the epic you're sprinting on
.claude/scripts/dso ticket ready --epic=<epic-id>

# Or scope directly to direct children of the ticket in focus
.claude/scripts/dso ticket list --parent=<epic-id> --status=open,in_progress

.claude/scripts/dso ticket transition <id> in_progress
# ... do the work ...
make lint && make test
git add <files> && git commit -m "feat: auth redesign"
```

### 4. Push and Create PR

```bash
git push -u origin feature-auth-redesign
gh pr create --title "feat: auth redesign" --body "..."
```

### 5. Wait for CI

```bash
"$(git rev-parse --show-toplevel)/.claude/scripts/dso" ci-status.sh --wait
```

### 6. Clean Up After Merge

```bash
# Switch back to the main repo
cd /path/to/lockpick-doc-to-logic

# Remove the worktree (git checks for unmerged work)
git worktree remove feature-auth

# Pull the merged changes
git pull
```

---

## Per-Agent Worktree Isolation

### Overview

When `/dso:sprint` dispatches implementation sub-agents with `isolation: worktree`, each agent receives its own dedicated worktree rather than operating in the shared orchestrator directory. This prevents concurrent agents from overwriting each other's in-progress files.

Per-agent worktrees are created automatically by the orchestrator before each batch dispatch and are distinct from the `claude-safe` human worktrees and the Claude Code built-in agent worktrees.

### Worktree Lifecycle: create → implement → review → commit → merge → cleanup

```
1. create     Orchestrator runs: git worktree add .claude/worktrees/agent-<task-id>-<ts> -b agent/<task-id>
2. implement  Sub-agent works in the per-agent worktree. Writes code, runs tests. Does NOT commit.
3. review     Orchestrator dispatches dso:code-reviewer-* in the shared (non-isolated) directory,
              passing the diff from the per-agent worktree for review.
4. commit     Orchestrator (not the sub-agent) commits approved changes to the worktree branch.
5. merge      Orchestrator merges the per-agent branch back into the story branch (or main worktree branch).
6. cleanup    Orchestrator removes the per-agent worktree: git worktree remove .claude/worktrees/agent-<task-id>-<ts>
```

### Sub-Agent Rules in Per-Agent Worktrees

Sub-agents running under `isolation: worktree` **must NOT commit** — they implement only:

- Write code changes and run tests (TDD: RED → GREEN)
- Record checkpoint notes via `.claude/scripts/dso ticket comment`
- Write discovery files to `$ARTIFACTS_DIR/agent-discoveries/<task-id>.json`
- Return `STATUS: pass|fail` and `FILES_MODIFIED:` in their final report
- Do NOT run `git commit`, `git push`, or any commit workflow step

The orchestrator reads the sub-agent's report, dispatches review, then commits on behalf of the sub-agent.

### Artifact Isolation Semantics

Each per-agent worktree gets its own `ARTIFACTS_DIR`, derived from a hash of `REPO_ROOT`:

```bash
# Compute ARTIFACTS_DIR inside a per-agent worktree (same library as all hooks)
source ${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh && get_artifacts_dir
```

This means:
- Test status files (`record-test-status.sh`) are scoped to the agent's worktree
- Review sentinel files are scoped to the agent's worktree
- Agent discovery files (`agent-discoveries/<task-id>.json`) are scoped to the agent's worktree
- Artifacts do NOT bleed between concurrent per-agent worktrees

The orchestrator collects artifacts from each per-agent `ARTIFACTS_DIR` after the agent returns.

### Retention Protocol

Per-agent worktrees are retained until merge is complete:

| State | Action |
|-------|--------|
| Sub-agent still running | Worktree retained — never remove a worktree while its agent is active |
| Sub-agent returned, review pending | Worktree retained — review may need to inspect files in the worktree |
| Review complete, commit pending | Worktree retained — orchestrator has not yet committed |
| Commit complete, merge pending | Worktree retained — merge step reads from the worktree branch |
| Merge complete | Worktree safe to remove — `git worktree remove .claude/worktrees/agent-<task-id>-<ts>` |

After cleanup, the orchestrator deletes the per-agent branch:
```bash
git branch -d agent/<task-id>
```

### Code-Review Sub-Agents Are NOT Isolated

Code-review (`dso:code-reviewer-*`) and fix-resolution sub-agents must NOT receive `isolation: worktree`. They require `reviewer-findings.json` and `write-reviewer-findings.sh` to be present in the shared orchestrator directory. Running them in a per-agent worktree would break the review gate. See `SUB-AGENT-BOUNDARIES.md` for the full prohibition.

---

## Cross-Worktree Ticket Sync

The v3 ticket system stores ticket events on a dedicated orphan git branch (`tickets`) mounted as `.tickets-tracker/`. All mutations are appended as JSON event files and the compiled state is produced on-demand by the Python reducer. Ticket state is shared across worktrees through normal git push/fetch on the `tickets` branch — there is no separate sync infrastructure.

### Syncing Code in Worktrees

Pull the latest main into the worktree branch before launching sub-agent batches:

```bash
git fetch origin main && git merge origin/main --no-edit
```

Ticket branch syncing happens automatically during `merge-to-main.sh` at end-of-sprint.

### Structured Note Format

Notes have unique IDs, `origin` tracking (`agent` or `jira`), ISO timestamps, and `sync_state` markers (`unsynced` or `synced`). This format enables bidirectional comment sync with Jira (see `.claude/docs/JIRA-INTEGRATION.md`).

---

## Merging a Worktree Branch to Main

At the end of a worktree session, use `merge-to-main.sh` (not raw `git merge`) to merge the worktree branch into `main` and push. The `/dso:end` skill calls this automatically.

```bash
# Standard usage (runs all phases sequentially)
.claude/scripts/dso merge-to-main.sh
```

### Phased Workflow

`merge-to-main.sh` executes as a sequence of named phases:

| Phase | Description |
|-------|-------------|
| `sync` | Sync ticket state from main before merging |
| `merge` | Merge worktree branch into main |
| `version_bump` | Bump patch version (when `version.file_path` is configured and `--bump` is passed) |
| `validate` | Run post-merge validation checks |
| `push` | Push main to origin (idempotent if already up to date) |
| `archive` | Archive worktree branch |
| `ci_trigger` | Trigger CI workflow if configured |

### Resuming an Interrupted Merge

If `merge-to-main.sh` is interrupted mid-run (e.g., by a SIGURG timeout), the script saves the in-progress phase to a state file via a SIGURG trap. Re-run with `--resume` to continue from the last completed phase:

```bash
# Resume after interruption — reads state file and skips completed phases
.claude/scripts/dso merge-to-main.sh --resume
```

**State file**: `/tmp/merge-to-main-state-<branch>.json` — records completed phases. Expires after 4 hours (stale state files are removed on next run).

**Lock file**: `/tmp/merge-to-main-lock-<hash>` — prevents concurrent merge runs against the same repo. If a stale lock exists (process died), it is automatically broken on the next run.

### Resuming After a Failure

To resume from the last incomplete phase after a partial failure:

```bash
.claude/scripts/dso merge-to-main.sh --resume
```

The script records completed phases in a state file and resumes from the first incomplete one.

---

## Reference

- **CLAUDE.md**: Quick Reference section for development commands
- **TESTING-MIGRATION.md**: Testing workflow and database management
- **GOTCHAS.md**: Docker section for container-specific issues
- **JIRA-INTEGRATION.md**: Jira sync mechanics and comment sync
- **SCRIPT-MIGRATION-PATTERNS.md**: Wrapper patterns and plugin migration conventions
- **dso-config.conf**: Project-specific config including `worktree.post_create_cmd`
