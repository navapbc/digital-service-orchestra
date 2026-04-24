#!/usr/bin/env bash
# tests/scripts/test-ci-generator-dogfooding.sh
# Dogfooding integration test: run ci-generator.sh on the DSO repo's own
# discovered test suites and verify the generated YAML is valid.
#
# This validates the end-to-end pipeline:
#   project-detect.sh --suites → ci-generator.sh → valid YAML output
#
# Tests covered:
#   1. test_project_detect_produces_valid_json
#   2. test_detect_discovers_expected_test_dirs
#   3. test_ci_generator_exits_0_on_dso_suites
#   4. test_ci_generator_produces_output_files
#   5. test_generated_yaml_passes_validation
#   6. test_job_ids_match_suite_names
#   7. test_slow_trigger_on_push_to_main
#
# Usage: bash tests/scripts/test-ci-generator-dogfooding.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/project-detect.sh"
GENERATOR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/onboarding/ci-generator.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-generator-dogfooding.sh ==="

# Temp dirs — cleaned up on exit
SUITES_JSON_FILE="$(mktemp)"
OUTPUT_DIR="$(mktemp -d)"
trap 'rm -f "$SUITES_JSON_FILE"; rm -rf "$OUTPUT_DIR"' EXIT

# ── test_project_detect_produces_valid_json ───────────────────────────────────
# project-detect.sh --suites must exit 0 and produce parseable JSON.
_snapshot_fail
detect_exit=0
bash "$DETECT_SCRIPT" --suites "$REPO_ROOT" > "$SUITES_JSON_FILE" 2>/dev/null || detect_exit=$?
assert_eq "test_project_detect_produces_valid_json: exit 0" \
    "0" "$detect_exit"

# Validate JSON with python3
json_valid="no"
if python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$SUITES_JSON_FILE" 2>/dev/null; then
    json_valid="yes"
fi
assert_eq "test_project_detect_produces_valid_json: output is valid JSON" \
    "yes" "$json_valid"

# Must be a non-empty JSON array
json_is_array="no"
json_has_entries="no"
if python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
assert isinstance(data, list), 'not a list'
assert len(data) > 0, 'empty list'
" "$SUITES_JSON_FILE" 2>/dev/null; then
    json_is_array="yes"
    json_has_entries="yes"
fi
assert_eq "test_project_detect_produces_valid_json: output is a non-empty JSON array" \
    "yes" "$json_is_array"
assert_pass_if_clean "test_project_detect_produces_valid_json"

# ── test_detect_discovers_expected_test_dirs ──────────────────────────────────
# The DSO repo has tests/hooks/, tests/scripts/, tests/plugin/, tests/skills/ —
# project-detect.sh must discover at least some of these.
_snapshot_fail
discovered_names="$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
print(','.join(sorted(e['name'] for e in data)))
" "$SUITES_JSON_FILE" 2>/dev/null || echo "")"

# At minimum we expect the 'scripts' suite (tests/scripts/ is where this test lives)
has_scripts="no"
if [[ "$discovered_names" == *"scripts"* ]]; then
    has_scripts="yes"
fi
assert_eq "test_detect_discovers_expected_test_dirs: 'scripts' suite discovered" \
    "yes" "$has_scripts"

# All discovered suites must have required fields: name, command, speed_class, runner
fields_ok="yes"
fields_check="$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
required = {'name', 'command', 'speed_class', 'runner'}
missing = []
for suite in data:
    for field in required:
        if field not in suite or not suite[field]:
            missing.append(suite.get('name','?') + '.' + field)
print(','.join(missing) if missing else 'ok')
" "$SUITES_JSON_FILE" 2>/dev/null || echo "parse_error")"
if [[ "$fields_check" != "ok" ]]; then
    fields_ok="no"
fi
assert_eq "test_detect_discovers_expected_test_dirs: all suites have required fields" \
    "yes" "$fields_ok"
assert_pass_if_clean "test_detect_discovers_expected_test_dirs"

# ── test_ci_generator_exits_0_on_dso_suites ──────────────────────────────────
# ci-generator.sh must exit 0 when given the DSO repo's discovered suites.
_snapshot_fail
gen_exit=0
bash "$GENERATOR_SCRIPT" \
    --suites-json="$SUITES_JSON_FILE" \
    --output-dir="$OUTPUT_DIR" \
    --non-interactive \
    2>/dev/null || gen_exit=$?
assert_eq "test_ci_generator_exits_0_on_dso_suites: exit 0" \
    "0" "$gen_exit"
assert_pass_if_clean "test_ci_generator_exits_0_on_dso_suites"

