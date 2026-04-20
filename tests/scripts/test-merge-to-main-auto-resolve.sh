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

# Prevent PROJECT_ROOT from leaking into temp-repo merge-to-main.sh invocations.
# The dso shim exports PROJECT_ROOT; if inherited, merge-to-main.sh uses the
# actual project root instead of the temp repo, causing false dirty-worktree failures.
unset PROJECT_ROOT

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
if [[ "${MERGE_OUT1,,}" =~ auto-resolved ]] || [[ "${MERGE_OUT1,,}" == *ticket-data\ conflicts\ auto-resolved* ]]; then
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
if [[ "$MERGE_OUT2" == *$'\nDONE:'* ]] || [[ "$MERGE_OUT2" == DONE:* ]]; then
    NO_DONE2="false"
fi
assert_eq "test_non_ticket_conflict_blocks_merge" "true" "$NO_DONE2"

# Should mention --resume in the error message
HAS_RESUME2="false"
if [[ "$MERGE_OUT2" == *--resume* ]]; then
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
if [[ "$MERGE_OUT3" == *$'\nDONE:'* ]] || [[ "$MERGE_OUT3" == DONE:* ]]; then
    HAS_DONE3="true"
fi
assert_eq "test_v3_two_level_ticket_path_auto_resolved" "true" "$HAS_DONE3"

# Auto-resolve message must appear
HAS_AUTO_MSG3="false"
if [[ "${MERGE_OUT3,,}" =~ auto-resolved ]] || [[ "${MERGE_OUT3,,}" == *ticket-data\ conflicts\ auto-resolved* ]]; then
    HAS_AUTO_MSG3="true"
fi
assert_eq "test_v3_two_level_ticket_path_reports_auto_resolve" "true" "$HAS_AUTO_MSG3"

git -C "$ENV3/main" worktree remove --force "$ENV3/worktree" 2>/dev/null || true

# =============================================================================
# Test 4: Skip pull --rebase when origin/main is already an ancestor of main
# Bug a8a1-6e9b: merge-to-main.sh fails when main is ahead of origin/main and
# git pull --rebase hits conflicts from prior worktree merges. The fix: detect
# that origin/main is an ancestor of HEAD and skip the pull entirely.
# =============================================================================

# Helper: create an env where main is AHEAD of origin/main (ancestor case).
# origin/main is an ancestor of local main. git pull --rebase is a no-op.
setup_ancestor_skip_env() {
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

    # Simulate prior worktree merge: main is AHEAD of origin (local commit not pushed)
    echo "prior-merge content" > "$ENV/main/extra.txt"
    git -C "$ENV/main" add extra.txt
    git -C "$ENV/main" commit -q -m "merge prior-worktree (local only)"

    # Fetch to update origin/main ref — origin stays at "init"
    git -C "$ENV/main" fetch origin 2>/dev/null || true

    echo "$ENV"
}

ENV4=$(setup_ancestor_skip_env)
WT4=$(cd "$ENV4/worktree" && pwd -P)

MERGE_OUT4=$(cd "$WT4" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Should succeed — origin/main is ancestor of main, pull is skipped
HAS_DONE4="false"
if [[ "$MERGE_OUT4" == *$'\nDONE:'* ]] || [[ "$MERGE_OUT4" == DONE:* ]]; then
    HAS_DONE4="true"
fi
assert_eq "test_ancestor_skip_pull_completes" "true" "$HAS_DONE4"

# Should log the stale-ahead reset message (35eb-1824: reset when local main is ahead)
HAS_SKIP_MSG4="false"
if [[ "${MERGE_OUT4,,}" =~ ahead.*origin/main ]] || [[ "${MERGE_OUT4,,}" =~ reset.*origin/main ]] || [[ "${MERGE_OUT4,,}" =~ origin/main.*ancestor.*skip ]]; then
    HAS_SKIP_MSG4="true"
fi
assert_eq "test_ancestor_skip_pull_logs_message" "true" "$HAS_SKIP_MSG4"

git -C "$ENV4/main" worktree remove --force "$ENV4/worktree" 2>/dev/null || true

# =============================================================================
# Test 5: Diverged pull with non-ticket code conflicts does NOT emit
# CONFLICT_DATA at pull_rebase phase — the conflict is deferred to _phase_merge
# Bug a8a1-6e9b: previously, the script aborted with CONFLICT_DATA at
# pull_rebase with no recovery path. Now it logs a warning and continues.
# =============================================================================

setup_diverged_pull_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ENV
    ENV=$(cd "$tmpdir" && pwd -P)

    # Seed repo with a shared file
    git init -q -b main "$ENV/seed"
    git -C "$ENV/seed" config user.email "test@test.com"
    git -C "$ENV/seed" config user.name "Test"
    echo "init" > "$ENV/seed/README.md"
    echo "base content" > "$ENV/seed/shared.txt"
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

    # Simulate prior worktree A merging to main: modify shared.txt locally
    echo "modified by worktree-A merge" > "$ENV/main/shared.txt"
    git -C "$ENV/main" add shared.txt
    git -C "$ENV/main" commit -q -m "merge worktree-A (local, not pushed)"

    # Push a conflicting change to origin from another clone
    local tmp_clone
    tmp_clone=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp_clone")
    git clone -q "$ENV/bare.git" "$tmp_clone/push"
    git -C "$tmp_clone/push" config user.email "other@test.com"
    git -C "$tmp_clone/push" config user.name "Other"
    echo "modified by other-worktree push" > "$tmp_clone/push/shared.txt"
    git -C "$tmp_clone/push" add shared.txt
    git -C "$tmp_clone/push" commit -q -m "other: different change to shared.txt"
    git -C "$tmp_clone/push" push -q origin main

    echo "$ENV"
}

ENV5=$(setup_diverged_pull_env)
WT5=$(cd "$ENV5/worktree" && pwd -P)

MERGE_OUT5=$(cd "$WT5" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Should NOT contain the old CONFLICT_DATA at pull_rebase — that phase is gone
NO_CONFLICT5="true"
if [[ "$MERGE_OUT5" == *CONFLICT_DATA*pull_rebase* ]]; then
    NO_CONFLICT5="false"
fi
assert_eq "test_diverged_pull_no_pull_rebase_abort" "true" "$NO_CONFLICT5"

# Should contain the warning about skipping the pull
HAS_WARNING5="false"
if [[ "${MERGE_OUT5,,}" =~ warning.*could\ not\ merge\ origin/main.*continuing ]]; then
    HAS_WARNING5="true"
fi
assert_eq "test_diverged_pull_logs_skip_warning" "true" "$HAS_WARNING5"

git -C "$ENV5/main" worktree remove --force "$ENV5/worktree" 2>/dev/null || true

# =============================================================================
# Test 6: bash -n syntax check
# =============================================================================
SYNTAX_OK=0
bash -n "$MERGE_SCRIPT" 2>/dev/null && SYNTAX_OK=1
assert_eq "test_merge_script_syntax_valid" "1" "$SYNTAX_OK"

# =============================================================================
print_summary
