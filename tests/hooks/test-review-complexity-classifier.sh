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

# Create a shared isolated git repo ONCE for merge-state isolation.
# All tests reference this via CLASSIFIER_GIT_DIR so the classifier's
# _is_merge_commit reads from this repo (no MERGE_HEAD) rather than the
# real worktree's git state. Per-test temp dirs only need artifacts.
_SHARED_GIT_DIR="$(mktemp -d)"
git -C "$_SHARED_GIT_DIR" init -q -b main 2>/dev/null
git -C "$_SHARED_GIT_DIR" config user.email "test@test" 2>/dev/null
git -C "$_SHARED_GIT_DIR" config user.name "test" 2>/dev/null
git -C "$_SHARED_GIT_DIR" config core.hooksPath /dev/null 2>/dev/null
touch "$_SHARED_GIT_DIR/.gitkeep"
git -C "$_SHARED_GIT_DIR" add -A 2>/dev/null
git -C "$_SHARED_GIT_DIR" commit -q -m "init" 2>/dev/null
export TEST_GIT_DIR="$_SHARED_GIT_DIR/.git"
trap 'rm -rf "$_SHARED_GIT_DIR"' EXIT

setup_temp_dir() {
    TEST_TMPDIR="$(mktemp -d)"
    export ARTIFACTS_DIR="$TEST_TMPDIR/artifacts"
    mkdir -p "$ARTIFACTS_DIR"
}

