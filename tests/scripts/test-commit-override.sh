#!/usr/bin/env bash
# tests/scripts/test-commit-override.sh
# RED-phase tests for plugins/dso/scripts/commit-override.sh (does not exist yet).
# All tests must FAIL until the implementation is written (T3).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/commit-override.sh"

# ── Isolation: each test gets a fresh artifacts dir ──
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup_tmpdirs EXIT

_make_artifacts_dir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Test 1: test_requires_reason_flag ──
# Given: commit-override.sh is invoked without --reason
# When: the script runs with DSO_FORCE_INTERACTIVE=1 (to bypass TTY check)
# Then: exits with code 1 (missing required argument)
test_requires_reason_flag() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_FORCE_INTERACTIVE=1 \
        bash "$SCRIPT" 2>/dev/null
    exit_code=$?

    assert_eq "requires_reason_flag_exits_1" "1" "$exit_code"
}

# ── Test 2: test_non_interactive_blocked ──
# Given: stdin is not a TTY and DSO_FORCE_INTERACTIVE is unset
# When: commit-override.sh is invoked with a valid --reason
# Then: exits with code 1 (non-interactive execution rejected)
test_non_interactive_blocked() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$SCRIPT" --reason "test override" < /dev/null 2>/dev/null
    exit_code=$?

    assert_eq "non_interactive_blocked_exits_1" "1" "$exit_code"
}

# ── Test 3: test_force_interactive_bypass ──
# Given: DSO_FORCE_INTERACTIVE=1 is set, valid --reason is provided
# When: commit-override.sh is invoked (stdin not TTY)
# Then: exits with code 0 (TTY check bypassed)
test_force_interactive_bypass() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_FORCE_INTERACTIVE=1 \
        bash "$SCRIPT" --reason "test override" < /dev/null 2>/dev/null
    exit_code=$?

    assert_eq "force_interactive_bypass_exits_0" "0" "$exit_code"
}

# ── Test 4: test_autonomous_mode_blocked ──
# Given: DSO_FBKY_AUTONOMOUS_MODE is set to a non-empty value
# When: commit-override.sh is invoked with DSO_FORCE_INTERACTIVE=1 and valid --reason
# Then: exits with code 1 (autonomous mode is explicitly blocked)
test_autonomous_mode_blocked() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_FORCE_INTERACTIVE=1 \
        DSO_FBKY_AUTONOMOUS_MODE=1 \
        bash "$SCRIPT" --reason "test override" < /dev/null 2>/dev/null
    exit_code=$?

    assert_eq "autonomous_mode_blocked_exits_1" "1" "$exit_code"
}

# ── Test 5: test_writes_override_token ──
# Given: DSO_FORCE_INTERACTIVE=1 and valid --reason
# When: commit-override.sh is invoked successfully
# Then: $ARTIFACTS_DIR/override.token is created as valid JSON with required fields:
#       diff_hash, reason, timestamp, attribution
test_writes_override_token() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_FORCE_INTERACTIVE=1 \
        bash "$SCRIPT" --reason "my override reason" < /dev/null 2>/dev/null

    local token_file="$artifacts_dir/override.token"
    local file_exists="no"
    [[ -f "$token_file" ]] && file_exists="yes"
    assert_eq "override_token_file_exists" "yes" "$file_exists"

    local token_content=""
    [[ -f "$token_file" ]] && token_content=$(cat "$token_file")

    # Validate JSON is parseable and contains required fields via python3
    local is_valid_json="no"
    local has_diff_hash="no"
    local has_reason="no"
    local has_timestamp="no"
    local has_attribution="no"

    if [[ -f "$token_file" ]]; then
        is_valid_json=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes')
except Exception:
    print('no')
" "$token_content" 2>/dev/null || echo "no")

        has_diff_hash=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'diff_hash' in data else 'no')
except Exception:
    print('no')
" "$token_content" 2>/dev/null || echo "no")

        has_reason=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'reason' in data else 'no')
except Exception:
    print('no')
" "$token_content" 2>/dev/null || echo "no")

        has_timestamp=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'timestamp' in data else 'no')
except Exception:
    print('no')
" "$token_content" 2>/dev/null || echo "no")

        has_attribution=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print('yes' if 'attribution' in data else 'no')
except Exception:
    print('no')
" "$token_content" 2>/dev/null || echo "no")
    fi

    assert_eq "override_token_is_valid_json" "yes" "$is_valid_json"
    assert_eq "override_token_has_diff_hash" "yes" "$has_diff_hash"
    assert_eq "override_token_has_reason" "yes" "$has_reason"
    assert_eq "override_token_has_timestamp" "yes" "$has_timestamp"
    assert_eq "override_token_has_attribution" "yes" "$has_attribution"
}

# ── Test 6: test_appends_to_log ──
# Given: DSO_FORCE_INTERACTIVE=1 and valid --reason
# When: commit-override.sh is invoked successfully
# Then: a JSON Lines entry is appended to $ARTIFACTS_DIR/commit-overrides.log
test_appends_to_log() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_FORCE_INTERACTIVE=1 \
        bash "$SCRIPT" --reason "logging test reason" < /dev/null 2>/dev/null

    local log_file="$artifacts_dir/commit-overrides.log"
    local log_exists="no"
    [[ -f "$log_file" ]] && log_exists="yes"
    assert_eq "commit_overrides_log_exists" "yes" "$log_exists"

    # Verify the log has at least one valid JSON line
    local log_has_json_entry="no"
    if [[ -f "$log_file" ]]; then
        log_has_json_entry=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        lines = [l.strip() for l in f if l.strip()]
    if lines:
        json.loads(lines[-1])
        print('yes')
    else:
        print('no')
except Exception:
    print('no')
" "$log_file" 2>/dev/null || echo "no")
    fi

    assert_eq "commit_overrides_log_has_json_entry" "yes" "$log_has_json_entry"
}

# ── Test 7: test_token_overwrite_if_exists ──
# Given: override.token already exists from a first invocation
# When: commit-override.sh is invoked a second time with a different --reason
# Then: override.token is overwritten with the new reason (last-writer-wins)
test_token_overwrite_if_exists() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # First invocation
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_FORCE_INTERACTIVE=1 \
        bash "$SCRIPT" --reason "first reason" < /dev/null 2>/dev/null

    # Second invocation with a different reason
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        DSO_FORCE_INTERACTIVE=1 \
        bash "$SCRIPT" --reason "second reason" < /dev/null 2>/dev/null

    local token_file="$artifacts_dir/override.token"
    local token_content=""
    [[ -f "$token_file" ]] && token_content=$(cat "$token_file")

    # The token should contain "second reason", not "first reason"
    local reason_value="none"
    if [[ -f "$token_file" ]]; then
        reason_value=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    print(data.get('reason', 'no_reason_field'))
except Exception:
    print('invalid_json')
" "$token_content" 2>/dev/null || echo "parse_error")
    fi

    assert_eq "token_overwritten_with_second_reason" "second reason" "$reason_value"
}

# ── Run all tests ──
test_requires_reason_flag
test_non_interactive_blocked
test_force_interactive_bypass
test_autonomous_mode_blocked
test_writes_override_token
test_appends_to_log
test_token_overwrite_if_exists

print_summary
