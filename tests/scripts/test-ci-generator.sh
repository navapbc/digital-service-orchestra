#!/usr/bin/env bash
# tests/scripts/test-ci-generator.sh
# RED-phase TDD tests for plugins/dso/scripts/onboarding/ci-generator.sh
#
# The generator script does not yet exist — all tests should FAIL (RED).
#
# Tests covered:
#   1. test_generates_ci_yml_for_fast_suites
#   2. test_generates_ci_slow_yml_for_slow_suites
#   3. test_job_id_derived_from_suite_name
#   4. test_fast_suites_trigger_on_pull_request
#   5. test_slow_suites_trigger_on_push_to_main
#   6. test_empty_suite_list_produces_no_files
#   7. test_unknown_speed_class_noninteractive_defaults_to_slow
#
# Usage: bash tests/scripts/test-ci-generator.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/onboarding/ci-generator.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ci-generator.sh ==="

# Create a temp dir for output files used in tests
TMPDIR_OUTPUT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_OUTPUT"' EXIT

# ── helpers ───────────────────────────────────────────────────────────────────

# Run the generator with a JSON suites string and a dedicated output subdir.
# Usage: run_generator <subdir_name> <suites_json>
# The --output-dir will be TMPDIR_OUTPUT/<subdir_name>.
# In non-interactive mode CI_NONINTERACTIVE=1 forces non-interactive path.
run_generator() {
    local subdir="$1"
    local suites_json="$2"
    local outdir="$TMPDIR_OUTPUT/$subdir"
    mkdir -p "$outdir"
    CI_NONINTERACTIVE=1 bash "$SCRIPT" \
        --suites-json "$suites_json" \
        --output-dir "$outdir" \
        2>/dev/null
}

