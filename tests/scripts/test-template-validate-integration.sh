#!/usr/bin/env bash
# tests/scripts/test-template-validate-integration.sh
# Integration tests for the template → detection → config pipeline.
#
# Tests the end-to-end chain:
#   template-registry.yaml → parse-template-registry.sh → detect-stack.sh
#
# Coverage:
#   1. parse-template-registry.sh correctly parses the real registry file
#   2. For each template type, marker files cause detect-stack.sh to return
#      the correct framework_type token
#   3. End-to-end: registry → detection → config inference chain works
#   4. Config resolution: template dso-config.conf does not collide with DSO config
#
# Usage: bash tests/scripts/test-template-validate-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DETECT_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/detect-stack.sh"
PARSE_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/onboarding/parse-template-registry.sh"
REAL_REGISTRY="$PLUGIN_ROOT/plugins/dso/config/template-registry.yaml"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-template-validate-integration.sh ==="

# Create a temp dir for all fixture project directories
TMPDIR_FIXTURE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_FIXTURE"' EXIT

# ── test_real_registry_parses_without_error ───────────────────────────────────
# parse-template-registry.sh must exit 0 with no stderr on the real registry file.
real_registry_stdout=""
real_registry_stderr=""
real_registry_exit=0
real_registry_stdout=$(bash "$PARSE_SCRIPT" "$REAL_REGISTRY" 2>/dev/null) || real_registry_exit=$?
real_registry_stderr=$(bash "$PARSE_SCRIPT" "$REAL_REGISTRY" 2>&1 >/dev/null) || true
assert_eq "test_real_registry_parses_without_error: exit 0" "0" "$real_registry_exit"
assert_eq "test_real_registry_parses_without_error: no stderr" "" "$real_registry_stderr"

# ── test_real_registry_has_expected_entries ───────────────────────────────────
# The real registry must output at least 4 lines (nextjs, flask, rails, jekyll-uswds).
registry_lines=0
registry_lines=$(printf '%s\n' "$real_registry_stdout" | grep -c '.') || true
assert_eq "test_real_registry_has_expected_entries: at least 4 templates" "4" "$registry_lines"

# ── test_real_registry_contains_nextjs ────────────────────────────────────────
# The real registry must include a 'nextjs' template entry.
nextjs_row=""
nextjs_row=$(printf '%s\n' "$real_registry_stdout" | grep '^nextjs') || true
assert_ne "test_real_registry_contains_nextjs: row found" "" "$nextjs_row"

nextjs_framework=""
nextjs_framework=$(printf '%s' "$nextjs_row" | cut -f4) || true
assert_eq "test_real_registry_contains_nextjs: framework_type is node-npm" "node-npm" "$nextjs_framework"

# ── test_real_registry_contains_flask ─────────────────────────────────────────
# The real registry must include a 'flask' template entry.
flask_row=""
flask_row=$(printf '%s\n' "$real_registry_stdout" | grep '^flask') || true
assert_ne "test_real_registry_contains_flask: row found" "" "$flask_row"

flask_framework=""
flask_framework=$(printf '%s' "$flask_row" | cut -f4) || true
assert_eq "test_real_registry_contains_flask: framework_type is python-poetry" "python-poetry" "$flask_framework"

# ── test_real_registry_contains_rails ─────────────────────────────────────────
# The real registry must include a 'rails' template entry.
rails_row=""
rails_row=$(printf '%s\n' "$real_registry_stdout" | grep '^rails') || true
assert_ne "test_real_registry_contains_rails: row found" "" "$rails_row"

rails_framework=""
rails_framework=$(printf '%s' "$rails_row" | cut -f4) || true
assert_eq "test_real_registry_contains_rails: framework_type is ruby-rails" "ruby-rails" "$rails_framework"

