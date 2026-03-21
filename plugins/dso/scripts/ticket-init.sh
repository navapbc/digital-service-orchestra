#!/usr/bin/env bash
# plugins/dso/scripts/ticket-init.sh
# Initialize the event-sourced ticket system:
#   - Creates an orphan 'tickets' branch (or fetches existing one)
#   - Mounts it as a worktree at .tickets-tracker/
#   - Commits .gitignore (excluding .env-id and .state-cache)
#   - Generates a UUID4 env-id
#   - Sets gc.auto=0 on the tickets worktree
#   - Adds .tickets-tracker to .git/info/exclude
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TRACKER_DIR="$REPO_ROOT/.tickets-tracker"

# ── Idempotency guard ────────────────────────────────────────────────────────
# If .tickets-tracker/ already exists and is a valid worktree, exit 0.
if [ -d "$TRACKER_DIR" ] && [ -f "$TRACKER_DIR/.git" ]; then
    # Verify it's actually a valid worktree
    if git -C "$TRACKER_DIR" rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Ticket system already initialized."
        exit 0
    fi
fi

# ── Clean up partial-stale worktree directory ─────────────────────────────────
# If .tickets-tracker/ exists but is not a valid worktree (e.g., partial crash),
# prune stale worktree entries and remove the directory so we can re-create it.
if [ -d "$TRACKER_DIR" ] && ! git -C "$TRACKER_DIR" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
    rm -rf "$TRACKER_DIR"
fi

# ── Add .tickets-tracker to .git/info/exclude ─────────────────────────────────
_git_dir="$REPO_ROOT/.git"
# In a worktree, .git is a file pointing to the real git dir
if [ -f "$_git_dir" ]; then
    _git_dir="$(sed -n 's/^gitdir: //p' "$_git_dir")"
fi
_exclude_file="$_git_dir/info/exclude"
mkdir -p "$(dirname "$_exclude_file")"
if [ ! -f "$_exclude_file" ]; then
    echo ".tickets-tracker" > "$_exclude_file"
elif ! grep -q '\.tickets-tracker' "$_exclude_file"; then
    echo ".tickets-tracker" >> "$_exclude_file"
fi

# ── Acquire exclusive lock (30s timeout) ──────────────────────────────────────
_lock_base="$REPO_ROOT/.git"
# Resolve real git dir if in a worktree
if [ -f "$_lock_base" ]; then
    _lock_base="$(sed -n 's/^gitdir: //p' "$_lock_base")"
    # Navigate up from worktree gitdir to the common git dir
    _lock_base="$(cd "$_lock_base" && cd "$(git rev-parse --git-common-dir)" && pwd)"
fi
_lock_dir="$_lock_base/ticket-init.lock"

# Portable mkdir-based lock (atomic on all platforms, works on macOS + Linux)
_lock_acquired=false
_lock_deadline=$((SECONDS + 30))
while [ "$SECONDS" -lt "$_lock_deadline" ]; do
    if mkdir "$_lock_dir" 2>/dev/null; then
        _lock_acquired=true
        # Remove lock on exit (normal or error)
        trap 'rmdir "$_lock_dir" 2>/dev/null; exit' EXIT INT TERM
        break
    fi
    sleep 1
done
if [ "$_lock_acquired" = false ]; then
    echo "Error: could not acquire ticket-init lock within 30s" >&2
    exit 1
fi

# ── Create or mount the tickets branch ────────────────────────────────────────
_branch_exists_local=false
_branch_exists_remote=false

if git -C "$REPO_ROOT" rev-parse --verify tickets &>/dev/null; then
    _branch_exists_local=true
fi

if git -C "$REPO_ROOT" rev-parse --verify origin/tickets &>/dev/null; then
    _branch_exists_remote=true
fi

if [ "$_branch_exists_local" = true ]; then
    # Branch exists locally — just mount the worktree
    git -C "$REPO_ROOT" worktree add "$TRACKER_DIR" tickets 2>/dev/null
elif [ "$_branch_exists_remote" = true ]; then
    # Branch exists on remote — fetch and mount
    git -C "$REPO_ROOT" fetch origin tickets 2>/dev/null
    git -C "$REPO_ROOT" worktree add "$TRACKER_DIR" tickets 2>/dev/null
else
    # No branch anywhere — create orphan (portable: works with git < 2.40)
    # git worktree add --orphan requires git 2.40+; use --detach + checkout --orphan instead
    git -C "$REPO_ROOT" worktree add --detach "$TRACKER_DIR" 2>/dev/null
    git -C "$TRACKER_DIR" checkout --orphan tickets 2>/dev/null
    git -C "$TRACKER_DIR" rm -rf . --quiet 2>/dev/null || true

    # Set user config with fallback to defaults
    _user_email="$(git -C "$REPO_ROOT" config user.email 2>/dev/null || echo "ticket-system@localhost")"
    _user_name="$(git -C "$REPO_ROOT" config user.name 2>/dev/null || echo "Ticket System")"
    git -C "$TRACKER_DIR" config user.email "$_user_email"
    git -C "$TRACKER_DIR" config user.name "$_user_name"

    git -C "$TRACKER_DIR" commit --allow-empty -q -m "chore: initialize ticket tracker"
fi

# ── Ensure user config is set (for remount case) ─────────────────────────────
if ! git -C "$TRACKER_DIR" config user.email &>/dev/null; then
    _user_email="$(git -C "$REPO_ROOT" config user.email 2>/dev/null || echo "ticket-system@localhost")"
    _user_name="$(git -C "$REPO_ROOT" config user.name 2>/dev/null || echo "Ticket System")"
    git -C "$TRACKER_DIR" config user.email "$_user_email"
    git -C "$TRACKER_DIR" config user.name "$_user_name"
fi

# ── Commit .gitignore on the tickets branch ───────────────────────────────────
# Only if .gitignore doesn't already exist on the branch
if ! git -C "$TRACKER_DIR" show tickets:.gitignore &>/dev/null 2>&1; then
    cat > "$TRACKER_DIR/.gitignore" <<'GITIGNORE'
.env-id
.state-cache
GITIGNORE
    git -C "$TRACKER_DIR" add .gitignore
    git -C "$TRACKER_DIR" commit -q -m "chore: add .gitignore for env-id and state-cache"
fi

# ── Generate env-id ───────────────────────────────────────────────────────────
if [ ! -f "$TRACKER_DIR/.env-id" ]; then
    python3 -c "import uuid; print(uuid.uuid4())" > "$TRACKER_DIR/.env-id"
fi

# ── Set gc.auto=0 on the tickets worktree ─────────────────────────────────────
git -C "$TRACKER_DIR" config gc.auto 0

echo "Ticket system initialized."
