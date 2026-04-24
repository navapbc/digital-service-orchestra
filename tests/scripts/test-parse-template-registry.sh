#!/usr/bin/env bash
# tests/scripts/test-parse-template-registry.sh
# TDD red-phase tests for plugins/dso/scripts/onboarding/parse-template-registry.sh
#
# Usage: bash tests/scripts/test-parse-template-registry.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until parse-template-registry.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/onboarding/parse-template-registry.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-parse-template-registry.sh ==="

# Shared temp dir for all fixture files; cleaned up on exit
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# Helper: write a 4-entry valid registry YAML fixture to a given path
_write_valid_4_entry_fixture() {
    local path="$1"
    cat > "$path" <<'YAML'
templates:
  - name: django-app
    repo_url: https://github.com/example/django-app
    description: "Django web application template"
    install_method: git-clone
    framework_type: django
    required_data_flags: []
  - name: flask-service
    repo_url: https://github.com/example/flask-service
    description: "Flask microservice template"
    install_method: git-clone
    framework_type: flask
    required_data_flags: []
  - name: react-frontend
    repo_url: https://github.com/example/react-frontend
    description: "React frontend template"
    install_method: git-clone
    framework_type: react
    required_data_flags: []
  - name: fastapi-service
    repo_url: https://github.com/example/fastapi-service
    description: "FastAPI service template"
    install_method: git-clone
    framework_type: fastapi
    required_data_flags: []
YAML
}

# ── test_parser_returns_all_templates ─────────────────────────────────────────
# A registry with 4 valid entries must produce exactly 4 lines of output (one
# tab-separated row per template, no header).
FIXTURE_4="$TMPDIR_FIXTURE/valid_4.yaml"
_write_valid_4_entry_fixture "$FIXTURE_4"

parser_4_output=""
parser_4_exit=0
parser_4_output=$(bash "$SCRIPT" "$FIXTURE_4" 2>/dev/null) || parser_4_exit=$?
assert_eq "test_parser_returns_all_templates: exit 0" "0" "$parser_4_exit"
parser_4_lines=$(printf '%s\n' "$parser_4_output" | grep -c '.')
assert_eq "test_parser_returns_all_templates: 4 output lines" "4" "$parser_4_lines"

# ── test_parser_outputs_correct_columns ───────────────────────────────────────
# The first output row for 'django-app' must be tab-separated; columns 1, 3, 4
# (name, install_method, framework_type) must match the fixture values.
FIXTURE_COLS="$TMPDIR_FIXTURE/valid_cols.yaml"
_write_valid_4_entry_fixture "$FIXTURE_COLS"

cols_output=""
cols_exit=0
cols_output=$(bash "$SCRIPT" "$FIXTURE_COLS" 2>/dev/null) || cols_exit=$?
assert_eq "test_parser_outputs_correct_columns: exit 0" "0" "$cols_exit"
cols_first_line=$(printf '%s\n' "$cols_output" | head -1)
col1=$(printf '%s' "$cols_first_line" | cut -f1)
col3=$(printf '%s' "$cols_first_line" | cut -f3)
col4=$(printf '%s' "$cols_first_line" | cut -f4)
assert_eq "test_parser_outputs_correct_columns: col1 is name" "django-app" "$col1"
assert_eq "test_parser_outputs_correct_columns: col3 is install_method" "git-clone" "$col3"
assert_eq "test_parser_outputs_correct_columns: col4 is framework_type" "django" "$col4"

# ── test_parser_outputs_data_flags_column ─────────────────────────────────────
# When required_data_flags contains [org, app_name], the fifth tab-separated
# column must be the comma-joined string "org,app_name".
FIXTURE_FLAGS="$TMPDIR_FIXTURE/flags.yaml"
cat > "$FIXTURE_FLAGS" <<'YAML'
templates:
  - name: org-app-template
    repo_url: https://github.com/example/org-app
    description: "Template requiring org and app_name"
    install_method: git-clone
    framework_type: django
    required_data_flags: [org, app_name]
YAML

flags_output=""
flags_exit=0
flags_output=$(bash "$SCRIPT" "$FIXTURE_FLAGS" 2>/dev/null) || flags_exit=$?
assert_eq "test_parser_outputs_data_flags_column: exit 0" "0" "$flags_exit"
flags_col5=$(printf '%s\n' "$flags_output" | head -1 | cut -f5)
assert_eq "test_parser_outputs_data_flags_column: col5 is comma-joined flags" "org,app_name" "$flags_col5"

# ── test_parser_validates_required_fields ─────────────────────────────────────
# A fixture missing the required 'repo_url' field must cause a non-zero exit
# and print "missing required field" to stderr.
FIXTURE_MISSING="$TMPDIR_FIXTURE/missing_repo_url.yaml"
cat > "$FIXTURE_MISSING" <<'YAML'
templates:
  - name: incomplete-template
    description: "Template missing repo_url"
    install_method: git-clone
    framework_type: django
    required_data_flags: []
