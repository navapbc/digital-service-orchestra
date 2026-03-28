#!/usr/bin/env bash
# tests/hooks/test-review-complexity-classifier.sh
# RED tests for review-complexity-classifier.sh (dso-qxyd)
#
# Tests the deterministic complexity classifier that scores diffs on 7 factors
# and routes to light/standard/deep review tiers.
#
# All tests are RED — the classifier script does not exist yet.
# They will turn GREEN when dso-qzn4 implements review-complexity-classifier.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

CLASSIFIER="$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh"
ALLOWLIST="$REPO_ROOT/plugins/dso/hooks/lib/review-gate-allowlist.conf"
CONFIG="$REPO_ROOT/.claude/dso-config.conf"

# --- Helpers ---

setup_temp_dir() {
    TEST_TMPDIR="$(mktemp -d)"
    export ARTIFACTS_DIR="$TEST_TMPDIR/artifacts"
    mkdir -p "$ARTIFACTS_DIR"
}

teardown_temp_dir() {
    [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# Create a minimal git diff fixture in TEST_TMPDIR
# Usage: create_diff_fixture "filename" "diff_content"
create_diff_fixture() {
    local filename="$1"
    local content="$2"
    local diff_file="$TEST_TMPDIR/test.diff"
    cat > "$diff_file" <<DIFFEOF
diff --git a/$filename b/$filename
index 0000000..1111111 100644
--- a/$filename
+++ b/$filename
@@ -1,3 +1,5 @@
$content
DIFFEOF
    echo "$diff_file"
}

# Run the classifier with a diff file and capture output + exit code
# Usage: run_classifier diff_file
# Sets: CLASSIFIER_OUTPUT, CLASSIFIER_EXIT
run_classifier() {
    local diff_file="$1"
    CLASSIFIER_OUTPUT=""
    CLASSIFIER_EXIT=0
    if [[ -x "$CLASSIFIER" ]]; then
        CLASSIFIER_OUTPUT=$(bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || CLASSIFIER_EXIT=$?
    else
        # Classifier doesn't exist — simulate failure for RED tests
        CLASSIFIER_EXIT=127
    fi
}

# Extract a JSON field value using python3 (no jq dependency)
# Usage: json_field "key" "$json_string"
json_field() {
    local key="$1" json="$2"
    python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('$key',''))" "$json" 2>/dev/null || echo ""
}

# Check if string is valid JSON
is_valid_json() {
    python3 -c "import json,sys; json.loads(sys.argv[1])" "$1" 2>/dev/null
}

# ============================================================
# Output Schema Tests
# ============================================================

test_classifier_outputs_json_object() {
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        assert_eq "classifier outputs valid JSON" "true" "true"
    else
        assert_eq "classifier outputs valid JSON" "true" "false"
    fi
    teardown_temp_dir
}

test_classifier_exits_zero_on_success() {
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    assert_eq "classifier exits 0 on success" "0" "$CLASSIFIER_EXIT"
    teardown_temp_dir
}

test_classifier_outputs_all_seven_factor_keys() {
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local all_present="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        local has_all
        has_all=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
keys=['blast_radius','critical_path','anti_shortcut','staleness','cross_cutting','diff_lines','change_volume']
print('true' if all(k in d for k in keys) else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
        all_present="$has_all"
    fi
    assert_eq "all 7 factor keys present" "true" "$all_present"
    teardown_temp_dir
}

test_classifier_outputs_computed_total() {
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local has_total="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        has_total=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print('true' if 'computed_total' in d and isinstance(d['computed_total'],int) else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
    fi
    assert_eq "computed_total field present (integer)" "true" "$has_total"
    teardown_temp_dir
}

test_classifier_outputs_selected_tier() {
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local has_tier="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        has_tier=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print('true' if d.get('selected_tier') in ('light','standard','deep') else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
    fi
    assert_eq "selected_tier field present (light|standard|deep)" "true" "$has_tier"
    teardown_temp_dir
}

# ============================================================
# Tier Threshold Tests
# ============================================================

test_classifier_tier_light_score_0_2() {
    # A trivial single-line change to a non-critical file should score 0-2 → light
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "README.md" "+typo fix")
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "score 0-2 selects light tier" "light" "$tier"
    teardown_temp_dir
}

test_classifier_tier_standard_score_3_6() {
    # A change touching auth/security (critical_path floor rule) should force at least standard
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/auth/login.py" "+def authenticate(user): pass")
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    # critical_path floor forces minimum score 3 → standard
    local is_standard_or_deep="false"
    if [[ "$tier" == "standard" || "$tier" == "deep" ]]; then
        is_standard_or_deep="true"
    fi
    assert_eq "score 3-6 selects standard tier (or higher)" "true" "$is_standard_or_deep"
    teardown_temp_dir
}

test_classifier_tier_deep_score_7_plus() {
    # A large cross-cutting change touching many directories, critical paths, with shortcuts
    setup_temp_dir
    local diff_file="$TEST_TMPDIR/test.diff"
    # Construct a diff that should score 7+ across multiple factors
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/auth/login.py b/src/auth/login.py
index 0000000..1111111 100644
--- a/src/auth/login.py
+++ b/src/auth/login.py
@@ -1,3 +1,50 @@
+# noqa: E501
+def authenticate(user):
+    try:
+        pass
+    except Exception:
+        pass
diff --git a/src/models/user.py b/src/models/user.py
index 0000000..1111111 100644
--- a/src/models/user.py
+++ b/src/models/user.py
@@ -1,3 +1,30 @@
+class User:
+    pass
diff --git a/plugins/dso/skills/review.md b/plugins/dso/skills/review.md
index 0000000..1111111 100644
--- a/plugins/dso/skills/review.md
+++ b/plugins/dso/skills/review.md
@@ -1,3 +1,20 @@
+# Updated review skill content
diff --git a/lib/utils/helpers.py b/lib/utils/helpers.py
index 0000000..1111111 100644
--- a/lib/utils/helpers.py
+++ b/lib/utils/helpers.py
@@ -1,3 +1,15 @@
+def helper(): pass
DIFFEOF
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "score 7+ selects deep tier" "deep" "$tier"
    teardown_temp_dir
}

# ============================================================
# Floor Rule Tests
# ============================================================

test_floor_rule_anti_shortcut_forces_standard() {
    # A diff containing noqa comment should force minimum standard tier
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+x = 1  # noqa: E501")
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    local is_at_least_standard="false"
    if [[ "$tier" == "standard" || "$tier" == "deep" ]]; then
        is_at_least_standard="true"
    fi
    assert_eq "anti-shortcut (noqa) forces minimum standard" "true" "$is_at_least_standard"
    teardown_temp_dir
}

test_floor_rule_critical_path_forces_standard() {
    # A diff touching an auth/security file should force minimum standard tier
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/auth/handler.py" "+pass")
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    local is_at_least_standard="false"
    if [[ "$tier" == "standard" || "$tier" == "deep" ]]; then
        is_at_least_standard="true"
    fi
    assert_eq "critical-path file forces minimum standard" "true" "$is_at_least_standard"
    teardown_temp_dir
}

test_floor_rule_safeguard_file_forces_standard() {
    # A diff touching CLAUDE.md should force minimum standard tier
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "CLAUDE.md" "+## New rule")
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    local is_at_least_standard="false"
    if [[ "$tier" == "standard" || "$tier" == "deep" ]]; then
        is_at_least_standard="true"
    fi
    assert_eq "safeguard file (CLAUDE.md) forces minimum standard" "true" "$is_at_least_standard"
    teardown_temp_dir
}

test_floor_rule_test_deletion_forces_standard() {
    # Deleting a test file without corresponding source deletion should force standard
    setup_temp_dir
    local diff_file="$TEST_TMPDIR/test.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/tests/test_foo.py b/tests/test_foo.py
deleted file mode 100644
index 1111111..0000000
--- a/tests/test_foo.py
+++ /dev/null
@@ -1,10 +0,0 @@
-def test_foo():
-    assert True
DIFFEOF
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    local is_at_least_standard="false"
    if [[ "$tier" == "standard" || "$tier" == "deep" ]]; then
        is_at_least_standard="true"
    fi
    assert_eq "test deletion without source deletion forces minimum standard" "true" "$is_at_least_standard"
    teardown_temp_dir
}

test_floor_rule_exception_broadening_forces_standard() {
    # A diff with 'catch Exception' or 'except Exception' should force standard
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/handler.py" "+    except Exception:\n+        pass")
    run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    local is_at_least_standard="false"
    if [[ "$tier" == "standard" || "$tier" == "deep" ]]; then
        is_at_least_standard="true"
    fi
    assert_eq "exception broadening forces minimum standard" "true" "$is_at_least_standard"
    teardown_temp_dir
}

# ============================================================
# Behavioral File Detection Tests
# ============================================================

test_behavioral_file_gets_full_scoring_weight() {
    # A behavioral file (matching review.behavioral_patterns) should get full scoring weight
    # i.e., it should count toward change_volume and other factors just like source code
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "plugins/dso/skills/foo.md" "+# Updated skill instructions")
    run_classifier "$diff_file"

    local change_volume=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        change_volume=$(json_field "change_volume" "$CLASSIFIER_OUTPUT")
    fi
    # A behavioral file should contribute to change_volume (score >= 1)
    local has_weight="false"
    if [[ -n "$change_volume" && "$change_volume" -ge 1 ]] 2>/dev/null; then
        has_weight="true"
    fi
    assert_eq "behavioral file gets full scoring weight (change_volume >= 1)" "true" "$has_weight"
    teardown_temp_dir
}

