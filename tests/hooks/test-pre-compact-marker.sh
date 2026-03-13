#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-pre-compact-marker.sh
#
# Tests for the rollback marker written by pre-compact-checkpoint.sh:
#   (a) Marker file is written after a successful checkpoint commit
#   (b) Default marker filename used when config key is absent
#   (c) No marker written on no-op path (no real changes)
#
# Usage: bash lockpick-workflow/tests/hooks/test-pre-compact-marker.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPACT_HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-compact-checkpoint.sh"
DEPS_SH="$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
READ_CONFIG="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# =============================================================================
# TEST A: Marker file is written after checkpoint commit (with real changes)
# =============================================================================

test_marker_written_after_checkpoint_commit() {
    local TEST_DIR
    TEST_DIR=$(mktemp -d)
    local TEST_ARTIFACTS
    TEST_ARTIFACTS=$(mktemp -d)

    (
        cd "$TEST_DIR"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > file.txt
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
# TEST B: Default marker filename used when workflow-config.yaml lacks key
# =============================================================================

test_marker_uses_default_when_config_absent() {
    local TEST_DIR
    TEST_DIR=$(mktemp -d)
    local TEST_ARTIFACTS
    TEST_ARTIFACTS=$(mktemp -d)

    (
        cd "$TEST_DIR"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > file.txt
        git add file.txt
        git commit -q -m "initial"
        # Create a workflow-config.yaml WITHOUT checkpoint.marker_file
        cat > workflow-config.yaml <<'WCEOF'
version: "1.0.0"
stack: python-poetry
WCEOF
        git add workflow-config.yaml
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
    local TEST_ARTIFACTS
    TEST_ARTIFACTS=$(mktemp -d)

    (
        cd "$TEST_DIR"
        git init -q
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
# TEST D: Config key checkpoint.marker_file exists in workflow-config.yaml
# =============================================================================

test_config_key_exists() {
    local MARKER_VALUE
    MARKER_VALUE=$("$READ_CONFIG" checkpoint.marker_file "$REPO_ROOT/workflow-config.yaml" 2>/dev/null || true)
    if [[ -n "$MARKER_VALUE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_config_key_exists\n  checkpoint.marker_file not found in workflow-config.yaml\n" >&2
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

print_summary
