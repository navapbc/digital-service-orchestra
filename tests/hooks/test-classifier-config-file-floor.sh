#!/usr/bin/env bash
# tests/hooks/test-classifier-config-file-floor.sh
# RED test for bug fb66-bfe6: classifier must not select light tier for
# diffs that touch only DSO plugin config files (.conf in .claude/, settings.json
# in .claude/).
#
# Root cause: review-complexity-classifier.sh has no floor rule for config files.
# A minimal .claude/dso-config.conf diff scores 0 on most factors, landing in
# light tier (haiku), which lacks schema context and produces false positives.
#
# Approved fix: add _has_config_file floor rule that forces computed_total >= 3
# (standard tier) when the diff includes *.conf or settings.json under .claude/.
#
# RED: these tests FAIL with the current code (config diff → light tier).
# GREEN: these tests PASS after the _has_config_file floor rule is implemented.
#
# Usage: bash tests/hooks/test-classifier-config-file-floor.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

CLASSIFIER="$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh"

echo "=== test-classifier-config-file-floor.sh ==="

# --- Helpers ---

_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d"
    done
}
trap _cleanup_tmpdirs EXIT

_make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# Build a unified diff touching a single file
# Usage: _make_diff_fixture <tmpdir> <filepath> <added_line>
# Writes to <tmpdir>/fixture.diff and prints the path.
_make_diff_fixture() {
    local tmpdir="$1" filepath="$2" added_line="$3"
    local diff_file="$tmpdir/fixture.diff"
    cat > "$diff_file" <<DIFFEOF
diff --git a/$filepath b/$filepath
index 0000000..1111111 100644
--- a/$filepath
+++ b/$filepath
@@ -1,3 +1,4 @@
 key1=value1
+$added_line
 key2=value2
DIFFEOF
    echo "$diff_file"
}

# Run the classifier on a diff file and return the selected_tier value.
# Sets global CLASSIFIER_TIER and CLASSIFIER_EXIT.
_run_classifier_get_tier() {
    local diff_file="$1"
    CLASSIFIER_TIER=""
    CLASSIFIER_EXIT=0
    local output
    output=$(REPO_ROOT="$REPO_ROOT" bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || CLASSIFIER_EXIT=$?
    if [[ "$CLASSIFIER_EXIT" -eq 0 && -n "$output" ]]; then
        CLASSIFIER_TIER=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('selected_tier', ''))
" "$output" 2>/dev/null || echo "")
    fi
}

# ============================================================
# test_dso_config_conf_not_light_tier
# A diff touching only .claude/dso-config.conf must not produce
# selected_tier="light". Without the floor rule, the score is 0-1,
# landing in light tier.
# ============================================================
test_dso_config_conf_not_light_tier() {
    _snapshot_fail

    local tmpdir
    tmpdir=$(_make_tmpdir)

    local diff_file
    diff_file=$(_make_diff_fixture "$tmpdir" ".claude/dso-config.conf" "ci.workflow_name=new-ci-pipeline")

    _run_classifier_get_tier "$diff_file"

    assert_eq "classifier exits 0 for dso-config.conf diff" "0" "$CLASSIFIER_EXIT"
    assert_ne "dso-config.conf diff must not select light tier" "light" "$CLASSIFIER_TIER"

    assert_pass_if_clean "test_dso_config_conf_not_light_tier"
}

# ============================================================
# test_dso_config_conf_tier_is_standard_or_deep
# Verify the tier is specifically "standard" or "deep" (not an empty
# string or an unexpected value) — guards against the floor rule setting
# an incorrect tier label.
# ============================================================
test_dso_config_conf_tier_is_standard_or_deep() {
    _snapshot_fail

    local tmpdir
    tmpdir=$(_make_tmpdir)

    local diff_file
    diff_file=$(_make_diff_fixture "$tmpdir" ".claude/dso-config.conf" "test.gate=enabled")

    _run_classifier_get_tier "$diff_file"

    assert_eq "classifier exits 0" "0" "$CLASSIFIER_EXIT"

    local is_standard_or_deep
    is_standard_or_deep=$(python3 -c "
tier = '$CLASSIFIER_TIER'
print('yes' if tier in ('standard', 'deep') else 'no')
" 2>/dev/null || echo "no")

    assert_eq "dso-config.conf diff tier is standard or deep" "yes" "$is_standard_or_deep"

    assert_pass_if_clean "test_dso_config_conf_tier_is_standard_or_deep"
}

# ============================================================
# test_claude_settings_json_not_light_tier
# A diff touching only .claude/settings.json must also not produce
# selected_tier="light".
# ============================================================
test_claude_settings_json_not_light_tier() {
    _snapshot_fail

    local tmpdir
    tmpdir=$(_make_tmpdir)

    local diff_file
    diff_file=$(_make_diff_fixture "$tmpdir" ".claude/settings.json" "+  \"newSetting\": true,")

    _run_classifier_get_tier "$diff_file"

    assert_eq "classifier exits 0 for settings.json diff" "0" "$CLASSIFIER_EXIT"
    assert_ne "settings.json diff must not select light tier" "light" "$CLASSIFIER_TIER"

    assert_pass_if_clean "test_claude_settings_json_not_light_tier"
}

# ============================================================
# test_computed_total_at_least_three_for_config_diff
# The computed_total in the JSON output must be >= 3 when a config
# file floor rule is applied — this is the mechanism that forces
# standard tier.
# ============================================================
test_computed_total_at_least_three_for_config_diff() {
    _snapshot_fail

    local tmpdir
    tmpdir=$(_make_tmpdir)

    local diff_file
    diff_file=$(_make_diff_fixture "$tmpdir" ".claude/dso-config.conf" "format.python=ruff")

    local output exit_code=0
    output=$(REPO_ROOT="$REPO_ROOT" bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || exit_code=$?

    assert_eq "classifier exits 0" "0" "$exit_code"

    local computed_total
    computed_total=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(d.get('computed_total', -1))
" "$output" 2>/dev/null || echo "-1")

    local meets_floor
    meets_floor=$(python3 -c "print('yes' if int('$computed_total') >= 3 else 'no')" 2>/dev/null || echo "no")

    assert_eq "computed_total >= 3 for dso-config.conf diff" "yes" "$meets_floor"

    assert_pass_if_clean "test_computed_total_at_least_three_for_config_diff"
}

# ============================================================
# test_non_config_small_diff_still_light
# A diff touching only a non-config source file with no other
# score-raising signals should still produce light tier — verifies
# the floor rule is scoped to config files only and not a blanket
# tier upgrade.
# ============================================================
test_non_config_small_diff_still_light() {
    _snapshot_fail

    local tmpdir
    tmpdir=$(_make_tmpdir)

    local diff_file
    diff_file=$(_make_diff_fixture "$tmpdir" "src/utils/helpers/string_util.py" "+    pass  # no-op placeholder")

    _run_classifier_get_tier "$diff_file"

    assert_eq "classifier exits 0 for non-config diff" "0" "$CLASSIFIER_EXIT"
    assert_eq "non-config small diff stays at light tier" "light" "$CLASSIFIER_TIER"

    assert_pass_if_clean "test_non_config_small_diff_still_light"
}

# ============================================================
# Run all tests
# ============================================================
test_dso_config_conf_not_light_tier
test_dso_config_conf_tier_is_standard_or_deep
test_claude_settings_json_not_light_tier
test_computed_total_at_least_three_for_config_diff
test_non_config_small_diff_still_light

print_summary