# ── test_ci_generator_produces_output_files ───────────────────────────────────
# ci-generator.sh must write at least one YAML file (ci.yml or ci-slow.yml).
# DSO suites are all speed_class=unknown → non-interactive defaults to slow →
# ci-slow.yml is expected; ci.yml may or may not be present.
_snapshot_fail
ci_yml_exists="no"
ci_slow_yml_exists="no"
[[ -f "$OUTPUT_DIR/ci.yml" ]] && ci_yml_exists="yes"
[[ -f "$OUTPUT_DIR/ci-slow.yml" ]] && ci_slow_yml_exists="yes"

at_least_one_file="no"
if [[ "$ci_yml_exists" == "yes" || "$ci_slow_yml_exists" == "yes" ]]; then
    at_least_one_file="yes"
fi
assert_eq "test_ci_generator_produces_output_files: at least one YAML file written" \
    "yes" "$at_least_one_file"

# Since all DSO suites have unknown speed_class, non-interactive mode puts them
# all in ci-slow.yml — verify that specifically.
assert_eq "test_ci_generator_produces_output_files: ci-slow.yml written for unknown suites" \
    "yes" "$ci_slow_yml_exists"
assert_pass_if_clean "test_ci_generator_produces_output_files"

# ── test_generated_yaml_passes_validation ─────────────────────────────────────
# All generated YAML files must pass python3 yaml.safe_load validation.
_snapshot_fail
yaml_errors=0
yaml_files_checked=0
for yml_file in "$OUTPUT_DIR"/*.yml; do
    [[ -f "$yml_file" ]] || continue
    (( yaml_files_checked++ ))
    if ! python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    yaml.safe_load(f)
" "$yml_file" 2>/dev/null; then
        (( yaml_errors++ ))
        printf "FAIL: %s failed yaml.safe_load\n" "$yml_file" >&2
    fi
done

assert_ne "test_generated_yaml_passes_validation: at least one file was checked" \
    "0" "$yaml_files_checked"
assert_eq "test_generated_yaml_passes_validation: zero YAML parse errors" \
    "0" "$yaml_errors"
assert_pass_if_clean "test_generated_yaml_passes_validation"

# ── test_job_ids_match_suite_names ────────────────────────────────────────────
# Each discovered suite name must appear as a job ID (prefixed with 'test-')
# inside the generated YAML file(s).
_snapshot_fail

# Collect all discovered suite names
suite_names="$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for e in data:
    print(e['name'])
" "$SUITES_JSON_FILE" 2>/dev/null || echo "")"

# Concatenate all generated YAML content for checking
all_yaml_content=""
for yml_file in "$OUTPUT_DIR"/*.yml; do
    [[ -f "$yml_file" ]] || continue
    all_yaml_content="${all_yaml_content}$(cat "$yml_file")"
done

missing_job_ids=""
while IFS= read -r suite_name; do
    [[ -z "$suite_name" ]] && continue
    # sanitize_job_id: lowercase, replace non-alphanumeric with '-', prefix 'test-'
    expected_job_id="test-$(printf '%s' "$suite_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | tr -s '-' | sed 's/^-//;s/-$//')"
    if [[ "$all_yaml_content" != *"${expected_job_id}:"* ]]; then
        missing_job_ids="${missing_job_ids} ${expected_job_id}"
    fi
done <<< "$suite_names"

job_ids_ok="yes"
if [[ -n "$missing_job_ids" ]]; then
    job_ids_ok="no"
    printf "FAIL: missing job IDs in generated YAML:%s\n" "$missing_job_ids" >&2
fi
assert_eq "test_job_ids_match_suite_names: all suite names produce job IDs in YAML" \
    "yes" "$job_ids_ok"
assert_pass_if_clean "test_job_ids_match_suite_names"

# ── test_slow_trigger_on_push_to_main ─────────────────────────────────────────
# ci-slow.yml must contain push trigger targeting the main branch.
# (DSO suites are unknown→slow, so ci-slow.yml must always be written here.)
_snapshot_fail
slow_has_push="no"
slow_has_main="no"
if [[ -f "$OUTPUT_DIR/ci-slow.yml" ]]; then
    slow_content="$(cat "$OUTPUT_DIR/ci-slow.yml")"
    [[ "$slow_content" == *"push"* ]] && slow_has_push="yes"
    [[ "$slow_content" == *"main"* ]] && slow_has_main="yes"
fi
assert_eq "test_slow_trigger_on_push_to_main: ci-slow.yml has push trigger" \
    "yes" "$slow_has_push"
assert_eq "test_slow_trigger_on_push_to_main: ci-slow.yml targets main branch" \
    "yes" "$slow_has_main"
assert_pass_if_clean "test_slow_trigger_on_push_to_main"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
