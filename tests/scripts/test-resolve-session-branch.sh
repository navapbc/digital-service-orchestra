#!/usr/bin/env bash
# tests/scripts/test-resolve-session-branch.sh
# RED-phase behavioral tests for plugins/dso/scripts/resolve-session-branch.sh
#
# All tests FAIL until the script is implemented (RED gate confirmed).
#
# The helper resolves SESSION_BRANCH via a 3-step fallback:
#   1. gh pr view --json headRefName  (current PR's head branch)
#   2. gh api repos/{OWNER}/{REPO}/actions/variables/SPRINT_SESSION_ID (repo var)
#   3. Fail with non-zero exit and error message mentioning SPRINT_SESSION_ID
#
# Usage: bash tests/scripts/test-resolve-session-branch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/resolve-session-branch.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-resolve-session-branch.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

MOCK_BIN="$TMPDIR_TEST/bin"
mkdir -p "$MOCK_BIN"

# ── Test 1: script exists ────────────────────────────────────────────────────
# RED: script does not exist yet — assert_eq will FAIL
test_script_exists() {
    local exists
    if [[ -f "$SCRIPT" ]]; then exists="yes"; else exists="no"; fi
    assert_eq "test_script_exists: resolve-session-branch.sh exists" "yes" "$exists"
}

# ── Test 2: step1 — gh pr view success ──────────────────────────────────────
# Mock gh returns a valid headRefName from 'pr view'; script should output it.
test_step1_gh_pr_view_success() {
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*)
    echo '{"headRefName":"story/my-epic/my-story"}'
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local output
    output=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>/dev/null) || true
    assert_eq "test_step1_gh_pr_view_success: outputs headRefName branch" \
        "story/my-epic/my-story" "$output"
}

# ── Test 3: step2 — fallback to SPRINT_SESSION_ID repo variable ─────────────
# Mock gh: 'pr view' fails but 'api .../variables/SPRINT_SESSION_ID' succeeds.
test_step2_fallback_to_sprint_session_id() {
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
case "$*" in
  *"pr view"*)
    exit 1
    ;;
  *"variables/SPRINT_SESSION_ID"*)
    echo '{"value":"worktree-20260515-200444"}'
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local output
    output=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>/dev/null) || true
    assert_eq "test_step2_fallback_to_sprint_session_id: outputs SPRINT_SESSION_ID value" \
        "worktree-20260515-200444" "$output"
}

# ── Test 4: step3 — both gh calls fail → non-zero exit with error ────────────
# Mock gh: both 'pr view' and 'api' fail.
test_step3_fail_with_error() {
    cat > "$MOCK_BIN/gh" << 'MOCKEOF'
#!/usr/bin/env bash
exit 1
MOCKEOF
    chmod +x "$MOCK_BIN/gh"

    local exit_code=0
    local stderr_output
    stderr_output=$(PATH="$MOCK_BIN:$PATH" bash "$SCRIPT" 2>&1 >/dev/null) || exit_code=$?

    # Should exit non-zero
    assert_ne "test_step3_fail_with_error: exits non-zero when both fallbacks fail" \
        "0" "$exit_code"

    # Error message should mention SPRINT_SESSION_ID
    local mentions_sprint_session_id
    if echo "$stderr_output" | grep -q "SPRINT_SESSION_ID"; then
        mentions_sprint_session_id="yes"
    else
        mentions_sprint_session_id="no"
    fi
    assert_eq "test_step3_fail_with_error: error message mentions SPRINT_SESSION_ID" \
        "yes" "$mentions_sprint_session_id"
}

# ── Test 5: executable bit ───────────────────────────────────────────────────
# RED: script does not exist yet — will FAIL
test_executable_bit() {
    local is_executable
    if [[ -x "$SCRIPT" ]]; then is_executable="yes"; else is_executable="no"; fi
    assert_eq "test_executable_bit: script has executable bit set" "yes" "$is_executable"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_script_exists
test_step1_gh_pr_view_success
test_step2_fallback_to_sprint_session_id
test_step3_fail_with_error
test_executable_bit

print_summary