test_allowlist_file_exempt_from_scoring() {
    # A file matching review-gate-allowlist.conf should score 0 across all factors
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture ".tickets/dso-abc1.md" "+status: closed")
    run_classifier "$diff_file"

    local total=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        total=$(json_field "computed_total" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "allowlist-exempt file scores 0" "0" "$total"
    teardown_temp_dir
}

# ============================================================
# Performance Test
# ============================================================

test_classifier_completes_in_under_2s() {
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")

    local start_time end_time elapsed
    start_time=$(python3 -c "import time; print(time.time())")

    run_classifier "$diff_file"

    end_time=$(python3 -c "import time; print(time.time())")
    elapsed=$(python3 -c "print(float($end_time) - float($start_time))")

    local under_2s="false"
    under_2s=$(python3 -c "print('true' if $elapsed < 2.0 else 'false')")

    # When classifier doesn't exist, it "completes" instantly (exit 127).
    # This test is meaningful once the classifier is implemented.
    if [[ "$CLASSIFIER_EXIT" -eq 127 ]]; then
        # Classifier missing — cannot validate performance, mark as fail
        assert_eq "classifier completes in under 2s (classifier missing)" "true" "false"
    else
        assert_eq "classifier completes in under 2s (${elapsed}s)" "true" "$under_2s"
    fi
    teardown_temp_dir
}

