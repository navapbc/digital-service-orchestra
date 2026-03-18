#!/usr/bin/env bash
# tests/hooks/test-pre-compact-marker.sh
#
# Tests for the rollback marker written by pre-compact-checkpoint.sh:
#   (a) Marker file is written after a successful checkpoint commit
#   (b) Default marker filename used when config key is absent
#   (c) No marker written on no-op path (no real changes)
#
# Usage: bash tests/hooks/test-pre-compact-marker.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPACT_HOOK="$PLUGIN_ROOT/hooks/pre-compact-checkpoint.sh"
DEPS_SH="$PLUGIN_ROOT/hooks/lib/deps.sh"
READ_CONFIG="$PLUGIN_ROOT/scripts/read-config.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# =============================================================================
# TEST A: Marker file is written after checkpoint commit (with real changes)
# =============================================================================

test_marker_written_after_checkpoint_commit() {
    local TEST_DIR
    TEST_DIR=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_DIR")
    local TEST_ARTIFACTS
    TEST_ARTIFACTS=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_ARTIFACTS")

    (
        cd "$TEST_DIR"
        git init -q -b main
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial-test-a" > file.txt
        git add file.txt
        git commit -q -m "initial"
        # Add uncommitted work so _HAS_REAL_CHANGES is non-empty
        echo "work-in-progress" > work.py
    ) 2>/dev/null

    # Run the hook in the temp repo
    (
        cd "$TEST_DIR"
        export _DEPS_LOADED=1
        get_artifacts_dir() { echo "$TEST_ARTIFACTS"; }
        export -f get_artifacts_dir
        bash "$COMPACT_HOOK" 2>/dev/null
    ) || true

    # The marker file should exist in the working tree (not committed)
    local MARKER_DEFAULT=".checkpoint-pending-rollback"
    if [[ -f "$TEST_DIR/$MARKER_DEFAULT" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_marker_written_after_checkpoint_commit\n  %s not found in working tree\n" "$MARKER_DEFAULT" >&2
    fi

    # Verify marker is NOT committed (should be in .gitignore)
    local IN_INDEX
    IN_INDEX=$(cd "$TEST_DIR" && git ls-files "$MARKER_DEFAULT" 2>/dev/null || true)
    if [[ -z "$IN_INDEX" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_marker_not_committed\n  %s was found in git index\n" "$MARKER_DEFAULT" >&2
    fi

    rm -rf "$TEST_DIR" "$TEST_ARTIFACTS"
}

test_marker_written_after_checkpoint_commit

# =============================================================================
# TEST B: Default marker filename used when workflow-config.conf lacks key
# =============================================================================

test_marker_uses_default_when_config_absent() {
    local TEST_DIR
    TEST_DIR=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_DIR")
    local TEST_ARTIFACTS
    TEST_ARTIFACTS=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_ARTIFACTS")

    (
        cd "$TEST_DIR"
        git init -q -b main
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial-test-b" > file.txt
        git add file.txt
        git commit -q -m "initial"
        # Create a workflow-config.conf WITHOUT checkpoint.marker_file
        cat > workflow-config.conf <<'CONF'
stack=python-poetry
CONF
        git add workflow-config.conf
        git commit -q -m "add config"
        # Add uncommitted work
        echo "work" > work.py
    ) 2>/dev/null

    (
        cd "$TEST_DIR"
        export _DEPS_LOADED=1
        get_artifacts_dir() { echo "$TEST_ARTIFACTS"; }
        export -f get_artifacts_dir
        bash "$COMPACT_HOOK" 2>/dev/null
    ) || true

    # Should still write the default marker file
    if [[ -f "$TEST_DIR/.checkpoint-pending-rollback" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_marker_uses_default_when_config_absent\n  .checkpoint-pending-rollback not found when config key is absent\n" >&2
    fi

    rm -rf "$TEST_DIR" "$TEST_ARTIFACTS"
}

test_marker_uses_default_when_config_absent

# =============================================================================
# TEST C: No marker written on no-op path (no real changes)
# =============================================================================

test_no_marker_written_when_no_changes() {
    local TEST_DIR
    TEST_DIR=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_DIR")
    local TEST_ARTIFACTS
    TEST_ARTIFACTS=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_ARTIFACTS")

    (
        cd "$TEST_DIR"
        git init -q -b main
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > file.txt
        git add file.txt
        git commit -q -m "initial"
        # No uncommitted work — _HAS_REAL_CHANGES will be empty
    ) 2>/dev/null

    (
        cd "$TEST_DIR"
        export _DEPS_LOADED=1
        get_artifacts_dir() { echo "$TEST_ARTIFACTS"; }
        export -f get_artifacts_dir
        bash "$COMPACT_HOOK" 2>/dev/null
    ) || true

    if [[ ! -f "$TEST_DIR/.checkpoint-pending-rollback" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_no_marker_written_when_no_changes\n  .checkpoint-pending-rollback should not exist on no-op path\n" >&2
    fi

    rm -rf "$TEST_DIR" "$TEST_ARTIFACTS"
}

test_no_marker_written_when_no_changes

# =============================================================================
# TEST D: Config key checkpoint.marker_file exists in workflow-config.conf
# =============================================================================

test_config_key_exists() {
    # workflow-config.conf is not committed to git (it's a local config file).
    # Skip gracefully in CI where the file is absent; only verify when present.
    if [[ ! -f "$REPO_ROOT/workflow-config.conf" ]]; then
        (( ++PASS ))
        return
    fi
    local MARKER_VALUE
    MARKER_VALUE=$("$READ_CONFIG" checkpoint.marker_file "$REPO_ROOT/workflow-config.conf" 2>/dev/null || true)
    if [[ -n "$MARKER_VALUE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_config_key_exists\n  checkpoint.marker_file not found in workflow-config.conf\n" >&2
    fi
}

test_config_key_exists

# =============================================================================
# TEST E: .checkpoint-pending-rollback is listed in .gitignore
# =============================================================================

test_marker_in_gitignore() {
    if grep -q "checkpoint-pending-rollback" "$REPO_ROOT/.gitignore" 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_marker_in_gitignore\n  checkpoint-pending-rollback not found in .gitignore\n" >&2
    fi
}

test_marker_in_gitignore

# =============================================================================
# TEST F: Dedup lock key is stable across a checkpoint commit (HEAD change)
#   Pre-creates a lock file using only the CWD-based key (the fixed format).
#   With the current (buggy) code the lock key includes HEAD, so the hook
#   ignores the pre-created lock and makes a new commit.
#   With the fix the hook finds the lock and exits early — no new commit.
# =============================================================================

test_dedup_lock_stable_after_head_change() {
    local TEST_DIR TEST_ARTIFACTS
    TEST_DIR=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_DIR")
    TEST_ARTIFACTS=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_ARTIFACTS")

    (
        cd "$TEST_DIR"
        git init -q -b main
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial-test-f" > file.txt
        git add file.txt
        git commit -q -m "initial"
        echo "work-in-progress" > work.py
    ) 2>/dev/null

    # Compute the CWD-based lock key exactly as the fixed hook code does:
    #   _LOCK_PATH=$(pwd -P | shasum -a 256 | head -c 8)  [empty if shasum absent]
    #   _LOCK_KEY="${_LOCK_PATH}"   (no HEAD)
    local LOCK_PATH LOCK_FILE NOW
    LOCK_PATH=$(cd "$TEST_DIR" && pwd -P 2>/dev/null | shasum -a 256 2>/dev/null | head -c 8)
    LOCK_FILE="${TMPDIR:-/tmp}/.precompact-lock-${LOCK_PATH}"

    # Simulate a concurrent first invocation: write the lock file
    NOW=$(date +%s 2>/dev/null || echo 0)
    echo "$NOW" > "$LOCK_FILE"

    local commits_before
    commits_before=$(cd "$TEST_DIR" && git log --oneline 2>/dev/null | wc -l | tr -d ' ')

    # Run the hook — it should detect the lock and exit early (dedup)
    (
        cd "$TEST_DIR"
        export _DEPS_LOADED=1
        get_artifacts_dir() { echo "$TEST_ARTIFACTS"; }
        export -f get_artifacts_dir
        bash "$COMPACT_HOOK" 2>/dev/null
    ) || true

    rm -f "$LOCK_FILE"

    local commits_after
    commits_after=$(cd "$TEST_DIR" && git log --oneline 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$commits_before" -eq "$commits_after" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_dedup_lock_stable_after_head_change\n  Expected %s commits (dedup should fire), got %s\n" \
            "$commits_before" "$commits_after" >&2
    fi

    rm -rf "$TEST_DIR" "$TEST_ARTIFACTS"
}

test_dedup_lock_stable_after_head_change

print_summary
