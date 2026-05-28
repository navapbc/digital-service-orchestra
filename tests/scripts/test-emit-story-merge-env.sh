#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # subshell exported-var isolation is intentional
# tests/scripts/test-emit-story-merge-env.sh
# Behavioral RED tests for plugins/dso/scripts/emit-story-merge-env.sh
#
# The helper does not exist yet — all tests are expected to FAIL in RED phase.
#
# Contract:
#   source emit-story-merge-env.sh <story_id>
#   Exports: STORY_ID, STORY_EPIC_ID
#   Returns: 0 on success; non-zero if parent epic cannot be resolved
#   Exits 1 (aborts) if executed directly rather than sourced
#
# Test scenarios:
#   (a) test_sourced_valid_story_exports_vars_and_returns_zero
#   (b) test_sourced_no_parent_returns_nonzero_with_stderr
#   (c) test_executed_directly_exits_1_with_error_message
#   (d) test_sourced_without_story_id_returns_nonzero
#   (e) test_sourced_dso_command_fails_returns_nonzero
#
# Usage: bash tests/scripts/test-emit-story-merge-env.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/plugins/dso/scripts/emit-story-merge-env.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-emit-story-merge-env.sh ==="

# Guard: all tests fail immediately and cleanly if the helper has not been created.
if [[ ! -f "$HELPER" ]]; then
    echo "FAIL: helper not found: $HELPER" >&2
    (( ++FAIL ))
    print_summary
fi

# =============================================================================
# Shared setup helper
# Creates a temp directory with a stubbed .claude/scripts/dso command.
# Caller must set _tmp and optionally override _DSO_STUB_BODY before calling.
# =============================================================================
_make_tmp_with_stub() {
    local stub_body="$1"
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-emit-story-merge-env.XXXXXX")
    mkdir -p "$tmp/.claude/scripts"
    cat > "$tmp/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
${stub_body}
STUB
    chmod +x "$tmp/.claude/scripts/dso"
    echo "$tmp"
}

# =============================================================================
# (a) test_sourced_valid_story_exports_vars_and_returns_zero
#
# Stub: dso ticket show test-story-id --format=llm → emits "parent: 1d8b-0cad-8d19-45ad"
# Source the helper from the temp dir (so relative .claude/scripts/dso resolves).
# Assert: return code 0, STORY_ID == test-story-id, STORY_EPIC_ID == 1d8b-0cad-8d19-45ad
# =============================================================================
echo ""
echo "--- test_sourced_valid_story_exports_vars_and_returns_zero ---"
_snapshot_fail

(
    tmp=$(_make_tmp_with_stub '
case "$*" in
  *"ticket show test-story-id"*) echo "parent: 1d8b-0cad-8d19-45ad" ;;
  *) echo "unexpected stub call: $*" >&2; exit 1 ;;
esac
')
    trap 'rm -rf "$tmp"' EXIT

    cd "$tmp" || return 1
    # Unset any stale vars from the outer env
    unset STORY_ID STORY_EPIC_ID

    rc=0
    source "$HELPER" test-story-id || rc=$?

    assert_eq "return code is 0"          "0"                    "$rc"
    assert_eq "STORY_ID exported"         "test-story-id"        "${STORY_ID:-}"
    assert_eq "STORY_EPIC_ID exported"    "1d8b-0cad-8d19-45ad"  "${STORY_EPIC_ID:-}"
)
assert_pass_if_clean "test_sourced_valid_story_exports_vars_and_returns_zero"

# =============================================================================
# (b) test_sourced_no_parent_returns_nonzero_with_stderr
#
# Stub: dso ticket show no-parent-story → emits output WITHOUT a parent: line.
# Assert: return code != 0, stderr contains "ERROR", STORY_EPIC_ID is empty/unset.
# =============================================================================
echo ""
echo "--- test_sourced_no_parent_returns_nonzero_with_stderr ---"
_snapshot_fail

(
    tmp=$(_make_tmp_with_stub '
case "$*" in
  *"ticket show no-parent-story"*) echo "title: orphan story" ;;
  *) echo "unexpected stub call: $*" >&2; exit 1 ;;
esac
')
    trap 'rm -rf "$tmp"' EXIT

    cd "$tmp" || return 1
    unset STORY_ID STORY_EPIC_ID

    rc=0
    stderr_out=$(source "$HELPER" no-parent-story 2>&1 >/dev/null) || rc=$?

    assert_ne "return code is non-zero"   "0"  "$rc"
    assert_contains "stderr has ERROR"    "ERROR" "$stderr_out"
    assert_eq "STORY_EPIC_ID is unset"   ""  "${STORY_EPIC_ID:-}"
)
assert_pass_if_clean "test_sourced_no_parent_returns_nonzero_with_stderr"

# =============================================================================
# (c) test_executed_directly_exits_1_with_error_message
#
# Run the helper directly via bash (not sourced).
# Assert: exit code 1, stderr contains "must be sourced".
# =============================================================================
echo ""
echo "--- test_executed_directly_exits_1_with_error_message ---"
_snapshot_fail

(
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-emit-story-merge-env.XXXXXX")
    trap 'rm -rf "$tmp"' EXIT

    rc=0
    stderr_out=$(bash "$HELPER" test-story-id 2>&1) || rc=$?

    assert_eq "exit code is 1"             "1"             "$rc"
    assert_contains "stderr has sourced"   "must be sourced" "$stderr_out"
)
assert_pass_if_clean "test_executed_directly_exits_1_with_error_message"

# =============================================================================
# (d) test_sourced_without_story_id_returns_nonzero
#
# Source the helper without passing any argument.
# Assert: return code != 0 (parameter expansion ${1:?} fires).
# =============================================================================
echo ""
echo "--- test_sourced_without_story_id_returns_nonzero ---"
_snapshot_fail

(
    tmp=$(_make_tmp_with_stub '
echo "unexpected stub call: $*" >&2; exit 1
')
    trap 'rm -rf "$tmp"' EXIT

    cd "$tmp" || return 1
    unset STORY_ID STORY_EPIC_ID

    rc=0
    source "$HELPER" 2>/dev/null || rc=$?

    assert_ne "return code is non-zero when no arg" "0" "$rc"
)
assert_pass_if_clean "test_sourced_without_story_id_returns_nonzero"

# =============================================================================
# (e) test_sourced_dso_command_fails_returns_nonzero
#
# Stub: dso exits 1 for all invocations (command failure scenario).
# Assert: return code != 0, STORY_EPIC_ID is unset/empty.
# =============================================================================
echo ""
echo "--- test_sourced_dso_command_fails_returns_nonzero ---"
_snapshot_fail

(
    tmp=$(_make_tmp_with_stub '
echo "dso command error" >&2; exit 1
')
    trap 'rm -rf "$tmp"' EXIT

    cd "$tmp" || return 1
    unset STORY_ID STORY_EPIC_ID

    rc=0
    source "$HELPER" test-story-id 2>/dev/null || rc=$?

    assert_ne "return code is non-zero on dso failure" "0" "$rc"
    assert_eq "STORY_EPIC_ID is unset on dso failure"  ""  "${STORY_EPIC_ID:-}"
)
assert_pass_if_clean "test_sourced_dso_command_fails_returns_nonzero"

print_summary