YAML

missing_stdout=""
missing_stderr=""
missing_exit=0
missing_stderr=$(bash "$SCRIPT" "$FIXTURE_MISSING" 2>&1 >/dev/null) || missing_exit=$?
assert_ne "test_parser_validates_required_fields: non-zero exit" "0" "$missing_exit"
assert_contains "test_parser_validates_required_fields: stderr has 'missing required field'" "missing required field" "$missing_stderr"

# ── test_parser_allowlists_install_method ─────────────────────────────────────
# A fixture with install_method set to an invalid value ('docker') must cause a
# non-zero exit and print "invalid install_method" to stderr.
FIXTURE_DOCKER="$TMPDIR_FIXTURE/invalid_install_method.yaml"
cat > "$FIXTURE_DOCKER" <<'YAML'
templates:
  - name: docker-template
    repo_url: https://github.com/example/docker-template
    description: "Template with disallowed install_method"
    install_method: docker
    framework_type: django
    required_data_flags: []
YAML

docker_stderr=""
docker_exit=0
docker_stderr=$(bash "$SCRIPT" "$FIXTURE_DOCKER" 2>&1 >/dev/null) || docker_exit=$?
assert_ne "test_parser_allowlists_install_method: non-zero exit" "0" "$docker_exit"
assert_contains "test_parser_allowlists_install_method: stderr has 'invalid install_method'" "invalid install_method" "$docker_stderr"

# ── test_parser_detects_unknown_keys ──────────────────────────────────────────
# A fixture with a typo key ('instal_method' instead of 'install_method') must
# produce a warning containing "unknown key" on stderr while still exiting 0.
FIXTURE_TYPO="$TMPDIR_FIXTURE/typo_key.yaml"
cat > "$FIXTURE_TYPO" <<'YAML'
templates:
  - name: typo-template
    repo_url: https://github.com/example/typo-template
    description: "Template with a typo key"
    instal_method: git-clone
    framework_type: django
    required_data_flags: []
YAML

typo_stderr=""
typo_exit=0
typo_stderr=$(bash "$SCRIPT" "$FIXTURE_TYPO" 2>&1 >/dev/null) || typo_exit=$?
assert_contains "test_parser_detects_unknown_keys: stderr has 'unknown key'" "unknown key" "$typo_stderr"

# ── test_parser_handles_missing_file ──────────────────────────────────────────
# When the path argument points to a non-existent file, the parser must exit 0,
# produce empty stdout, and emit a warning to stderr.
missing_file_tmpout="$TMPDIR_FIXTURE/missing_file_stdout.txt"
missing_file_tmperr="$TMPDIR_FIXTURE/missing_file_stderr.txt"
bash "$SCRIPT" "/nonexistent.yaml" >"$missing_file_tmpout" 2>"$missing_file_tmperr"
missing_file_exit=$?
missing_file_stdout=$(cat "$missing_file_tmpout")
missing_file_stderr=$(cat "$missing_file_tmperr")
assert_eq "test_parser_handles_missing_file: exit 0" "0" "$missing_file_exit"
assert_eq "test_parser_handles_missing_file: empty stdout" "" "$missing_file_stdout"
assert_ne "test_parser_handles_missing_file: non-empty stderr warning" "" "$missing_file_stderr"

# ── test_parser_handles_malformed_yaml ────────────────────────────────────────
# When the registry file contains invalid YAML syntax, the parser must exit 0,
# produce empty stdout, and emit a warning to stderr.
FIXTURE_BAD_YAML="$TMPDIR_FIXTURE/malformed.yaml"
cat > "$FIXTURE_BAD_YAML" <<'YAML'
templates:
  - name: broken
    repo_url: [unclosed bracket
    description: {bad: yaml: structure
YAML

bad_yaml_tmpout="$TMPDIR_FIXTURE/bad_yaml_stdout.txt"
bad_yaml_tmperr="$TMPDIR_FIXTURE/bad_yaml_stderr.txt"
bash "$SCRIPT" "$FIXTURE_BAD_YAML" >"$bad_yaml_tmpout" 2>"$bad_yaml_tmperr"
bad_yaml_exit=$?
bad_yaml_stdout=$(cat "$bad_yaml_tmpout")
bad_yaml_stderr=$(cat "$bad_yaml_tmperr")
assert_eq "test_parser_handles_malformed_yaml: exit 0" "0" "$bad_yaml_exit"
assert_eq "test_parser_handles_malformed_yaml: empty stdout" "" "$bad_yaml_stdout"
assert_ne "test_parser_handles_malformed_yaml: non-empty stderr warning" "" "$bad_yaml_stderr"

print_summary
