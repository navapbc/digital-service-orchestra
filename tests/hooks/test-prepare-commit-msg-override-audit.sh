#!/usr/bin/env bash
# tests/hooks/test-prepare-commit-msg-override-audit.sh
# RED tests for plugins/dso/hooks/prepare-commit-msg-override-audit.sh
#
# Tests that the prepare-commit-msg hook:
#   1. Exits 0 and leaves commit msg unchanged when no override.token exists
#   2. Appends 'Override-Reason: <reason>' trailer when override.token has a reason field
#
# These tests are expected to FAIL until T3c implements the hook.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/prepare-commit-msg-override-audit.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
unset _DEPS_LOADED
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Temp dir cleanup on exit
_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── test_no_token_no_trailer ────────────────────────────────────────────────
# When no override.token exists in ARTIFACTS_DIR, the hook should:
#   - exit 0
#   - leave the commit message file unchanged
test_no_token_no_trailer() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    # Create an isolated artifacts dir with no override.token
    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"

    # Create a commit message file
    local commit_msg_file="$tmpdir/COMMIT_EDITMSG"
    printf 'feat: initial commit\n' > "$commit_msg_file"
    local original_content
    original_content=$(cat "$commit_msg_file")

    # Run the hook with the isolated artifacts dir and commit msg file as $1
    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" bash "$HOOK" "$commit_msg_file" 2>/dev/null \
        || exit_code=$?

    assert_eq "test_no_token_no_trailer_exit_code" "0" "$exit_code"

    local final_content
    final_content=$(cat "$commit_msg_file")
    assert_eq "test_no_token_no_trailer_msg_unchanged" "$original_content" "$final_content"
}

# ── test_token_appends_trailer ──────────────────────────────────────────────
# When override.token exists with a reason field, the hook should:
#   - exit 0
#   - append 'Override-Reason: <reason>' as a trailer to the commit msg file ($1)
test_token_appends_trailer() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    # Create an isolated artifacts dir and write override.token with a reason
    local artifacts_dir="$tmpdir/artifacts"
    mkdir -p "$artifacts_dir"
    printf '{"reason":"reviewer unavailable","timestamp":"2026-05-08T00:00:00Z"}\n' \
        > "$artifacts_dir/override.token"

    # Create a commit message file
    local commit_msg_file="$tmpdir/COMMIT_EDITMSG"
    printf 'feat: add new widget\n' > "$commit_msg_file"

    # Run the hook
    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" bash "$HOOK" "$commit_msg_file" 2>/dev/null \
        || exit_code=$?

    assert_eq "test_token_appends_trailer_exit_code" "0" "$exit_code"

    local final_content
    final_content=$(cat "$commit_msg_file")
    assert_contains "test_token_appends_trailer_has_trailer" \
        "Override-Reason: reviewer unavailable" "$final_content"
}

# Run test cases
test_no_token_no_trailer
test_token_appends_trailer

print_summary
