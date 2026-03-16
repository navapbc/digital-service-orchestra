#!/usr/bin/env bash
# tests/hooks/test-pre-compact-checkpoint-base.sh
# Tests that pre-compact-checkpoint.sh writes HEAD SHA to
# $ARTIFACTS_DIR/pre-checkpoint-base before creating the checkpoint commit.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/pre-compact-checkpoint.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# --- Setup: create a temp ARTIFACTS_DIR and source deps.sh for get_artifacts_dir ---
# We override get_artifacts_dir so the hook writes to our temp dir.
TEST_ARTIFACTS_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_ARTIFACTS_DIR")

# test_hook_source_contains_pre_checkpoint_base_write
# The hook source must contain a line writing to pre-checkpoint-base
HOOK_SOURCE=$(cat "$HOOK")
assert_contains "test_hook_source_contains_pre_checkpoint_base_write" \
    "pre-checkpoint-base" "$HOOK_SOURCE"

# test_hook_source_uses_git_rev_parse_head
# The hook must use 'git rev-parse HEAD' to get the SHA
assert_contains "test_hook_source_uses_git_rev_parse_head" \
    "git rev-parse HEAD" "$HOOK_SOURCE"

# test_hook_source_writes_to_artifacts_dir
# The hook must write to ARTIFACTS_DIR path
assert_contains "test_hook_source_writes_to_artifacts_dir" \
    "ARTIFACTS_DIR" "$HOOK_SOURCE"

# test_pre_checkpoint_base_written_before_commit
# The write to pre-checkpoint-base must appear BEFORE the git commit line.
# Extract line numbers for both operations.
BASE_WRITE_LINE=$(grep -n 'pre-checkpoint-base' "$HOOK" | head -1 | cut -d: -f1)
COMMIT_LINE=$(grep -n 'git commit' "$HOOK" | head -1 | cut -d: -f1)
if [[ -n "$BASE_WRITE_LINE" && -n "$COMMIT_LINE" ]] && (( BASE_WRITE_LINE < COMMIT_LINE )); then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_pre_checkpoint_base_written_before_commit\n  base_write_line: %s\n  commit_line: %s\n" \
        "${BASE_WRITE_LINE:-not found}" "${COMMIT_LINE:-not found}" >&2
fi

# test_pre_checkpoint_base_contains_40_char_hex_sha
# Run the hook in a real git repo and verify the file content is a 40-char hex SHA.
# We need to use a temp git repo to avoid modifying the real repo.
TEST_GIT_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_GIT_DIR")
(
    cd "$TEST_GIT_DIR"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "test" > file.txt
    git add file.txt
    git commit -q -m "initial"
)

# Create a patched version of the hook that uses our test artifacts dir
# by pre-setting ARTIFACTS_DIR before get_artifacts_dir is called.
# We also need deps.sh to be available.
EXPECTED_SHA=$(cd "$TEST_GIT_DIR" && git rev-parse HEAD)

# Run the hook in the temp git repo context, with deps.sh sourced
# We override get_artifacts_dir to return our test dir
HOOK_OUTPUT=$(
    cd "$TEST_GIT_DIR"
    # Create a shim that overrides get_artifacts_dir
    export _TEST_ARTIFACTS_DIR="$TEST_ARTIFACTS_DIR"
    # Source deps.sh then override get_artifacts_dir, then source the hook
    bash -c '
        # Override get_artifacts_dir before the hook runs
        source "'"$REPO_ROOT"'/hooks/lib/deps.sh"
        get_artifacts_dir() { echo "$_TEST_ARTIFACTS_DIR"; }
        export -f get_artifacts_dir
        # Run the hook (it will source deps.sh but our function override persists
        # only if we source instead of running in a subprocess)
        # Actually, the hook runs git commands, so we need to be in the temp repo
        source "'"$HOOK"'"
    ' 2>/dev/null
) || true

# Check if the file was written
if [[ -f "$TEST_ARTIFACTS_DIR/pre-checkpoint-base" ]]; then
    FILE_CONTENT=$(cat "$TEST_ARTIFACTS_DIR/pre-checkpoint-base")
    # Verify it's a 40-char hex string
    if [[ "$FILE_CONTENT" =~ ^[0-9a-f]{40}$ ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_pre_checkpoint_base_contains_40_char_hex_sha\n  expected: 40-char hex\n  actual: %s\n" "$FILE_CONTENT" >&2
    fi
    # Verify it matches the expected SHA
    assert_eq "test_pre_checkpoint_base_sha_matches_head" "$EXPECTED_SHA" "$FILE_CONTENT"
else
    (( ++FAIL ))
    printf "FAIL: test_pre_checkpoint_base_contains_40_char_hex_sha\n  file not found: %s/pre-checkpoint-base\n" "$TEST_ARTIFACTS_DIR" >&2
    (( ++FAIL ))
    printf "FAIL: test_pre_checkpoint_base_sha_matches_head\n  file not written\n" >&2
fi

# Cleanup
rm -rf "$TEST_ARTIFACTS_DIR" "$TEST_GIT_DIR"

print_summary