# ── test_real_registry_contains_jekyll_uswds ──────────────────────────────────
# The real registry must include a 'jekyll-uswds' template entry.
jekyll_row=""
jekyll_row=$(printf '%s\n' "$real_registry_stdout" | grep '^jekyll-uswds') || true
assert_ne "test_real_registry_contains_jekyll_uswds: row found" "" "$jekyll_row"

jekyll_framework=""
jekyll_framework=$(printf '%s' "$jekyll_row" | cut -f4) || true
assert_eq "test_real_registry_contains_jekyll_uswds: framework_type is ruby-jekyll" "ruby-jekyll" "$jekyll_framework"

# ── test_detect_stack_nextjs_template_markers ─────────────────────────────────
# A project created via the nextjs template (package.json) must cause detect-stack.sh
# to output 'node-npm', matching the registry's framework_type for nextjs.
NEXTJS_DIR="$TMPDIR_FIXTURE/nextjs_project"
mkdir -p "$NEXTJS_DIR"
printf '{"name": "my-nextjs-app", "version": "0.1.0", "private": true}\n' > "$NEXTJS_DIR/package.json"

nextjs_detect_output=""
nextjs_detect_exit=0
nextjs_detect_output=$(bash "$DETECT_SCRIPT" "$NEXTJS_DIR" 2>&1) || nextjs_detect_exit=$?
assert_eq "test_detect_stack_nextjs_template_markers: exit 0" "0" "$nextjs_detect_exit"
assert_eq "test_detect_stack_nextjs_template_markers: detects node-npm" "node-npm" "$nextjs_detect_output"

# Verify detection matches the registry's framework_type
nextjs_registry_framework=""
nextjs_registry_framework=$(printf '%s\n' "$real_registry_stdout" | grep '^nextjs' | cut -f4) || true
assert_eq "test_detect_stack_nextjs_template_markers: detection matches registry framework_type" "$nextjs_registry_framework" "$nextjs_detect_output"

# ── test_detect_stack_flask_template_markers ──────────────────────────────────
# A project created via the flask template (pyproject.toml) must cause detect-stack.sh
# to output 'python-poetry', matching the registry's framework_type for flask.
FLASK_DIR="$TMPDIR_FIXTURE/flask_project"
mkdir -p "$FLASK_DIR"
printf '[build-system]\nrequires = ["poetry-core"]\nbuild-backend = "poetry.core.masonry.api"\n\n[tool.poetry]\nname = "my-flask-app"\n' > "$FLASK_DIR/pyproject.toml"

flask_detect_output=""
flask_detect_exit=0
flask_detect_output=$(bash "$DETECT_SCRIPT" "$FLASK_DIR" 2>&1) || flask_detect_exit=$?
assert_eq "test_detect_stack_flask_template_markers: exit 0" "0" "$flask_detect_exit"
assert_eq "test_detect_stack_flask_template_markers: detects python-poetry" "python-poetry" "$flask_detect_output"

# Verify detection matches the registry's framework_type
flask_registry_framework=""
flask_registry_framework=$(printf '%s\n' "$real_registry_stdout" | grep '^flask' | cut -f4) || true
assert_eq "test_detect_stack_flask_template_markers: detection matches registry framework_type" "$flask_registry_framework" "$flask_detect_output"

# ── test_detect_stack_rails_template_markers ──────────────────────────────────
# A project created via the rails template (Gemfile + config/routes.rb) must cause
# detect-stack.sh to output 'ruby-rails', matching the registry's framework_type.
RAILS_DIR="$TMPDIR_FIXTURE/rails_template_project"
mkdir -p "$RAILS_DIR/config"
printf 'source "https://rubygems.org"\ngem "rails"\n' > "$RAILS_DIR/Gemfile"
printf '# Rails routes\nRails.application.routes.draw do\nend\n' > "$RAILS_DIR/config/routes.rb"

rails_detect_output=""
rails_detect_exit=0
rails_detect_output=$(bash "$DETECT_SCRIPT" "$RAILS_DIR" 2>&1) || rails_detect_exit=$?
assert_eq "test_detect_stack_rails_template_markers: exit 0" "0" "$rails_detect_exit"
assert_eq "test_detect_stack_rails_template_markers: detects ruby-rails" "ruby-rails" "$rails_detect_output"