# ============================================================
# Failure Handling Tests
# ============================================================

test_classifier_failure_defaults_to_standard() {
    # Per the contract: if classifier exits non-zero, parser must default to standard tier.
    # This test validates that a broken/missing classifier results in standard being the safe default.
    # The classifier itself doesn't need to output "standard" on failure — the PARSER does.
    # But the classifier contract says exit non-zero → parser defaults to standard.
    # We test that the classifier exits non-zero when given invalid input (or doesn't exist).
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")

    if [[ ! -x "$CLASSIFIER" ]]; then
        # Classifier missing — confirm it would fail (RED test)
        assert_eq "classifier failure detected (script missing)" "true" "false"
    else
        # Force a failure scenario: pipe empty stdin
        local exit_code=0
        local output
        output=$(echo "" | bash "$CLASSIFIER" --invalid-flag 2>/dev/null) || exit_code=$?
        if [[ "$exit_code" -ne 0 ]]; then
            assert_eq "classifier exits non-zero on failure" "true" "true"
        else
            assert_eq "classifier exits non-zero on failure" "true" "false"
        fi
    fi
    teardown_temp_dir
}

test_classifier_stdout_parseable_on_success() {
    # When classifier exits 0, stdout must be valid JSON
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    if [[ "$CLASSIFIER_EXIT" -eq 0 ]]; then
        if is_valid_json "$CLASSIFIER_OUTPUT"; then
            assert_eq "stdout is valid JSON on exit 0" "true" "true"
        else
            assert_eq "stdout is valid JSON on exit 0" "true" "false"
        fi
    else
        # Classifier failed or missing — this is expected in RED state
        assert_eq "classifier exits 0 (required for parseable output test)" "0" "$CLASSIFIER_EXIT"
    fi
    teardown_temp_dir
}

# ============================================================
# Run All Tests
# ============================================================

# Output schema
test_classifier_outputs_json_object
test_classifier_exits_zero_on_success
test_classifier_outputs_all_seven_factor_keys
test_classifier_outputs_computed_total
test_classifier_outputs_selected_tier

# Tier thresholds
test_classifier_tier_light_score_0_2
test_classifier_tier_standard_score_3_6
test_classifier_tier_deep_score_7_plus

# Floor rules
test_floor_rule_anti_shortcut_forces_standard
test_floor_rule_critical_path_forces_standard
test_floor_rule_safeguard_file_forces_standard
test_floor_rule_test_deletion_forces_standard
test_floor_rule_exception_broadening_forces_standard

# Behavioral file detection
test_behavioral_file_gets_full_scoring_weight
test_allowlist_file_exempt_from_scoring

# Performance
test_classifier_completes_in_under_2s

