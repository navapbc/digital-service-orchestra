#!/usr/bin/env bash
# tests/scripts/test-ci-generator.sh
# RED-phase TDD tests for plugins/dso/scripts/ci-generator.sh
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
SCRIPT="$DSO_PLUGIN_DIR/scripts/ci-generator.sh"

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

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