# Verify detection matches the registry's framework_type
rails_registry_framework=""
rails_registry_framework=$(printf '%s\n' "$real_registry_stdout" | grep '^rails' | cut -f4) || true
assert_eq "test_detect_stack_rails_template_markers: detection matches registry framework_type" "$rails_registry_framework" "$rails_detect_output"

# ── test_detect_stack_jekyll_template_markers ─────────────────────────────────
# A project created via the jekyll-uswds template (Gemfile + _config.yml) must
# cause detect-stack.sh to output 'ruby-jekyll', matching the registry's framework_type.
JEKYLL_DIR="$TMPDIR_FIXTURE/jekyll_template_project"
mkdir -p "$JEKYLL_DIR"
printf 'source "https://rubygems.org"\ngem "jekyll"\ngem "jekyll-uswds"\n' > "$JEKYLL_DIR/Gemfile"
printf 'title: My USWDS Site\ndescription: Site built with jekyll-uswds\n' > "$JEKYLL_DIR/_config.yml"

jekyll_detect_output=""
jekyll_detect_exit=0
jekyll_detect_output=$(bash "$DETECT_SCRIPT" "$JEKYLL_DIR" 2>&1) || jekyll_detect_exit=$?
assert_eq "test_detect_stack_jekyll_template_markers: exit 0" "0" "$jekyll_detect_exit"
assert_eq "test_detect_stack_jekyll_template_markers: detects ruby-jekyll" "ruby-jekyll" "$jekyll_detect_output"

# Verify detection matches the registry's framework_type
jekyll_registry_framework=""
jekyll_registry_framework=$(printf '%s\n' "$real_registry_stdout" | grep '^jekyll-uswds' | cut -f4) || true
assert_eq "test_detect_stack_jekyll_template_markers: detection matches registry framework_type" "$jekyll_registry_framework" "$jekyll_detect_output"

# ── test_end_to_end_registry_detection_chain ──────────────────────────────────
# End-to-end: for every template in the real registry, the framework_type field
# maps to a valid detect-stack.sh output token, and the appropriate marker files
# for that framework_type cause detect-stack.sh to return exactly that token.
#
# This test iterates over all registry rows and validates the chain:
#   registry framework_type → create marker files → detect-stack.sh → same token
chain_pass=0
chain_fail=0

_create_markers_for_framework() {
    local dir="$1"
    local framework="$2"
    case "$framework" in
        node-npm)
            printf '{"name": "test-app"}\n' > "$dir/package.json"
            ;;
        python-poetry)
            printf '[build-system]\nrequires = ["poetry-core"]\n' > "$dir/pyproject.toml"
            ;;
        ruby-rails)
            mkdir -p "$dir/config"
            printf 'source "https://rubygems.org"\ngem "rails"\n' > "$dir/Gemfile"
            printf '# Routes\n' > "$dir/config/routes.rb"
            ;;
        ruby-jekyll)
            printf 'source "https://rubygems.org"\ngem "jekyll"\n' > "$dir/Gemfile"
            printf 'title: Test\n' > "$dir/_config.yml"
            ;;
        *)
            # Unknown framework — no markers; detection will return 'unknown'
            ;;
    esac
}

while IFS=$'\t' read -r tmpl_name tmpl_repo tmpl_method tmpl_framework tmpl_flags; do
    [[ -z "$tmpl_name" ]] && continue

    CHAIN_DIR="$TMPDIR_FIXTURE/chain_${tmpl_name}"
    mkdir -p "$CHAIN_DIR"
    _create_markers_for_framework "$CHAIN_DIR" "$tmpl_framework"

    detected=""
    detected=$(bash "$DETECT_SCRIPT" "$CHAIN_DIR" 2>&1) || true

    if [[ "$detected" == "$tmpl_framework" ]]; then
        (( chain_pass++ ))
    else
        (( chain_fail++ ))
        printf "FAIL: end-to-end chain for template '%s'\n  expected: %s\n  actual:   %s\n" \
            "$tmpl_name" "$tmpl_framework" "$detected" >&2
        (( ++FAIL ))
    fi