# Failure handling
test_classifier_failure_defaults_to_standard
test_classifier_stdout_parseable_on_success

# ============================================================
# Diff Size Threshold and Merge Commit Detection Tests (RED — w22-pccy)
# ============================================================

# Helper: create a diff with N added non-test source lines
create_n_line_diff() {
    local n="$1"
    local filename="${2:-src/foo.py}"
    local diff_file="$TEST_TMPDIR/test_n_lines.diff"
    {
        echo "diff --git a/${filename} b/${filename}"
        echo "index 0000000..1111111 100644"
        echo "--- a/${filename}"
        echo "+++ b/${filename}"
        echo "@@ -1,1 +1,${n} @@"
        local i
        for (( i = 1; i <= n; i++ )); do
            echo "+line_${i} = ${i}"
        done
    } > "$diff_file"
    echo "$diff_file"
}

test_classifier_diff_size_lines_raw_count() {
    # Assert diff_size_lines field exists, is integer >= 0, and equals 50 for 50-line diff
    setup_temp_dir
    local diff_file
    diff_file=$(create_n_line_diff 50 "src/foo.py")
    run_classifier "$diff_file"

    local has_field="false"
    local value_correct="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        has_field=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print('true' if 'diff_size_lines' in d and isinstance(d['diff_size_lines'],int) and d['diff_size_lines'] >= 0 else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
        value_correct=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print('true' if d.get('diff_size_lines') == 50 else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
    fi
    assert_eq "diff_size_lines field exists and is integer >= 0" "true" "$has_field"
    assert_eq "diff_size_lines equals 50 for 50-line diff" "true" "$value_correct"
    teardown_temp_dir
}

test_classifier_size_action_none_below_300() {
    # 10 scorable lines → size_action = "none"
    setup_temp_dir
    local diff_file
    diff_file=$(create_n_line_diff 10 "src/foo.py")
    run_classifier "$diff_file"

    local size_action=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        size_action=$(json_field "size_action" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "10-line diff has size_action=none" "none" "$size_action"
    teardown_temp_dir
}

test_classifier_size_action_upgrade_at_300() {
    # 300 scorable added lines → size_action = "upgrade"
    setup_temp_dir
    local diff_file
    diff_file=$(create_n_line_diff 300 "src/foo.py")
    run_classifier "$diff_file"

    local size_action=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        size_action=$(json_field "size_action" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "300-line diff has size_action=upgrade" "upgrade" "$size_action"
    teardown_temp_dir
}

test_classifier_size_action_reject_at_600() {
    # 600+ scorable added lines → size_action = "reject"
    setup_temp_dir
    local diff_file
    diff_file=$(create_n_line_diff 600 "src/foo.py")
    run_classifier "$diff_file"

    local size_action=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        size_action=$(json_field "size_action" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "600-line diff has size_action=reject" "reject" "$size_action"
    teardown_temp_dir
}

test_classifier_size_action_none_for_test_only_diff() {
    # Diff touching only test files → size_action = "none" regardless of line count
    setup_temp_dir
    local diff_file
    diff_file=$(create_n_line_diff 400 "tests/test_foo.py")
    run_classifier "$diff_file"

    local size_action=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        size_action=$(json_field "size_action" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "test-only diff (400 lines) has size_action=none" "none" "$size_action"
    teardown_temp_dir
}

test_classifier_size_action_none_for_generated_files() {
    # Diff touching only migration/lock files → size_action = "none"
    setup_temp_dir
    local diff_file
    diff_file=$(create_n_line_diff 400 "poetry.lock")
    run_classifier "$diff_file"

    local size_action=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        size_action=$(json_field "size_action" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "generated-file-only diff (poetry.lock, 400 lines) has size_action=none" "none" "$size_action"
    teardown_temp_dir
}

test_classifier_is_merge_commit_false_default() {
    # Normal diff (no MOCK_MERGE_HEAD) → is_merge_commit = false
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    unset MOCK_MERGE_HEAD 2>/dev/null || true
    run_classifier "$diff_file"

    local is_merge="true"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        is_merge=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
v=d.get('is_merge_commit',True)
print(str(v).lower() if isinstance(v,bool) else str(v))
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "true")
    fi
    assert_eq "normal diff has is_merge_commit=false" "false" "$is_merge"
    teardown_temp_dir
}

test_classifier_is_merge_commit_size_action_none() {
    # When MOCK_MERGE_HEAD=1, size_action = "none" even with 600+ lines
    setup_temp_dir
    local diff_file
    diff_file=$(create_n_line_diff 600 "src/foo.py")
    MOCK_MERGE_HEAD=1 run_classifier "$diff_file"

    local size_action=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        size_action=$(json_field "size_action" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "merge commit (MOCK_MERGE_HEAD=1) with 600 lines has size_action=none" "none" "$size_action"
    teardown_temp_dir
}

test_classifier_output_includes_new_fields() {
    # Verify JSON output contains diff_size_lines, size_action, and is_merge_commit keys
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local has_new_fields="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        has_new_fields=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
keys=['diff_size_lines','size_action','is_merge_commit']
print('true' if all(k in d for k in keys) else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
    fi
    assert_eq "JSON output includes diff_size_lines, size_action, is_merge_commit" "true" "$has_new_fields"
    teardown_temp_dir
}

# Diff size thresholds and merge commit detection (RED — w22-pccy)
test_classifier_diff_size_lines_raw_count  # RED: diff_size_lines field not yet implemented
test_classifier_size_action_none_below_300  # RED: size_action field not yet implemented
test_classifier_size_action_upgrade_at_300  # RED: size_action field not yet implemented
test_classifier_size_action_reject_at_600  # RED: size_action field not yet implemented
test_classifier_size_action_none_for_test_only_diff  # RED: size_action bypass not yet implemented
test_classifier_size_action_none_for_generated_files  # RED: size_action bypass not yet implemented
test_classifier_is_merge_commit_false_default  # RED: is_merge_commit field not yet implemented
test_classifier_is_merge_commit_size_action_none  # RED: merge commit bypass not yet implemented
test_classifier_output_includes_new_fields  # RED: new fields not yet in output schema

# ============================================================
# Telemetry tests (RED — w21-0kt1)
# ============================================================

test_classifier_telemetry_file_created() {
    # When ARTIFACTS_DIR is set, classifier must create classifier-telemetry.jsonl
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local file_exists="false"
    if [[ -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl" ]]; then
        file_exists="true"
    fi
    assert_eq "classifier-telemetry.jsonl created when ARTIFACTS_DIR set" "true" "$file_exists"
    teardown_temp_dir
}

test_classifier_telemetry_entry_is_valid_json() {
    # The telemetry file must contain at least one valid JSON line
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local is_valid="false"
    if [[ -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl" ]]; then
        local last_line
        last_line=$(tail -1 "$ARTIFACTS_DIR/classifier-telemetry.jsonl" 2>/dev/null || echo "")
        if [[ -n "$last_line" ]] && is_valid_json "$last_line"; then
            is_valid="true"
        fi
    fi
    assert_eq "telemetry entry is valid JSON" "true" "$is_valid"
    teardown_temp_dir
}

test_classifier_telemetry_contains_required_fields() {
    # Telemetry entry must contain all 13 required fields:
    # blast_radius, critical_path, anti_shortcut, staleness, cross_cutting,
    # diff_lines, change_volume, computed_total, selected_tier,
    # files, diff_size_lines, size_action, is_merge_commit
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local has_all="false"
    if [[ -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl" ]]; then
        local last_line
        last_line=$(tail -1 "$ARTIFACTS_DIR/classifier-telemetry.jsonl" 2>/dev/null || echo "")
        if [[ -n "$last_line" ]]; then
            has_all=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
keys=['blast_radius','critical_path','anti_shortcut','staleness','cross_cutting',
      'diff_lines','change_volume','computed_total','selected_tier',
      'files','diff_size_lines','size_action','is_merge_commit']
print('true' if all(k in d for k in keys) else 'false')
" "$last_line" 2>/dev/null || echo "false")
        fi
    fi
    assert_eq "telemetry contains all 13 required fields" "true" "$has_all"
    teardown_temp_dir
}

test_classifier_telemetry_factor_scores_match_stdout() {
    # Factor scores in telemetry must match those on stdout (no divergence)
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
    run_classifier "$diff_file"

    local scores_match="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT" && \
       [[ -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl" ]]; then
        local last_line
        last_line=$(tail -1 "$ARTIFACTS_DIR/classifier-telemetry.jsonl" 2>/dev/null || echo "")
        if [[ -n "$last_line" ]] && is_valid_json "$last_line"; then
            scores_match=$(python3 -c "
import json,sys
stdout=json.loads(sys.argv[1])
telemetry=json.loads(sys.argv[2])
factor_keys=['blast_radius','critical_path','anti_shortcut','staleness',
             'cross_cutting','diff_lines','change_volume','computed_total','selected_tier']
print('true' if all(stdout.get(k)==telemetry.get(k) for k in factor_keys) else 'false')
" "$CLASSIFIER_OUTPUT" "$last_line" 2>/dev/null || echo "false")
        fi
    fi
    assert_eq "telemetry factor scores match stdout" "true" "$scores_match"
    teardown_temp_dir
}

test_classifier_telemetry_files_array() {
    # Telemetry 'files' field must be a JSON array of scored file paths
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/bar.py" "+x = 1")
    run_classifier "$diff_file"

    local files_ok="false"
    if [[ -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl" ]]; then
        local last_line
        last_line=$(tail -1 "$ARTIFACTS_DIR/classifier-telemetry.jsonl" 2>/dev/null || echo "")
        if [[ -n "$last_line" ]]; then
            files_ok=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
files=d.get('files')
# Must be a list; scoring file src/bar.py must appear in it
print('true' if isinstance(files,list) and any('src/bar.py' in f for f in files) else 'false')
" "$last_line" 2>/dev/null || echo "false")
        fi
    fi
    assert_eq "telemetry files field is array containing scored files" "true" "$files_ok"
    teardown_temp_dir
}

test_classifier_no_telemetry_without_artifacts_dir() {
    # When ARTIFACTS_DIR is unset, no telemetry file should be written anywhere
    local prev_artifacts="${ARTIFACTS_DIR:-}"
    unset ARTIFACTS_DIR

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local diff_file="$tmp_dir/test.diff"
    cat > "$diff_file" <<DIFFEOF
diff --git a/src/foo.py b/src/foo.py
index 0000000..1111111 100644
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,1 +1,2 @@
+print('hello')
DIFFEOF

    local output exit_code=0
    output=$(bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || exit_code=$?

    # No telemetry file should be created in $tmp_dir (it was never set as ARTIFACTS_DIR)
    local no_telemetry="true"
    if [[ -f "$tmp_dir/classifier-telemetry.jsonl" ]]; then
        no_telemetry="false"
    fi
    assert_eq "no telemetry file written when ARTIFACTS_DIR unset" "true" "$no_telemetry"

    rm -rf "$tmp_dir"
    if [[ -n "$prev_artifacts" ]]; then
        export ARTIFACTS_DIR="$prev_artifacts"
    fi
}

# Telemetry tests (RED — w21-0kt1)
test_classifier_telemetry_file_created
test_classifier_telemetry_entry_is_valid_json
test_classifier_telemetry_contains_required_fields
test_classifier_telemetry_factor_scores_match_stdout
test_classifier_telemetry_files_array
test_classifier_no_telemetry_without_artifacts_dir

# ============================================================
# Security Overlay Flag Tests (RED — w22-wwu2)
# ============================================================
# These tests verify the security_overlay boolean flag in classifier output.
# The flag must be true when the diff touches security-sensitive paths
# (auth/, security/, crypto/) or contains sensitive content keywords
# (password, secret, token) or security import patterns.
# The flag must be false for unrelated diffs.
# All tests are RED — security_overlay is not yet emitted by the classifier.

test_security_overlay_true_for_auth_path() {
    # A diff touching auth/ directory must produce security_overlay:true
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/auth/login.py" "+def login(user, password): pass")
    run_classifier "$diff_file"

    local security_overlay="absent"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        security_overlay=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if 'security_overlay' not in d:
    print('absent')
else:
    print(str(d['security_overlay']).lower())
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "absent")
    fi
    assert_eq "auth/ path sets security_overlay=true" "true" "$security_overlay"
    teardown_temp_dir
}

test_security_overlay_true_for_crypto_path() {
    # A diff touching crypto/ directory must produce security_overlay:true
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/crypto/hash.py" "+import hashlib")
    run_classifier "$diff_file"

    local security_overlay="absent"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        security_overlay=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if 'security_overlay' not in d:
    print('absent')
else:
    print(str(d['security_overlay']).lower())
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "absent")
    fi
    assert_eq "crypto/ path sets security_overlay=true" "true" "$security_overlay"
    teardown_temp_dir
}

test_security_overlay_true_for_security_path() {
    # A diff touching security/ directory must produce security_overlay:true
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/security/policy.py" "+ALLOW_ANONYMOUS = False")
    run_classifier "$diff_file"

    local security_overlay="absent"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        security_overlay=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if 'security_overlay' not in d:
    print('absent')
else:
    print(str(d['security_overlay']).lower())
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "absent")
    fi
    assert_eq "security/ path sets security_overlay=true" "true" "$security_overlay"
    teardown_temp_dir
}

test_security_overlay_true_for_security_import_in_diff() {
    # A diff whose added lines contain 'from auth' must produce security_overlay:true
    setup_temp_dir
    local diff_file="$TEST_TMPDIR/test_security_import.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/services/user_service.py b/src/services/user_service.py
index 0000000..1111111 100644
--- a/src/services/user_service.py
+++ b/src/services/user_service.py
@@ -1,3 +1,5 @@
+from auth import get_token
+from crypto import encrypt
DIFFEOF
    run_classifier "$diff_file"

    local security_overlay="absent"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        security_overlay=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if 'security_overlay' not in d:
    print('absent')
else:
    print(str(d['security_overlay']).lower())
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "absent")
    fi
    assert_eq "security import in diff sets security_overlay=true" "true" "$security_overlay"
    teardown_temp_dir
}

test_security_overlay_true_for_password_keyword_in_diff() {
    # A diff whose added lines contain the word 'password' must produce security_overlay:true
    setup_temp_dir
    local diff_file="$TEST_TMPDIR/test_password_keyword.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/utils/config.py b/src/utils/config.py
index 0000000..1111111 100644
--- a/src/utils/config.py
+++ b/src/utils/config.py
@@ -1,3 +1,5 @@
+DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
+SECRET_KEY = "changeme"
+API_TOKEN = os.environ.get("API_TOKEN", "")
DIFFEOF
    run_classifier "$diff_file"

    local security_overlay="absent"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        security_overlay=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if 'security_overlay' not in d:
    print('absent')
else:
    print(str(d['security_overlay']).lower())
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "absent")
    fi
    assert_eq "password/secret/token keywords in diff set security_overlay=true" "true" "$security_overlay"
    teardown_temp_dir
}

test_security_overlay_false_for_non_security_path() {
    # A diff touching a plain source file with no security signals must produce security_overlay:false
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/utils/formatting.py" "+def format_name(name): return name.strip()")
    run_classifier "$diff_file"

    local security_overlay="absent"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        security_overlay=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if 'security_overlay' not in d:
    print('absent')
else:
    print(str(d['security_overlay']).lower())
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "absent")
    fi
    assert_eq "non-security diff sets security_overlay=false" "false" "$security_overlay"
    teardown_temp_dir
}

test_security_overlay_field_present_in_output_schema() {
    # The security_overlay key must exist in classifier JSON output for any diff
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+x = 1")
    run_classifier "$diff_file"

    local has_field="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        has_field=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print('true' if 'security_overlay' in d and isinstance(d['security_overlay'], bool) else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
    fi
    assert_eq "security_overlay field present as boolean in output schema" "true" "$has_field"
    teardown_temp_dir
}

# Security overlay flag (RED — w22-wwu2)
test_security_overlay_true_for_auth_path           # RED: security_overlay field not yet emitted
test_security_overlay_true_for_crypto_path         # RED: security_overlay field not yet emitted
test_security_overlay_true_for_security_path       # RED: security_overlay field not yet emitted
test_security_overlay_true_for_security_import_in_diff  # RED: security_overlay field not yet emitted
test_security_overlay_true_for_password_keyword_in_diff # RED: security_overlay field not yet emitted
test_security_overlay_false_for_non_security_path  # RED: security_overlay field not yet emitted
test_security_overlay_field_present_in_output_schema    # RED: security_overlay field not yet emitted

# ============================================================
# Performance Overlay Flag Tests (RED — w22-wwu2 / task a621-1689)
# ============================================================
# These tests verify the performance_overlay boolean flag in classifier output.
# The flag must be true when the diff touches performance-sensitive paths
# (db/, database/, cache/, query/, pool/) or contains performance-sensitive
# content (SELECT, INSERT, async def, await, pool, cursor).
# The flag must be false for unrelated diffs.
# All tests are RED — performance_overlay is hardcoded false until task 3c31-41b5.

# Helper: extract performance_overlay from classifier JSON output
# Usage: extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT"
# Prints: "true", "false", or "absent"
_extract_performance_overlay() {
    local output="$1"
    local exit_code="$2"
    local result="absent"
    if [[ "$exit_code" -eq 0 ]] && is_valid_json "$output"; then
        result=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
if 'performance_overlay' not in d:
    print('absent')
else:
    print(str(d['performance_overlay']).lower())
" "$output" 2>/dev/null || echo "absent")
    fi
    echo "$result"
}

test_performance_overlay_true_for_db_path() {
    # A diff touching db/ directory must produce performance_overlay:true
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/db/connection.py" "+def get_connection(): pass")
    run_classifier "$diff_file"

    local performance_overlay
    performance_overlay=$(_extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT")
    assert_eq "db/ path sets performance_overlay=true" "true" "$performance_overlay"
    teardown_temp_dir
}

test_performance_overlay_true_for_database_path() {
    # A diff touching database/ directory must produce performance_overlay:true
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/database/models.py" "+class User(Base): pass")
    run_classifier "$diff_file"

    local performance_overlay
    performance_overlay=$(_extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT")
    assert_eq "database/ path sets performance_overlay=true" "true" "$performance_overlay"
    teardown_temp_dir
}

test_performance_overlay_true_for_cache_path() {
    # A diff touching cache/ directory must produce performance_overlay:true
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/cache/redis_client.py" "+import redis")
    run_classifier "$diff_file"

    local performance_overlay
    performance_overlay=$(_extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT")
    assert_eq "cache/ path sets performance_overlay=true" "true" "$performance_overlay"
    teardown_temp_dir
}

test_performance_overlay_true_for_sql_in_diff() {
    # A diff whose added lines contain SQL keywords must produce performance_overlay:true
    setup_temp_dir
    local diff_file="$TEST_TMPDIR/test_sql_keywords.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/services/report.py b/src/services/report.py
index 0000000..1111111 100644
--- a/src/services/report.py
+++ b/src/services/report.py
@@ -1,3 +1,5 @@
+    cursor.execute("SELECT id, name FROM users WHERE active = 1")
+    rows = cursor.fetchall()
DIFFEOF
    run_classifier "$diff_file"

    local performance_overlay
    performance_overlay=$(_extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT")
    assert_eq "SELECT/cursor keywords in diff set performance_overlay=true" "true" "$performance_overlay"
    teardown_temp_dir
}

test_performance_overlay_true_for_async_await_in_diff() {
    # A diff whose added lines contain async def / await must produce performance_overlay:true
    setup_temp_dir
    local diff_file="$TEST_TMPDIR/test_async.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/workers/task_runner.py b/src/workers/task_runner.py
index 0000000..1111111 100644
--- a/src/workers/task_runner.py
+++ b/src/workers/task_runner.py
@@ -1,3 +1,5 @@
+async def run_task(task_id):
+    result = await fetch_data(task_id)
DIFFEOF
    run_classifier "$diff_file"

    local performance_overlay
    performance_overlay=$(_extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT")
    assert_eq "async def/await keywords in diff set performance_overlay=true" "true" "$performance_overlay"
    teardown_temp_dir
}

test_performance_overlay_true_for_pool_path() {
    # A diff touching pool/ directory must produce performance_overlay:true
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/pool/worker_pool.py" "+MAX_WORKERS = 10")
    run_classifier "$diff_file"

    local performance_overlay
    performance_overlay=$(_extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT")
    assert_eq "pool/ path sets performance_overlay=true" "true" "$performance_overlay"
    teardown_temp_dir
}

test_performance_overlay_false_for_non_performance_path() {
    # A diff touching a plain source file with no performance signals must produce performance_overlay:false
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/utils/string_helpers.py" "+def truncate(s, n): return s[:n]")
    run_classifier "$diff_file"

    local performance_overlay
    performance_overlay=$(_extract_performance_overlay "$CLASSIFIER_OUTPUT" "$CLASSIFIER_EXIT")
    assert_eq "non-performance diff sets performance_overlay=false" "false" "$performance_overlay"
    teardown_temp_dir
}

test_performance_overlay_field_present_in_output_schema() {
    # The performance_overlay key must exist as a boolean in classifier JSON output for any diff
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+x = 1")
    run_classifier "$diff_file"

    local has_field="false"
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        has_field=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print('true' if 'performance_overlay' in d and isinstance(d['performance_overlay'], bool) else 'false')
" "$CLASSIFIER_OUTPUT" 2>/dev/null || echo "false")
    fi
    assert_eq "performance_overlay field present as boolean in output schema" "true" "$has_field"
    teardown_temp_dir
}

# Performance overlay flag (RED — w22-wwu2 / task a621-1689)
# All assertions expect performance_overlay=true but classifier hardcodes false — these are RED.
test_performance_overlay_true_for_db_path             # RED: performance_overlay hardcoded false
test_performance_overlay_true_for_database_path       # RED: performance_overlay hardcoded false
test_performance_overlay_true_for_cache_path          # RED: performance_overlay hardcoded false
test_performance_overlay_true_for_sql_in_diff         # RED: performance_overlay hardcoded false
test_performance_overlay_true_for_async_await_in_diff # RED: performance_overlay hardcoded false
test_performance_overlay_true_for_pool_path           # RED: performance_overlay hardcoded false
test_performance_overlay_false_for_non_performance_path  # GREEN: hardcoded false matches expected false
test_performance_overlay_field_present_in_output_schema  # GREEN: field already present in schema

print_summary
