#!/usr/bin/env bash
# tests/scratch/test-measure-token-reduction.sh
# Tests for plugins/dso/scripts/scratch-measure-token-reduction.py config loader.
#
# Testing Mode: RED → GREEN
# Task: 98f0-54cf-8bad-467f (Harness config loader with fixed test epic id)
#
# Test cases:
#   1. (test_check_config_valid_epic)      --check-config with valid epic id → exit 0
#   2. (test_check_config_missing_epic)    --check-config with non-existent epic id → exit non-zero + clear error
#   3. (test_harness_executable)           Harness script is executable
#   4. (test_example_config_exists)        Example config exists at expected path
#
# Usage: bash tests/scratch/test-measure-token-reduction.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

HARNESS="$REPO_ROOT/plugins/dso/scripts/scratch-measure-token-reduction.py"
EXAMPLE_CONFIG="$REPO_ROOT/plugins/dso/scripts/scratch-measure-config.example.yaml"

echo "=== test-measure-token-reduction.sh: config loader ==="

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_FILES=()
_cleanup() {
    for f in "${_CLEANUP_FILES[@]:-}"; do
        [ -n "$f" ] && rm -f "$f"
    done
}
trap _cleanup EXIT

# ── Test 1: --check-config with valid epic id → exit 0 ───────────────────────
test_check_config_valid_epic() {
    local cfg
    cfg=$(mktemp /tmp/measure-config-test-XXXXXX)
    _CLEANUP_FILES+=("$cfg")

    # 98f0-54cf-8bad-467f is the task ticket for this harness — guaranteed to
    # exist while this test runs.
    cat > "$cfg" <<EOF
test_epic_id: "98f0-54cf-8bad-467f"
tokenizer: "tiktoken-cl100k"
pre_head_sha: "abc0000000000000000000000000000000000000"
post_head_sha: "def1111111111111111111111111111111111111"
output_path: "/tmp/measure-test-output.json"
EOF

    local output exit_code
    output=$(python3 "$HARNESS" --config "$cfg" --check-config 2>&1)
    exit_code=$?

    assert_eq "check-config valid epic: exit 0" "0" "$exit_code"
    assert_contains "check-config valid epic: OK message" "OK" "$output"
}

# ── Test 2: --check-config with missing epic id → exit non-zero ──────────────
test_check_config_missing_epic() {
    local cfg
    cfg=$(mktemp /tmp/measure-config-test-XXXXXX)
    _CLEANUP_FILES+=("$cfg")

    # Use a clearly bogus ticket id that will never exist.
    cat > "$cfg" <<EOF
test_epic_id: "0000-0000-0000-0000"
tokenizer: "tiktoken-cl100k"
pre_head_sha: "abc0000000000000000000000000000000000000"
post_head_sha: "def1111111111111111111111111111111111111"
output_path: "/tmp/measure-test-output.json"
EOF

    local stderr_out exit_code
    stderr_out=$(python3 "$HARNESS" --config "$cfg" --check-config 2>&1)
    exit_code=$?

    # Must exit non-zero
    local non_zero=1
    if [ "$exit_code" -ne 0 ]; then
        non_zero=0
    fi
    assert_eq "check-config missing epic: exit non-zero" "0" "$non_zero"
    assert_contains "check-config missing epic: error message mentions ticket id" \
        "0000-0000-0000-0000" "$stderr_out"
}

# ── Test 3: harness script is executable ─────────────────────────────────────
test_harness_executable() {
    local result=1
    test -x "$HARNESS" && result=0
    assert_eq "harness executable" "0" "$result"
}

# ── Test 4: example config exists at expected path ───────────────────────────
test_example_config_exists() {
    local result=1
    test -f "$EXAMPLE_CONFIG" && result=0
    assert_eq "example config exists" "0" "$result"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_harness_executable
test_example_config_exists
test_check_config_valid_epic
test_check_config_missing_epic

print_summary