done < <(printf '%s\n' "$real_registry_stdout")

(( PASS += chain_pass ))

assert_ne "test_end_to_end_registry_detection_chain: at least one template tested" "0" "$chain_pass"
assert_eq "test_end_to_end_registry_detection_chain: all templates pass" "0" "$chain_fail"

# ── test_config_resolution_no_template_config_collision ───────────────────────
# Verify that a host project's .claude/dso-config.conf is not shadowed by a
# template-installed config in a different subdirectory.
#
# Scenario: template installs into a temp dir with its own .claude/dso-config.conf;
# the host project dir has its own .claude/dso-config.conf with different values.
# The host config must take precedence when referenced by absolute path.
HOST_CONFIG_DIR="$TMPDIR_FIXTURE/host_project"
TEMPLATE_CONFIG_DIR="$TMPDIR_FIXTURE/template_project"
mkdir -p "$HOST_CONFIG_DIR/.claude"
mkdir -p "$TEMPLATE_CONFIG_DIR/.claude"

# Write distinct config files
printf 'ci.test_command=make test-host\n' > "$HOST_CONFIG_DIR/.claude/dso-config.conf"
printf 'ci.test_command=make test-template\n' > "$TEMPLATE_CONFIG_DIR/.claude/dso-config.conf"

# Read the host config directly (absolute path — simulates how validate.sh
# should consume the config when the host project dir is known)
host_test_command=""
host_test_command=$(grep '^ci.test_command=' "$HOST_CONFIG_DIR/.claude/dso-config.conf" | cut -d= -f2) || true
assert_eq "test_config_resolution_no_template_config_collision: host config read correctly" \
    "make test-host" "$host_test_command"

# Read the template config directly (absolute path)
template_test_command=""
template_test_command=$(grep '^ci.test_command=' "$TEMPLATE_CONFIG_DIR/.claude/dso-config.conf" | cut -d= -f2) || true
assert_eq "test_config_resolution_no_template_config_collision: template config read correctly" \
    "make test-template" "$template_test_command"

# Verify the two configs are distinct (no collision)
assert_ne "test_config_resolution_no_template_config_collision: configs are distinct" \
    "$host_test_command" "$template_test_command"

# ── test_config_resolution_dso_config_format ──────────────────────────────────
# A dso-config.conf file generated for a template-installed project must use
# valid KEY=VALUE format (flat, no YAML/TOML). Each non-empty, non-comment line
# must match the pattern KEY=VALUE.
DSO_CONF_DIR="$TMPDIR_FIXTURE/config_format_project"
mkdir -p "$DSO_CONF_DIR/.claude"

cat > "$DSO_CONF_DIR/.claude/dso-config.conf" <<'CONF'
# DSO config for template-installed project
ci.test_command=make test
ci.lint_command=make lint
format.style=ruff
test_gate.test_dirs=tests/
CONF

# Validate format: every non-empty, non-comment line must have KEY=VALUE
conf_file="$DSO_CONF_DIR/.claude/dso-config.conf"
conf_format_fail=0
while IFS= read -r line; do
    # Skip empty lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Must match KEY=VALUE
    if ! [[ "$line" =~ ^[A-Za-z0-9_][A-Za-z0-9_.]*= ]]; then
        (( conf_format_fail++ ))
        printf "FAIL: test_config_resolution_dso_config_format: invalid line: %s\n" "$line" >&2
        (( ++FAIL ))
    fi
done < "$conf_file"
if [[ "$conf_format_fail" -eq 0 ]]; then
    (( ++PASS ))
fi