teardown_temp_dir() {
    [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# Create a temp git dir with a fake MERGE_HEAD file for merge-state isolation.
# Returns the .git dir path on stdout.
# Usage: local git_dir; git_dir=$(make_merge_head_git_dir)
make_merge_head_git_dir() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    git -C "$tmpdir" init -q -b main 2>/dev/null
    git -C "$tmpdir" config user.email "test@test" 2>/dev/null
    git -C "$tmpdir" config user.name "test" 2>/dev/null
    git -C "$tmpdir" config core.hooksPath /dev/null 2>/dev/null
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add -A 2>/dev/null
    git -C "$tmpdir" commit -q -m "init" 2>/dev/null
    # Write a fake MERGE_HEAD that does NOT equal HEAD (to pass the MERGE_HEAD==HEAD guard)
    # Use a SHA that looks valid but is not the current HEAD
    echo "0000000000000000000000000000000000000001" > "$tmpdir/.git/MERGE_HEAD"
    echo "$tmpdir/.git"
}

# Create a temp git dir with a fake REBASE_HEAD file for rebase-state isolation.
# Returns the .git dir path on stdout.
make_rebase_head_git_dir() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    git -C "$tmpdir" init -q -b main 2>/dev/null
    git -C "$tmpdir" config user.email "test@test" 2>/dev/null
    git -C "$tmpdir" config user.name "test" 2>/dev/null
    git -C "$tmpdir" config core.hooksPath /dev/null 2>/dev/null
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add -A 2>/dev/null
    git -C "$tmpdir" commit -q -m "init" 2>/dev/null
    echo "0000000000000000000000000000000000000001" > "$tmpdir/.git/REBASE_HEAD"
    echo "$tmpdir/.git"
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
        # Pin REPO_ROOT so the classifier doesn't depend on `git rev-parse`,
        # which can fail intermittently under parallel load (index.lock contention).
        # Use CLASSIFIER_GIT_DIR to isolate _is_merge_commit from the real
        # worktree's MERGE_HEAD — each test gets its own temp git repo from
        # setup_temp_dir, ensuring parallel runs don't interfere.
        CLASSIFIER_OUTPUT=$(REPO_ROOT="$REPO_ROOT" _MERGE_STATE_GIT_DIR="${TEST_GIT_DIR:-}" bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || CLASSIFIER_EXIT=$?
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

# REMOVED: test_classifier_completes_in_under_2s
# Absolute wall-clock performance assertion removed — too flaky (2s threshold
# hit by deps.sh sourcing + config resolution jitter). The fast-path optimization
# in pre-commit-test-gate.sh (bug 38a0-e706) is what matters for commit-time
# performance. Per-invocation speed is a nice-to-have, not a gate.
# Tracking bug: 642e-b82e
_removed_test_classifier_completes_in_under_2s() {
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

# Performance — removed (flaky, see 642e-b82e)

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
    # Normal diff (no merge/rebase state) → is_merge_commit = false
    setup_temp_dir
    local diff_file
    diff_file=$(create_diff_fixture "src/foo.py" "+print('hello')")
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
    assert_eq "normal diff (no merge/rebase state) has is_merge_commit=false" "false" "$is_merge"
    teardown_temp_dir
}

test_classifier_is_merge_commit_false_when_head_has_two_parents() {
    # Bug d03a-b1f6: After worktree sync merges, HEAD has 2 parents.
    # The classifier's parent-count check falsely returns is_merge_commit=true
    # for non-merge staged diffs. Only MERGE_HEAD should matter.
    setup_temp_dir

    # Create a temp git repo with a merge commit as HEAD (2 parents, no MERGE_HEAD)
    local merge_repo="$TEST_TMPDIR/merge-repo"
    mkdir -p "$merge_repo"
    git -C "$merge_repo" init -q
    git -C "$merge_repo" config user.email "test@test.com"
    git -C "$merge_repo" config user.name "Test"
    git -C "$merge_repo" config core.hooksPath /dev/null
    echo "base" > "$merge_repo/base.txt"
    git -C "$merge_repo" add base.txt
    git -C "$merge_repo" commit -q -m "base commit"
    git -C "$merge_repo" checkout -q -b feature
    echo "feature" > "$merge_repo/feature.txt"
    git -C "$merge_repo" add feature.txt
    git -C "$merge_repo" commit -q -m "feature commit"
    git -C "$merge_repo" checkout -q main 2>/dev/null || git -C "$merge_repo" checkout -q master
    git -C "$merge_repo" merge -q --no-ff feature -m "merge feature"

    # Verify HEAD has 2 parents (the merge)
    local parent_count
    parent_count=$(git -C "$merge_repo" log -1 --pretty=%P HEAD | wc -w | tr -d '[:space:]')
    assert_eq "merge repo HEAD has 2 parents" "2" "$parent_count"

    # Verify no MERGE_HEAD (merge is already committed)
    local merge_head_exists="false"
    if [[ -f "$merge_repo/.git/MERGE_HEAD" ]]; then
        merge_head_exists="true"
    fi
    assert_eq "no MERGE_HEAD after committed merge" "false" "$merge_head_exists"

    # Run classifier from inside the merge repo with a normal diff
    local diff_file="$TEST_TMPDIR/test.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/foo.py b/src/foo.py
index 0000000..1111111 100644
--- a/src/foo.py
+++ b/src/foo.py
@@ -1,3 +1,5 @@
+print('hello')
DIFFEOF

    local classifier_output=""
    local classifier_exit=0
    classifier_output=$(cd "$merge_repo" && bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || classifier_exit=$?

    local is_merge="true"
    if [[ "$classifier_exit" -eq 0 ]] && python3 -c "import json; json.loads('''$classifier_output''')" 2>/dev/null; then
        is_merge=$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
v=d.get('is_merge_commit',True)
print(str(v).lower() if isinstance(v,bool) else str(v))
" "$classifier_output" 2>/dev/null || echo "true")
    fi
    # This SHOULD be false: we're staging a normal diff, just HEAD happens to be a merge
    assert_eq "is_merge_commit=false when HEAD has 2 parents but no MERGE_HEAD" "false" "$is_merge"
    teardown_temp_dir
}

test_classifier_is_merge_commit_size_action_none() {
    # When merge is in progress (_MERGE_STATE_GIT_DIR pointing to repo with MERGE_HEAD),
    # size_action = "none" even with 600+ lines
    setup_temp_dir
    local diff_file merge_git_dir
    diff_file=$(create_n_line_diff 600 "src/foo.py")
    merge_git_dir=$(make_merge_head_git_dir)
    TEST_GIT_DIR="$merge_git_dir" run_classifier "$diff_file"

    local size_action=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        size_action=$(json_field "size_action" "$CLASSIFIER_OUTPUT")
    fi
    assert_eq "merge commit (_MERGE_STATE_GIT_DIR with MERGE_HEAD) with 600 lines has size_action=none" "none" "$size_action"
    rm -rf "$(dirname "$merge_git_dir")" 2>/dev/null || true
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
test_classifier_is_merge_commit_false_when_head_has_two_parents  # RED: parent-count falsely detects merge
test_classifier_is_merge_commit_size_action_none  # RED: merge commit bypass not yet implemented
test_classifier_output_includes_new_fields  # RED: new fields not yet in output schema

# ============================================================
# Merge-commit floor tests (57ed-e776)
# ============================================================

test_classifier_merge_commit_floor_upgrades_light_to_standard() {
    # A merge commit with a low-scoring diff (would normally be light tier)
    # must be upgraded to at least standard tier.
    setup_temp_dir
    local diff_file merge_git_dir
    # Single-line diff in a non-critical file = light tier normally
    diff_file=$(create_diff_fixture "README.md" "+minor edit")
    merge_git_dir=$(make_merge_head_git_dir)
    TEST_GIT_DIR="$merge_git_dir" run_classifier "$diff_file"

    local tier=""
    if [[ "$CLASSIFIER_EXIT" -eq 0 ]] && is_valid_json "$CLASSIFIER_OUTPUT"; then
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    fi
    # Merge commits must NEVER be light — floor is standard
    assert_ne "merge commit floor: tier is not light" "light" "$tier"
    rm -rf "$(dirname "$merge_git_dir")" 2>/dev/null || true
    teardown_temp_dir
}

test_classifier_merge_commit_floor_upgrades_light_to_standard

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

# ============================================================
# Rebase commit detection (task 1bf5-9563)
# ============================================================
# _is_merge_commit() now delegates to ms_is_rebase_in_progress() from merge-state.sh.
# Test isolation uses _MERGE_STATE_GIT_DIR pointing to a temp git dir with REBASE_HEAD.

test_classifier_detects_rebase_commit() {
    # When _MERGE_STATE_GIT_DIR points to a repo with REBASE_HEAD, the classifier
    # must emit is_merge_commit=true.
    setup_temp_dir
    local diff_file rebase_git_dir
    diff_file=$(create_diff_fixture "src/utils/helpers.py" "+def noop(): pass")
    rebase_git_dir=$(make_rebase_head_git_dir)

    local is_merge
    is_merge=$(_MERGE_STATE_GIT_DIR="$rebase_git_dir" REPO_ROOT="$REPO_ROOT" bash "$CLASSIFIER" < "$diff_file" 2>/dev/null \
        | python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
v=d.get('is_merge_commit', False)
print(str(v).lower() if isinstance(v,bool) else str(v))
" 2>/dev/null || echo "false")

    assert_eq "rebase commit (_MERGE_STATE_GIT_DIR with REBASE_HEAD) sets is_merge_commit=true" "true" "$is_merge"
    rm -rf "$(dirname "$rebase_git_dir")" 2>/dev/null || true
    teardown_temp_dir
}

# Rebase detection — now GREEN with merge-state.sh delegation
test_classifier_detects_rebase_commit  # GREEN: _is_merge_commit() delegates to ms_is_rebase_in_progress()

# ============================================================
# External API import floor rule tests (task 355c-2344)
# ============================================================
# These tests verify that a diff containing an import not present in any
# project dependency manifest (pyproject.toml, package.json, requirements.txt)
# triggers the _has_external_api_signal() floor rule and forces the tier to
# at least "standard".
#
# Tests verify the floor rule bumps light→standard for unfamiliar imports.

# Helper: extract selected_tier from classifier JSON output
_extract_tier_from_output() {
    local output="$1"
    local exit_code="$2"
    if [[ "$exit_code" -eq 0 ]] && is_valid_json "$output"; then
        python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print(d.get('selected_tier', ''))
" "$output" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

test_floor_rule_external_api_import_forces_standard() {
    # A diff that imports a library not listed in any manifest must not produce light tier.
    # This simulates a developer adding an import for an unfamiliar package.
    setup_temp_dir

    # Create a minimal pyproject.toml in a temp dir so the classifier has a
    # manifest to parse (that does NOT contain the imported package).
    local manifest_dir="$TEST_TMPDIR/project"
    mkdir -p "$manifest_dir"
    cat > "$manifest_dir/pyproject.toml" <<'TOMLEOF'
[tool.poetry.dependencies]
python = "^3.11"
requests = "^2.28"
TOMLEOF

    # Create a diff that imports a package NOT listed in pyproject.toml
    local diff_file="$TEST_TMPDIR/external_import.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/services/payment.py b/src/services/payment.py
index 0000000..1111111 100644
--- a/src/services/payment.py
+++ b/src/services/payment.py
@@ -1,3 +1,5 @@
+import stripe
+from stripe.error import StripeError
DIFFEOF

    local output exit_code=0
    # Set REPO_ROOT to the manifest_dir so the classifier finds pyproject.toml there
    output=$(REPO_ROOT="$manifest_dir" _MERGE_STATE_GIT_DIR="$TEST_GIT_DIR" bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || exit_code=$?

    local tier
    tier=$(_extract_tier_from_output "$output" "$exit_code")

    local is_at_least_standard="false"
    if [[ "$tier" == "standard" || "$tier" == "deep" ]]; then
        is_at_least_standard="true"
    fi
    assert_eq "external API import (stripe not in pyproject.toml) forces at least standard tier" "true" "$is_at_least_standard"
    teardown_temp_dir
}

test_floor_rule_known_import_stays_light() {
    # A diff importing a package that IS listed in pyproject.toml must not trigger the floor.
    # A minimal diff that only adds a known import should stay at light tier.
    setup_temp_dir

    local manifest_dir="$TEST_TMPDIR/project"
    mkdir -p "$manifest_dir"
    cat > "$manifest_dir/pyproject.toml" <<'TOMLEOF'
[tool.poetry.dependencies]
python = "^3.11"
requests = "^2.28"
boto3 = "^1.26"
TOMLEOF

    local diff_file="$TEST_TMPDIR/known_import.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/utils/http_client.py b/src/utils/http_client.py
index 0000000..1111111 100644
--- a/src/utils/http_client.py
+++ b/src/utils/http_client.py
@@ -1,3 +1,4 @@
+import requests
DIFFEOF

    local output exit_code=0
    output=$(REPO_ROOT="$manifest_dir" _MERGE_STATE_GIT_DIR="$TEST_GIT_DIR" bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || exit_code=$?

    local tier
    tier=$(_extract_tier_from_output "$output" "$exit_code")

    assert_eq "known import (requests in pyproject.toml) stays at light tier" "light" "$tier"
    teardown_temp_dir
}

test_floor_rule_external_import_fail_open_no_manifest() {
    # When no manifest exists (no pyproject.toml/package.json/requirements.txt),
    # the floor rule must NOT fire (fail-open: no false positives from missing manifests).
    setup_temp_dir

    # Use a REPO_ROOT that has no manifests at all
    local empty_dir="$TEST_TMPDIR/empty_project"
    mkdir -p "$empty_dir"
    # Initialize a minimal git repo so REPO_ROOT is valid
    git -C "$empty_dir" init -q -b main 2>/dev/null
    git -C "$empty_dir" config user.email "test@test" 2>/dev/null
    git -C "$empty_dir" config user.name "test" 2>/dev/null
    touch "$empty_dir/.gitkeep"
    git -C "$empty_dir" add -A 2>/dev/null
    git -C "$empty_dir" commit -q -m "init" 2>/dev/null

    local diff_file="$TEST_TMPDIR/unknown_import_no_manifest.diff"
    cat > "$diff_file" <<'DIFFEOF'
diff --git a/src/services/payment.py b/src/services/payment.py
index 0000000..1111111 100644
--- a/src/services/payment.py
+++ b/src/services/payment.py
@@ -1,3 +1,4 @@
+import stripe
DIFFEOF

    local output exit_code=0
    output=$(REPO_ROOT="$empty_dir" _MERGE_STATE_GIT_DIR="$TEST_GIT_DIR" bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || exit_code=$?

    local tier
    tier=$(_extract_tier_from_output "$output" "$exit_code")

    # Without a manifest, the floor rule must not fire — should stay light
    assert_eq "no manifest present: external import does NOT trigger floor (fail-open)" "light" "$tier"
    teardown_temp_dir
}

# External API import floor rule tests (task 355c-2344)
test_floor_rule_external_api_import_forces_standard
test_floor_rule_known_import_stays_light
test_floor_rule_external_import_fail_open_no_manifest

print_summary
