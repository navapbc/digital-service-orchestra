#!/usr/bin/env bash
# tests/scripts/test-flag-deprecation-check.sh
# RED:d08e-314c-5528-4140 — test suite for plugins/dso/scripts/flag-deprecation-check.sh
#
# Tests the flag-mint pathway: new is_*_enabled() functions added in a diff
# require a corresponding deprecation plan document before they can be created.
#
# Test cases:
#   test_no_new_flags_exits_0            — diff with no new flag additions → exits 0
#   test_new_flag_with_valid_plan_exits_0 — new flag + valid plan doc → exits 0
#   test_new_flag_missing_plan_exits_1   — new flag without plan doc → exits 1
#   test_new_flag_plan_missing_field_exits_1 — new flag + plan missing replacement_key → exits 1
#
# Usage: bash tests/scripts/test-flag-deprecation-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

SUT="$REPO_ROOT/plugins/dso/scripts/flag-deprecation-check.sh"

echo "=== test-flag-deprecation-check.sh ==="

# ── Helpers ───────────────────────────────────────────────────────────────────

# _run_sut_with_diff <diff_content> [extra_args...]
# Pipes diff_content to the SUT and returns its exit code.
_run_sut_with_diff() {
    local diff_content="$1"
    shift
    local exit_code=0
    echo "$diff_content" | REPO_ROOT="$REPO_ROOT" bash "$SUT" "$@" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# _run_sut_with_file <diff_file> [extra_args...]
# Passes diff via --diff-file argument and returns the exit code.
_run_sut_with_file() {
    local diff_file="$1"
    shift
    local exit_code=0
    REPO_ROOT="$REPO_ROOT" bash "$SUT" --diff-file "$diff_file" "$@" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ── Test 1: No new flag additions → exits 0 ───────────────────────────────────

test_no_new_flags_exits_0() {
    _snapshot_fail

    local diff_content
    diff_content=$(cat <<'DIFF'
diff --git a/some_file.sh b/some_file.sh
--- a/some_file.sh
+++ b/some_file.sh
@@ -1,3 +1,4 @@
 # existing content
+echo "no new flags here"
+# is_external_dep_block_enabled is already tracked
 exit 0
DIFF
)

    local exit_code
    exit_code=$(_run_sut_with_diff "$diff_content")
    assert_eq "test_no_new_flags_exits_0: should exit 0 when no new flags in diff" "0" "$exit_code"

    assert_pass_if_clean "test_no_new_flags_exits_0"
}

# ── Test 2: New flag with valid deprecation plan → exits 0 ───────────────────

test_new_flag_with_valid_plan_exits_0() {
    _snapshot_fail

    # Create a temporary deprecation plan with all required fields
    local tmp_plan_dir
    tmp_plan_dir="$(mktemp -d)"
    mkdir -p "$tmp_plan_dir/docs/flag-deprecation-plans"

    local plan_file="$tmp_plan_dir/docs/flag-deprecation-plans/is_my_flag_enabled.md"
    cat > "$plan_file" <<'PLAN'
# Deprecation Plan: is_my_flag_enabled

plan_date: 2026-06-01
owner: joe.oakhart@example.com
replacement_key: my_feature.enabled

This flag controls the legacy my_feature toggle.
It will be replaced by the config key my_feature.enabled.
PLAN

    local diff_content
    diff_content=$(cat <<'DIFF'
diff --git a/plugins/dso/hooks/lib/my-config.sh b/plugins/dso/hooks/lib/my-config.sh
--- /dev/null
+++ b/plugins/dso/hooks/lib/my-config.sh
@@ -0,0 +1,5 @@
+#!/usr/bin/env bash
+is_my_flag_enabled() {
+    local _val
+    [[ "$_val" == "true" ]]
+}
DIFF
)

    local diff_file
    diff_file="$(mktemp "${TMPDIR:-/tmp}/test-flag-check.XXXXXX")"
    echo "$diff_content" > "$diff_file"

    local exit_code
    exit_code=$(_run_sut_with_file "$diff_file" --plan-dir "$tmp_plan_dir/docs/flag-deprecation-plans")
    assert_eq "test_new_flag_with_valid_plan_exits_0: should exit 0 when valid plan exists" "0" "$exit_code"

    rm -f "$diff_file"
    rm -rf "$tmp_plan_dir"

    assert_pass_if_clean "test_new_flag_with_valid_plan_exits_0"
}

# ── Test 3: New flag without deprecation plan → exits 1 ──────────────────────

test_new_flag_missing_plan_exits_1() {
    _snapshot_fail

    # Use a non-existent plan dir so no plan can be found
    local tmp_plan_dir
    tmp_plan_dir="$(mktemp -d)"
    mkdir -p "$tmp_plan_dir/docs/flag-deprecation-plans"
    # Intentionally leave the dir empty (no plan for is_another_flag_enabled)

    local diff_content
    diff_content=$(cat <<'DIFF'
diff --git a/plugins/dso/hooks/lib/another-config.sh b/plugins/dso/hooks/lib/another-config.sh
--- /dev/null
+++ b/plugins/dso/hooks/lib/another-config.sh
@@ -0,0 +1,4 @@
+#!/usr/bin/env bash
+is_another_flag_enabled() {
+    [[ "$1" == "true" ]]
+}
DIFF
)

    local exit_code
    exit_code=$(_run_sut_with_diff "$diff_content" --plan-dir "$tmp_plan_dir/docs/flag-deprecation-plans")
    assert_eq "test_new_flag_missing_plan_exits_1: should exit 1 when no deprecation plan" "1" "$exit_code"

    # Verify JSON error is emitted on stderr
    local stderr_out
    stderr_out=$({ echo "$diff_content" | REPO_ROOT="$REPO_ROOT" bash "$SUT" \
        --plan-dir "$tmp_plan_dir/docs/flag-deprecation-plans" > /dev/null; } 2>&1 || true)
    assert_contains "test_new_flag_missing_plan_exits_1: stderr should contain missing_deprecation_plan" \
        "missing_deprecation_plan" "$stderr_out"
    assert_contains "test_new_flag_missing_plan_exits_1: stderr should name the flag" \
        "is_another_flag_enabled" "$stderr_out"

    rm -rf "$tmp_plan_dir"

    assert_pass_if_clean "test_new_flag_missing_plan_exits_1"
}

# ── Test 4: New flag with plan missing replacement_key → exits 1 ─────────────

test_new_flag_plan_missing_field_exits_1() {
    _snapshot_fail

    # Create a plan that has plan_date and owner but NOT replacement_key
    local tmp_plan_dir
    tmp_plan_dir="$(mktemp -d)"
    mkdir -p "$tmp_plan_dir/docs/flag-deprecation-plans"

    local plan_file="$tmp_plan_dir/docs/flag-deprecation-plans/is_incomplete_flag_enabled.md"
    cat > "$plan_file" <<'PLAN'
# Deprecation Plan: is_incomplete_flag_enabled

plan_date: 2026-07-01
owner: someone@example.com

This plan intentionally omits replacement_key to test validation.
PLAN

    local diff_content
    diff_content=$(cat <<'DIFF'
diff --git a/plugins/dso/hooks/lib/incomplete-config.sh b/plugins/dso/hooks/lib/incomplete-config.sh
--- /dev/null
+++ b/plugins/dso/hooks/lib/incomplete-config.sh
@@ -0,0 +1,4 @@
+#!/usr/bin/env bash
+is_incomplete_flag_enabled() {
+    [[ "$1" == "true" ]]
+}
DIFF
)

    local diff_file
    diff_file="$(mktemp "${TMPDIR:-/tmp}/test-flag-check.XXXXXX")"
    echo "$diff_content" > "$diff_file"

    local exit_code
    exit_code=$(_run_sut_with_file "$diff_file" --plan-dir "$tmp_plan_dir/docs/flag-deprecation-plans")
    assert_eq "test_new_flag_plan_missing_field_exits_1: should exit 1 when plan missing replacement_key" "1" "$exit_code"

    # Verify the error JSON names the reason as invalid_deprecation_plan
    local stderr_out
    stderr_out=$({ REPO_ROOT="$REPO_ROOT" bash "$SUT" \
        --diff-file "$diff_file" \
        --plan-dir "$tmp_plan_dir/docs/flag-deprecation-plans" > /dev/null; } 2>&1 || true)
    assert_contains "test_new_flag_plan_missing_field_exits_1: stderr should indicate invalid plan" \
        "replacement_key" "$stderr_out"

    rm -f "$diff_file"
    rm -rf "$tmp_plan_dir"

    assert_pass_if_clean "test_new_flag_plan_missing_field_exits_1"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_no_new_flags_exits_0
test_new_flag_with_valid_plan_exits_0
test_new_flag_missing_plan_exits_1
test_new_flag_plan_missing_field_exits_1

print_summary
