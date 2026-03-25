#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-auto-resolve.sh
# Behavioral integration tests for merge-to-main.sh conflict auto-resolution.
#
# Tests the full merge-to-main.sh script against fixture repos with real
# conflicts, verifying that ticket-data conflicts are auto-resolved and
# non-ticket conflicts cause appropriate failures.
#
# Replaces the change-detector tests in test-merge-to-main-qt4u.sh.
#
# Usage: bash tests/scripts/test-merge-to-main-auto-resolve.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# Ensure python3 with pyyaml is available for read-config.sh
if [[ -z "${CLAUDE_PLUGIN_PYTHON:-}" ]]; then
    for _py in "$REPO_ROOT/app/.venv/bin/python3" "$REPO_ROOT/.venv/bin/python3" "python3"; do
        if "$_py" -c "import yaml" 2>/dev/null; then
            export CLAUDE_PLUGIN_PYTHON="$_py"
            break
        fi
    done
fi

# ── Helper: create a full merge-to-main test env with a pull conflict ────
# The conflict is injected between the worktree branch point and origin/main,
# so it surfaces during `git pull --rebase` in the main repo after the merge.
#
# Args:
#   $1 — conflict file path (e.g., ".tickets-tracker/t1/event.json")
setup_pull_conflict_env() {
    local conflict_path="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ENV
    ENV=$(cd "$tmpdir" && pwd -P)

    # Seed repo
    git init -q -b main "$ENV/seed"
    git -C "$ENV/seed" config user.email "test@test.com"
    git -C "$ENV/seed" config user.name "Test"
    echo "init" > "$ENV/seed/README.md"
    mkdir -p "$ENV/seed/.claude"
    echo "tickets.directory=.tickets" > "$ENV/seed/.claude/dso-config.conf"
    git -C "$ENV/seed" add -A
    git -C "$ENV/seed" commit -q -m "init"

    # Bare origin
    git clone --bare -q "$ENV/seed" "$ENV/bare.git"

    # Main clone
    git clone -q "$ENV/bare.git" "$ENV/main"
    git -C "$ENV/main" config user.email "test@test.com"
    git -C "$ENV/main" config user.name "Test"

    # Create worktree on feature branch
    git -C "$ENV/main" branch feature-branch 2>/dev/null || true
    git -C "$ENV/main" worktree add -q "$ENV/worktree" feature-branch
    git -C "$ENV/worktree" config user.email "test@test.com"
    git -C "$ENV/worktree" config user.name "Test"

    # Feature commit on worktree
    echo "feature work" > "$ENV/worktree/feature.txt"
    git -C "$ENV/worktree" add feature.txt
    git -C "$ENV/worktree" commit -q -m "feat: feature work"

    # Now push a conflicting commit directly to origin/main (simulates
    # another developer or CI pushing between the branch point and merge).
    # This creates a pull --rebase conflict in the main repo.
    local tmp_clone
    tmp_clone=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp_clone")
    git clone -q "$ENV/bare.git" "$tmp_clone/push"
    git -C "$tmp_clone/push" config user.email "other@test.com"
    git -C "$tmp_clone/push" config user.name "Other"
    local conflict_dir
    conflict_dir=$(dirname "$conflict_path")
    mkdir -p "$tmp_clone/push/$conflict_dir"
    echo '{"from": "other-developer"}' > "$tmp_clone/push/$conflict_path"
    git -C "$tmp_clone/push" add "$conflict_path"
    git -C "$tmp_clone/push" commit -q -m "other: add conflicting file"
    git -C "$tmp_clone/push" push -q origin main

    # Also add the same file on the worktree's main (via the main clone)
    # so that after the worktree merges to main-clone, the pull --rebase
    # from origin hits the conflict.
    mkdir -p "$ENV/main/$conflict_dir"
    echo '{"from": "local-main"}' > "$ENV/main/$conflict_path"
    git -C "$ENV/main" add "$conflict_path"
    git -C "$ENV/main" commit -q -m "local: add conflicting file"

    echo "$ENV"
}

# =============================================================================
# Test 1: Ticket-tracker JSON conflicts are auto-resolved during pull --rebase
# =============================================================================
ENV1=$(setup_pull_conflict_env ".tickets-tracker/t1/001-CREATE.json")
WT1=$(cd "$ENV1/worktree" && pwd -P)

MERGE_OUT1=$(cd "$WT1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

assert_contains "test_ticket_json_conflict_auto_resolved" "DONE" "$MERGE_OUT1"

# Verify auto-resolve message appeared
HAS_AUTO_MSG1="false"
if echo "$MERGE_OUT1" | grep -qi "auto-resolved\|Ticket-data conflicts auto-resolved"; then
    HAS_AUTO_MSG1="true"
fi
assert_eq "test_ticket_json_conflict_reports_auto_resolve" "true" "$HAS_AUTO_MSG1"

# Feature file landed on main
FEATURE1=$(cd "$ENV1/main" && git show HEAD:feature.txt 2>/dev/null || echo "NOT_FOUND")
assert_eq "test_ticket_json_conflict_feature_on_main" "feature work" "$FEATURE1"

git -C "$ENV1/main" worktree remove --force "$ENV1/worktree" 2>/dev/null || true

# =============================================================================
# Test 2: Non-ticket conflicts cause merge failure
# =============================================================================
ENV2=$(setup_pull_conflict_env "src/app.py")
WT2=$(cd "$ENV2/worktree" && pwd -P)

MERGE_OUT2=$(cd "$WT2" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Should fail — real code conflict
NO_DONE2="true"
if echo "$MERGE_OUT2" | grep -q "^DONE:"; then
    NO_DONE2="false"
fi
assert_eq "test_non_ticket_conflict_blocks_merge" "true" "$NO_DONE2"

# Should mention --resume in the error message
HAS_RESUME2="false"
if echo "$MERGE_OUT2" | grep -q "\-\-resume"; then
    HAS_RESUME2="true"
fi
assert_eq "test_non_ticket_conflict_mentions_resume" "true" "$HAS_RESUME2"

git -C "$ENV2/main" worktree remove --force "$ENV2/worktree" 2>/dev/null || true

# =============================================================================
# Test 3: v3 two-level ticket event path is auto-resolved (not treated as
# non-archive conflict). Validates the case pattern matches <id>/<event>.json.
# =============================================================================
ENV3=$(setup_pull_conflict_env ".tickets-tracker/abc123/02-transition.json")
WT3=$(cd "$ENV3/worktree" && pwd -P)

MERGE_OUT3=$(cd "$WT3" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Should succeed — two-level ticket path must be auto-resolved, not block merge
HAS_DONE3="false"
if echo "$MERGE_OUT3" | grep -q "^DONE:"; then
    HAS_DONE3="true"
fi
assert_eq "test_v3_two_level_ticket_path_auto_resolved" "true" "$HAS_DONE3"

# Auto-resolve message must appear
HAS_AUTO_MSG3="false"
if echo "$MERGE_OUT3" | grep -qi "auto-resolved\|Ticket-data conflicts auto-resolved"; then
    HAS_AUTO_MSG3="true"
fi
assert_eq "test_v3_two_level_ticket_path_reports_auto_resolve" "true" "$HAS_AUTO_MSG3"

git -C "$ENV3/main" worktree remove --force "$ENV3/worktree" 2>/dev/null || true

# =============================================================================
# Test 4: bash -n syntax check
# =============================================================================
SYNTAX_OK=0
bash -n "$MERGE_SCRIPT" 2>/dev/null && SYNTAX_OK=1
assert_eq "test_merge_script_syntax_valid" "1" "$SYNTAX_OK"

# =============================================================================
print_summary