# ── test_ci_generator_script_exists ──────────────────────────────────────────
# The generator script must exist and be executable before any other test runs.
# (This test will also be RED until the script is created.)
_snapshot_fail
if [[ -f "$SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_ci_generator_script_exists: file exists" "exists" "$actual_exists"

if [[ -x "$SCRIPT" ]]; then
    actual_exec="executable"
else
    actual_exec="not_executable"
fi
assert_eq "test_ci_generator_script_exists: file is executable" "executable" "$actual_exec"
assert_pass_if_clean "test_ci_generator_script_exists"

# ── test_generates_ci_yml_for_fast_suites ────────────────────────────────────
# Given a JSON array with one fast suite, ci.yml must be written.
_snapshot_fail
FAST_SUITES='[{"name":"unit","command":"make test-unit","speed_class":"fast","runner":"make"}]'
run_generator "fast_only" "$FAST_SUITES" || true
assert_eq "test_generates_ci_yml_for_fast_suites: ci.yml created" \
    "yes" \
    "$(test -f "$TMPDIR_OUTPUT/fast_only/ci.yml" && echo yes || echo no)"
assert_pass_if_clean "test_generates_ci_yml_for_fast_suites"

# ── test_generates_ci_slow_yml_for_slow_suites ───────────────────────────────
# Given a JSON array with one slow suite, ci-slow.yml must be written.
_snapshot_fail
SLOW_SUITES='[{"name":"e2e","command":"make test-e2e","speed_class":"slow","runner":"make"}]'
run_generator "slow_only" "$SLOW_SUITES" || true
assert_eq "test_generates_ci_slow_yml_for_slow_suites: ci-slow.yml created" \
    "yes" \
    "$(test -f "$TMPDIR_OUTPUT/slow_only/ci-slow.yml" && echo yes || echo no)"
assert_pass_if_clean "test_generates_ci_slow_yml_for_slow_suites"

# ── test_job_id_derived_from_suite_name ──────────────────────────────────────
# Suite name 'unit' must produce a job ID of 'test-unit' inside ci.yml.
_snapshot_fail
UNIT_SUITES='[{"name":"unit","command":"make test-unit","speed_class":"fast","runner":"make"}]'
run_generator "job_id" "$UNIT_SUITES" || true
CI_YML="$TMPDIR_OUTPUT/job_id/ci.yml"
if [[ -f "$CI_YML" ]]; then
    job_id_content="$(cat "$CI_YML")"
else
    job_id_content=""
fi
assert_contains "test_job_id_derived_from_suite_name: job id test-unit present" \
    "test-unit" "$job_id_content"
assert_pass_if_clean "test_job_id_derived_from_suite_name"

# ── test_fast_suites_trigger_on_pull_request ─────────────────────────────────
# ci.yml must contain a 'pull_request' trigger.
_snapshot_fail
PR_SUITES='[{"name":"lint","command":"make lint","speed_class":"fast","runner":"make"}]'
run_generator "pr_trigger" "$PR_SUITES" || true
PR_CI_YML="$TMPDIR_OUTPUT/pr_trigger/ci.yml"
if [[ -f "$PR_CI_YML" ]]; then
    pr_content="$(cat "$PR_CI_YML")"
else
    pr_content=""
fi
assert_contains "test_fast_suites_trigger_on_pull_request: pull_request trigger present" \
    "pull_request" "$pr_content"
assert_pass_if_clean "test_fast_suites_trigger_on_pull_request"

# ── test_slow_suites_trigger_on_push_to_main ─────────────────────────────────
# ci-slow.yml must contain a 'push' trigger pointing to the main branch.
_snapshot_fail
PUSH_SUITES='[{"name":"integration","command":"make test-integration","speed_class":"slow","runner":"make"}]'
run_generator "push_trigger" "$PUSH_SUITES" || true
SLOW_CI_YML="$TMPDIR_OUTPUT/push_trigger/ci-slow.yml"
if [[ -f "$SLOW_CI_YML" ]]; then
    push_content="$(cat "$SLOW_CI_YML")"
else
    push_content=""
fi
assert_contains "test_slow_suites_trigger_on_push_to_main: push trigger present" \
    "push" "$push_content"
assert_contains "test_slow_suites_trigger_on_push_to_main: main branch present" \
    "main" "$push_content"
assert_pass_if_clean "test_slow_suites_trigger_on_push_to_main"

# ── test_empty_suite_list_produces_no_files ──────────────────────────────────
# An empty JSON array must write neither ci.yml nor ci-slow.yml.
_snapshot_fail
run_generator "empty_suites" '[]' || true
EMPTY_DIR="$TMPDIR_OUTPUT/empty_suites"
ci_exists="no"
ci_slow_exists="no"
if [[ -f "$EMPTY_DIR/ci.yml" ]]; then ci_exists="yes"; fi
if [[ -f "$EMPTY_DIR/ci-slow.yml" ]]; then ci_slow_exists="yes"; fi
assert_eq "test_empty_suite_list_produces_no_files: ci.yml absent" \
    "no" "$ci_exists"
assert_eq "test_empty_suite_list_produces_no_files: ci-slow.yml absent" \
    "no" "$ci_slow_exists"
assert_pass_if_clean "test_empty_suite_list_produces_no_files"

# ── test_unknown_speed_class_noninteractive_defaults_to_slow ──────────────────
# In non-interactive mode (CI_NONINTERACTIVE=1), suites with speed_class=unknown
# must go into ci-slow.yml (conservative default — avoid blocking PRs).
_snapshot_fail
UNKNOWN_SUITES='[{"name":"perf","command":"make test-perf","speed_class":"unknown","runner":"make"}]'
run_generator "unknown_noninteractive" "$UNKNOWN_SUITES" || true
UNKNOWN_DIR="$TMPDIR_OUTPUT/unknown_noninteractive"
ci_slow_has_perf="no"
if [[ -f "$UNKNOWN_DIR/ci-slow.yml" ]]; then
    slow_content="$(cat "$UNKNOWN_DIR/ci-slow.yml")"
    if [[ "$slow_content" == *"perf"* ]]; then
        ci_slow_has_perf="yes"
    fi
fi
# Also verify it was NOT written to ci.yml (fast path)
ci_has_perf="no"
if [[ -f "$UNKNOWN_DIR/ci.yml" ]]; then
    fast_content="$(cat "$UNKNOWN_DIR/ci.yml")"
    if [[ "$fast_content" == *"perf"* ]]; then
        ci_has_perf="yes"
    fi
fi
assert_eq "test_unknown_speed_class_noninteractive_defaults_to_slow: in ci-slow.yml" \
    "yes" "$ci_slow_has_perf"
assert_eq "test_unknown_speed_class_noninteractive_defaults_to_slow: not in ci.yml" \
    "no" "$ci_has_perf"
assert_pass_if_clean "test_unknown_speed_class_noninteractive_defaults_to_slow"

# ── test_mixed_suites_split_correctly ────────────────────────────────────────
# A JSON array with both fast and slow suites must produce both ci.yml and ci-slow.yml,
# each containing only the relevant suite's job.
_snapshot_fail
MIXED_SUITES='[{"name":"unit","command":"make test-unit","speed_class":"fast","runner":"make"},{"name":"e2e","command":"make test-e2e","speed_class":"slow","runner":"make"}]'
run_generator "mixed" "$MIXED_SUITES" || true
MIXED_DIR="$TMPDIR_OUTPUT/mixed"
mixed_ci_has_unit="no"
mixed_ci_has_e2e="no"
mixed_slow_has_unit="no"
mixed_slow_has_e2e="no"
if [[ -f "$MIXED_DIR/ci.yml" ]]; then
    mc="$(cat "$MIXED_DIR/ci.yml")"
    if [[ "$mc" == *"unit"* ]]; then mixed_ci_has_unit="yes"; fi
    if [[ "$mc" == *"e2e"* ]]; then mixed_ci_has_e2e="yes"; fi
fi
if [[ -f "$MIXED_DIR/ci-slow.yml" ]]; then
    ms="$(cat "$MIXED_DIR/ci-slow.yml")"
    if [[ "$ms" == *"unit"* ]]; then mixed_slow_has_unit="yes"; fi
    if [[ "$ms" == *"e2e"* ]]; then mixed_slow_has_e2e="yes"; fi
fi
assert_eq "test_mixed_suites_split_correctly: unit in ci.yml" \
    "yes" "$mixed_ci_has_unit"
assert_eq "test_mixed_suites_split_correctly: e2e not in ci.yml" \
    "no" "$mixed_ci_has_e2e"
assert_eq "test_mixed_suites_split_correctly: e2e in ci-slow.yml" \
    "yes" "$mixed_slow_has_e2e"
assert_eq "test_mixed_suites_split_correctly: unit not in ci-slow.yml" \
    "no" "$mixed_slow_has_unit"
assert_pass_if_clean "test_mixed_suites_split_correctly"

# ── test_command_sanitization_strips_metacharacters ──────────────────────────
# A suite command with shell metacharacters (e.g. 'make test; rm -rf /') must
# produce a YAML run: field that contains ONLY the safe portion before the
# semicolon — i.e. the dangerous fragment 'rm -rf' must NOT appear.
#
# The current sanitize_command strips the semicolon but retains the text after
# it ('rm -rf /'), so the YAML run field ends up as 'make test rm -rf /'.
# This test fails RED until dso-cwyt implements truncation-at-first-metachar
# or a stricter rejection policy.
_snapshot_fail
METACHAR_SUITES='[{"name":"unit","command":"make test; rm -rf /","speed_class":"fast","runner":"make"}]'
run_generator "sanitize_meta" "$METACHAR_SUITES" || true
SANITIZE_CI_YML="$TMPDIR_OUTPUT/sanitize_meta/ci.yml"
sanitize_run_field=""
if [[ -f "$SANITIZE_CI_YML" ]]; then
    sanitize_run_field="$(grep 'run:' "$SANITIZE_CI_YML" | head -1)"
fi
# Assert: exit 0 (script must not error on this input)
sanitize_exit=0
CI_NONINTERACTIVE=1 bash "$SCRIPT" \
    --suites-json "$METACHAR_SUITES" \
    --output-dir "$TMPDIR_OUTPUT/sanitize_meta_exit" \
    2>/dev/null || sanitize_exit=$?
assert_eq "test_command_sanitization_strips_metacharacters: exit 0" \
    "0" "$sanitize_exit"
# Assert: the dangerous fragment 'rm -rf' is NOT in the run: field
rm_rf_in_yaml="no"
if [[ "$sanitize_run_field" == *"rm -rf"* ]]; then
    rm_rf_in_yaml="yes"
fi
assert_eq "test_command_sanitization_strips_metacharacters: no rm -rf in run field" \
    "no" "$rm_rf_in_yaml"
assert_pass_if_clean "test_command_sanitization_strips_metacharacters"

# ── test_yaml_validation_blocks_invalid_yaml ─────────────────────────────────
# When the generated YAML fails validation, the generator must exit 2 and
# write no output file.  We simulate a validation failure by injecting a fake
# python3 into PATH that always returns non-zero for yaml.safe_load calls.
#
# Additionally, the error message on stderr must contain the string
# "invalid YAML" so callers can parse it programmatically.  The current
# implementation emits "failed YAML validation" (not "invalid YAML"), so the
# stderr-content assertion fails RED until dso-cwyt normalises the message.
_snapshot_fail
YAML_FAKE_BIN="$(mktemp -d)"
cat > "$YAML_FAKE_BIN/python3" << 'FAKE_PYEOF'
#!/usr/bin/env bash
# Stub: pretend yaml.safe_load always fails
_args="$*"
if [[ "$_args" == *'yaml.safe_load'* ]]; then
    exit 1
fi
exec /usr/bin/python3 "$@"
FAKE_PYEOF
chmod +x "$YAML_FAKE_BIN/python3"
trap 'rm -rf "$YAML_FAKE_BIN"' EXIT

YAML_VAL_DIR="$TMPDIR_OUTPUT/yaml_validation"
mkdir -p "$YAML_VAL_DIR"
yaml_val_stderr="$(PATH="$YAML_FAKE_BIN:$PATH" CI_NONINTERACTIVE=1 bash "$SCRIPT" \
    --suites-json '[{"name":"unit","command":"make test","speed_class":"fast","runner":"make"}]' \
    --output-dir "$YAML_VAL_DIR" \
    2>&1 >/dev/null)"
yaml_val_exit=$?

assert_eq "test_yaml_validation_blocks_invalid_yaml: exit code is 2" \
    "2" "$yaml_val_exit"

yaml_val_file_written="yes"
if [[ ! -f "$YAML_VAL_DIR/ci.yml" ]]; then
    yaml_val_file_written="no"
fi
assert_eq "test_yaml_validation_blocks_invalid_yaml: no file written on failure" \
    "no" "$yaml_val_file_written"

yaml_val_msg_ok="no"
if [[ "$yaml_val_stderr" == *"invalid YAML"* ]]; then
    yaml_val_msg_ok="yes"
fi
assert_eq "test_yaml_validation_blocks_invalid_yaml: stderr contains 'invalid YAML'" \
    "yes" "$yaml_val_msg_ok"
assert_pass_if_clean "test_yaml_validation_blocks_invalid_yaml"

# ── test_special_chars_in_suite_name_produce_valid_job_id ─────────────────────
# Suite name 'my_test suite' (underscore + space) must produce the job ID
# 'test-my-test-suite' in the generated YAML.  Both the job ID must appear
# as a key in the YAML jobs: block and the YAML must remain structurally valid
# (parseable by python3 yaml.safe_load).
_snapshot_fail
SPECIAL_NAME_SUITES='[{"name":"my_test suite","command":"make test","speed_class":"fast","runner":"make"}]'
run_generator "special_name" "$SPECIAL_NAME_SUITES" || true
SPECIAL_CI_YML="$TMPDIR_OUTPUT/special_name/ci.yml"

special_job_id_present="no"
special_yaml_valid="no"
if [[ -f "$SPECIAL_CI_YML" ]]; then
    if grep -q 'test-my-test-suite:' "$SPECIAL_CI_YML"; then
        special_job_id_present="yes"
    fi
    if python3 -c "import yaml; yaml.safe_load(open('$SPECIAL_CI_YML'))" 2>/dev/null; then
        special_yaml_valid="yes"
    fi
fi
assert_eq "test_special_chars_in_suite_name_produce_valid_job_id: job ID test-my-test-suite present" \
    "yes" "$special_job_id_present"
assert_eq "test_special_chars_in_suite_name_produce_valid_job_id: generated YAML is valid" \
    "yes" "$special_yaml_valid"
assert_pass_if_clean "test_special_chars_in_suite_name_produce_valid_job_id"

# ── test_all_unknown_suites_noninteractive_go_to_slow ─────────────────────────
# In non-interactive mode, a JSON array where ALL suites have speed_class=unknown
# must write ONLY ci-slow.yml (never ci.yml).  Having multiple unknown-class
# suites exercises the all-unknown branch rather than the single-suite case
# already covered by test_unknown_speed_class_noninteractive_defaults_to_slow.
_snapshot_fail
ALL_UNKNOWN_SUITES='[{"name":"load","command":"make load","speed_class":"unknown","runner":"make"},{"name":"smoke","command":"make smoke","speed_class":"unknown","runner":"make"}]'
run_generator "all_unknown" "$ALL_UNKNOWN_SUITES" || true
ALL_UNKNOWN_DIR="$TMPDIR_OUTPUT/all_unknown"

all_unknown_slow_exists="no"
all_unknown_fast_exists="no"
all_unknown_slow_has_both="no"
if [[ -f "$ALL_UNKNOWN_DIR/ci-slow.yml" ]]; then
    all_unknown_slow_exists="yes"
    slow_content="$(cat "$ALL_UNKNOWN_DIR/ci-slow.yml")"
    if [[ "$slow_content" == *"load"* && "$slow_content" == *"smoke"* ]]; then
        all_unknown_slow_has_both="yes"
    fi
fi
if [[ -f "$ALL_UNKNOWN_DIR/ci.yml" ]]; then
    all_unknown_fast_exists="yes"
fi
assert_eq "test_all_unknown_suites_noninteractive_go_to_slow: ci-slow.yml written" \
    "yes" "$all_unknown_slow_exists"
assert_eq "test_all_unknown_suites_noninteractive_go_to_slow: ci.yml not written" \
    "no" "$all_unknown_fast_exists"
assert_eq "test_all_unknown_suites_noninteractive_go_to_slow: both suites in ci-slow.yml" \
    "yes" "$all_unknown_slow_has_both"
assert_pass_if_clean "test_all_unknown_suites_noninteractive_go_to_slow"

# ── test_temp_then_move_pattern ───────────────────────────────────────────────
# The generator must write output atomically: compose content in a temp file
# first, validate, then move to the final path.  On validation failure the
# final output file must NOT exist and no stray temp files must remain in the
# output directory itself.
#
# This test verifies the observable contract of the temp-then-move pattern:
# (a) on success, ci.yml exists and contains valid YAML, and
# (b) on failure (mocked), ci.yml does NOT exist and the output dir is empty.
_snapshot_fail
TTM_FAKE_BIN="$(mktemp -d)"
cat > "$TTM_FAKE_BIN/python3" << 'TTM_PYEOF'
#!/usr/bin/env bash
_args="$*"
if [[ "$_args" == *'yaml.safe_load'* ]]; then
    exit 1
fi
exec /usr/bin/python3 "$@"
TTM_PYEOF
chmod +x "$TTM_FAKE_BIN/python3"
trap 'rm -rf "$TTM_FAKE_BIN"' EXIT

# Part (a): success path — output file must exist after validation passes
TTM_SUCCESS_DIR="$TMPDIR_OUTPUT/ttm_success"
mkdir -p "$TTM_SUCCESS_DIR"
CI_NONINTERACTIVE=1 bash "$SCRIPT" \
    --suites-json '[{"name":"unit","command":"make test","speed_class":"fast","runner":"make"}]' \
    --output-dir "$TTM_SUCCESS_DIR" \
    2>/dev/null || true
ttm_success_file_exists="no"
if [[ -f "$TTM_SUCCESS_DIR/ci.yml" ]]; then
    ttm_success_file_exists="yes"
fi
assert_eq "test_temp_then_move_pattern: success path writes ci.yml" \
    "yes" "$ttm_success_file_exists"

# Part (b): failure path — no stray files must remain in output dir
TTM_FAIL_DIR="$TMPDIR_OUTPUT/ttm_fail"
mkdir -p "$TTM_FAIL_DIR"
PATH="$TTM_FAKE_BIN:$PATH" CI_NONINTERACTIVE=1 bash "$SCRIPT" \
    --suites-json '[{"name":"unit","command":"make test","speed_class":"fast","runner":"make"}]' \
    --output-dir "$TTM_FAIL_DIR" \
    2>/dev/null || true
ttm_fail_dir_empty="yes"
ttm_fail_stray_count="$(find "$TTM_FAIL_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$ttm_fail_stray_count" -gt 0 ]]; then
    ttm_fail_dir_empty="no"
fi
assert_eq "test_temp_then_move_pattern: failure path leaves output dir empty" \
    "yes" "$ttm_fail_dir_empty"
assert_pass_if_clean "test_temp_then_move_pattern"

# ── test_no_validator_available_succeeds ──────────────────────────────────────
# When neither actionlint nor PyYAML is available, validate_yaml must return 0
# (skip validation) so the generator succeeds instead of exit 2.
_snapshot_fail
NOVAL_FAKE_BIN="$(mktemp -d)"
cat > "$NOVAL_FAKE_BIN/python3" << 'NOVAL_PYEOF'
#!/usr/bin/env bash
# Stub: pretend PyYAML is not installed (import yaml fails)
_args="$*"
if [[ "$_args" == *'import yaml'* ]]; then
    exit 1
fi
exec /usr/bin/python3 "$@"
NOVAL_PYEOF
chmod +x "$NOVAL_FAKE_BIN/python3"
# Also hide actionlint by putting our fake bin first and not including it
NOVAL_DIR="$TMPDIR_OUTPUT/no_validator"
mkdir -p "$NOVAL_DIR"
noval_exit=0
PATH="$NOVAL_FAKE_BIN:$PATH" CI_NONINTERACTIVE=1 bash "$SCRIPT" \
    --suites-json '[{"name":"unit","command":"make test","speed_class":"fast","runner":"make"}]' \
    --output-dir "$NOVAL_DIR" \
    2>/dev/null || noval_exit=$?
assert_eq "test_no_validator_available_succeeds: exit code is 0" \
    "0" "$noval_exit"
noval_file_exists="no"
if [[ -f "$NOVAL_DIR/ci.yml" ]]; then
    noval_file_exists="yes"
fi
assert_eq "test_no_validator_available_succeeds: ci.yml written despite no validator" \
    "yes" "$noval_file_exists"
rm -rf "$NOVAL_FAKE_BIN"
assert_pass_if_clean "test_no_validator_available_succeeds"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