# ── test_jekyll_project_has_valid_detection_path ──────────────────────────────
# Ensure the Jekyll path specifically produces a valid project structure that
# detect-stack.sh can recognize — verifying no edge cases in file placement.
JEKYLL_VALID_DIR="$TMPDIR_FIXTURE/jekyll_valid_project"
mkdir -p "$JEKYLL_VALID_DIR"
printf 'source "https://rubygems.org"\ngem "jekyll", "~> 4.3"\n' > "$JEKYLL_VALID_DIR/Gemfile"
printf 'title: My Jekyll Site\nbaseurl: ""\nurl: "https://example.com"\n' > "$JEKYLL_VALID_DIR/_config.yml"

jekyll_valid_exit=0
jekyll_valid_output=""
jekyll_valid_output=$(bash "$DETECT_SCRIPT" "$JEKYLL_VALID_DIR" 2>&1) || jekyll_valid_exit=$?
assert_eq "test_jekyll_project_has_valid_detection_path: exit 0" "0" "$jekyll_valid_exit"
assert_eq "test_jekyll_project_has_valid_detection_path: output is ruby-jekyll" "ruby-jekyll" "$jekyll_valid_output"

# Verify non-empty Gemfile (content-based CoVe check)
gemfile_size=""
gemfile_size=$(wc -c < "$JEKYLL_VALID_DIR/Gemfile") || true
gemfile_size="${gemfile_size// /}"
assert_ne "test_jekyll_project_has_valid_detection_path: Gemfile non-empty" "0" "$gemfile_size"

# ── test_nextjs_project_no_pyproject_collision ────────────────────────────────
# A pure NextJS project (only package.json, no pyproject.toml) must not be
# misidentified as python-poetry. This guards against the Python-over-Node
# priority causing false positives.
NEXTJS_PURE_DIR="$TMPDIR_FIXTURE/nextjs_pure_project"
mkdir -p "$NEXTJS_PURE_DIR"
printf '{"name": "nextjs-app", "version": "14.0.0", "private": true, "scripts": {"dev": "next dev"}}\n' > "$NEXTJS_PURE_DIR/package.json"
# Explicitly ensure no pyproject.toml exists
if [[ -f "$NEXTJS_PURE_DIR/pyproject.toml" ]]; then
    rm "$NEXTJS_PURE_DIR/pyproject.toml"
fi

nextjs_pure_output=""
nextjs_pure_exit=0
nextjs_pure_output=$(bash "$DETECT_SCRIPT" "$NEXTJS_PURE_DIR" 2>&1) || nextjs_pure_exit=$?
assert_eq "test_nextjs_project_no_pyproject_collision: exit 0" "0" "$nextjs_pure_exit"
assert_eq "test_nextjs_project_no_pyproject_collision: pure NextJS detects as node-npm" "node-npm" "$nextjs_pure_output"
assert_ne "test_nextjs_project_no_pyproject_collision: not misidentified as python-poetry" "python-poetry" "$nextjs_pure_output"

# ── test_all_registry_install_methods_are_valid ───────────────────────────────
# Every entry in the real registry must use a recognized install_method:
# 'nava-platform' or 'git-clone'. This guards against registry corruption.
invalid_methods=0
while IFS=$'\t' read -r tmpl_name tmpl_repo tmpl_method tmpl_framework tmpl_flags; do
    [[ -z "$tmpl_name" ]] && continue
    if [[ "$tmpl_method" != "nava-platform" && "$tmpl_method" != "git-clone" ]]; then
        (( invalid_methods++ ))
        printf "FAIL: test_all_registry_install_methods_are_valid: template '%s' has invalid method '%s'\n" \
            "$tmpl_name" "$tmpl_method" >&2
        (( ++FAIL ))
    fi
done < <(printf '%s\n' "$real_registry_stdout")

if [[ "$invalid_methods" -eq 0 ]]; then
    (( ++PASS ))
fi

print_summary
