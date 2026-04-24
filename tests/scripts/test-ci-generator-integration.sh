#!/usr/bin/env bash
# tests/scripts/test-ci-generator-integration.sh
# Integration test: full discover → generate → validate → write workflow for new project
#
# Exercises the complete pipeline:
#   project-detect.sh --suites → ci-generator.sh → YAML validation → written files
#
# Test scenarios:
#   1. test_full_workflow_makefile_project        — fixture project with Makefile test targets
#   2. test_full_workflow_no_suites_fallback      — project with no Makefile/test dirs
#   3. test_full_workflow_validation_blocks_write — injected YAML validation failure
#   4. test_job_ids_unique_per_suite             — two suites produce two distinct job IDs
#
# Usage: bash tests/scripts/test-ci-generator-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
DETECT_SCRIPT="$DSO_PLUGIN_DIR/scripts/onboarding/project-detect.sh"
GENERATOR_SCRIPT="$DSO_PLUGIN_DIR/scripts/onboarding/ci-generator.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ci-generator-integration.sh ==="

# ── Temp dir setup ─────────────────────────────────────────────────────────────
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ── Helper: create a minimal mock project directory ───────────────────────────
# Usage: _make_project <name>
# Returns the path to the created project directory.
_make_project() {
    local name="$1"
    local dir="$WORK_DIR/$name"
    mkdir -p "$dir"
    echo "$dir"
}

# ── Helper: run full pipeline ─────────────────────────────────────────────────
# Usage: _run_pipeline <project_dir> <output_dir>
# Runs project-detect.sh --suites | ci-generator.sh --non-interactive
# Returns the exit code of ci-generator.sh.
_run_pipeline() {
    local project_dir="$1"
    local output_dir="$2"
    mkdir -p "$output_dir"

    local suites_json
    suites_json="$(bash "$DETECT_SCRIPT" --suites "$project_dir" 2>/dev/null)"

    CI_NONINTERACTIVE=1 bash "$GENERATOR_SCRIPT" \
        --suites-json "$suites_json" \
        --output-dir "$output_dir" \
        2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# test_full_workflow_makefile_project
# ─────────────────────────────────────────────────────────────────────────────
# Fixture: a mock project with a Makefile containing test-unit (fast via config)
# and test-e2e (slow via config) targets.  Run the full pipeline and verify:
#   - ci.yml is created and contains the "test-unit" job
#   - ci-slow.yml is created and contains the "test-e2e" job
#   - Both files contain valid YAML (parseable by python3)
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail

MAKEFILE_PROJECT="$(_make_project "makefile_project")"

# Create Makefile with two test targets
cat > "$MAKEFILE_PROJECT/Makefile" << 'MAKEFILE_EOF'
.PHONY: test-unit test-e2e

test-unit:
	@echo "running unit tests"

test-e2e:
	@echo "running e2e tests"
MAKEFILE_EOF

# Provide a dso-config.conf with speed_class overrides so pipeline classifies
# test-unit as fast and test-e2e as slow (without needing interactive prompts).
mkdir -p "$MAKEFILE_PROJECT/.claude"
cat > "$MAKEFILE_PROJECT/.claude/dso-config.conf" << 'CONF_EOF'
test.suite.unit.speed_class=fast
test.suite.e2e.speed_class=slow
CONF_EOF

MAKEFILE_OUT="$WORK_DIR/makefile_out"
_run_pipeline "$MAKEFILE_PROJECT" "$MAKEFILE_OUT" || true

# ci.yml must exist
assert_eq "test_full_workflow_makefile_project: ci.yml created" \
    "yes" "$(test -f "$MAKEFILE_OUT/ci.yml" && echo yes || echo no)"

# ci-slow.yml must exist
assert_eq "test_full_workflow_makefile_project: ci-slow.yml created" \
    "yes" "$(test -f "$MAKEFILE_OUT/ci-slow.yml" && echo yes || echo no)"

# ci.yml must contain the test-unit job
ci_yml_content=""
if [[ -f "$MAKEFILE_OUT/ci.yml" ]]; then
    ci_yml_content="$(cat "$MAKEFILE_OUT/ci.yml")"
fi
assert_contains "test_full_workflow_makefile_project: test-unit job in ci.yml" \
    "test-unit" "$ci_yml_content"

# ci-slow.yml must contain the test-e2e job
ci_slow_content=""
if [[ -f "$MAKEFILE_OUT/ci-slow.yml" ]]; then
    ci_slow_content="$(cat "$MAKEFILE_OUT/ci-slow.yml")"
fi
assert_contains "test_full_workflow_makefile_project: test-e2e job in ci-slow.yml" \
    "test-e2e" "$ci_slow_content"

# ci.yml must be valid YAML
ci_yml_valid="no"
if [[ -f "$MAKEFILE_OUT/ci.yml" ]]; then
    if python3 -c "import yaml; yaml.safe_load(open('$MAKEFILE_OUT/ci.yml'))" 2>/dev/null; then
        ci_yml_valid="yes"
    fi
fi
assert_eq "test_full_workflow_makefile_project: ci.yml is valid YAML" \
    "yes" "$ci_yml_valid"

# ci-slow.yml must be valid YAML
ci_slow_valid="no"
if [[ -f "$MAKEFILE_OUT/ci-slow.yml" ]]; then
    if python3 -c "import yaml; yaml.safe_load(open('$MAKEFILE_OUT/ci-slow.yml'))" 2>/dev/null; then
        ci_slow_valid="yes"
    fi
fi
assert_eq "test_full_workflow_makefile_project: ci-slow.yml is valid YAML" \
    "yes" "$ci_slow_valid"

# ci.yml must contain pull_request trigger
assert_contains "test_full_workflow_makefile_project: ci.yml has pull_request trigger" \
    "pull_request" "$ci_yml_content"

# ci-slow.yml must contain push to main trigger
assert_contains "test_full_workflow_makefile_project: ci-slow.yml has push trigger" \
    "push" "$ci_slow_content"
assert_contains "test_full_workflow_makefile_project: ci-slow.yml has main branch" \
    "main" "$ci_slow_content"

assert_pass_if_clean "test_full_workflow_makefile_project"

# ─────────────────────────────────────────────────────────────────────────────
# test_full_workflow_no_suites_fallback
# ─────────────────────────────────────────────────────────────────────────────
# Fixture: a project with no Makefile, no tests/ dir, no package.json.
# project-detect.sh --suites should return an empty JSON array [].
# ci-generator.sh must exit 0 and write NO output files.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail

EMPTY_PROJECT="$(_make_project "empty_project")"
# No Makefile, no tests/, no package.json — just an empty dir

EMPTY_OUT="$WORK_DIR/empty_out"
empty_exit=0
_run_pipeline "$EMPTY_PROJECT" "$EMPTY_OUT" || empty_exit=$?

assert_eq "test_full_workflow_no_suites_fallback: generator exits 0" \
    "0" "$empty_exit"

assert_eq "test_full_workflow_no_suites_fallback: ci.yml not created" \
    "no" "$(test -f "$EMPTY_OUT/ci.yml" && echo yes || echo no)"

assert_eq "test_full_workflow_no_suites_fallback: ci-slow.yml not created" \
    "no" "$(test -f "$EMPTY_OUT/ci-slow.yml" && echo yes || echo no)"

assert_pass_if_clean "test_full_workflow_no_suites_fallback"

# ─────────────────────────────────────────────────────────────────────────────
# test_full_workflow_validation_blocks_write
# ─────────────────────────────────────────────────────────────────────────────
# Verifies the write guard: when YAML validation fails (mocked python3 that
# always exits non-zero for yaml.safe_load), the final output file must NOT
# be written and the generator must exit 2.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail

# Create a mock python3 that fails yaml.safe_load but passes everything else
VALIDATION_FAKE_BIN="$(mktemp -d)"
cat > "$VALIDATION_FAKE_BIN/python3" << 'FAKE_PYEOF'
#!/usr/bin/env bash
# Stub: make yaml.safe_load always fail; delegate everything else to real python3
_args="$*"
if [[ "$_args" == *'yaml.safe_load'* ]]; then
    exit 1
fi
exec /usr/bin/python3 "$@"
FAKE_PYEOF
chmod +x "$VALIDATION_FAKE_BIN/python3"
trap 'rm -rf "$VALIDATION_FAKE_BIN"' EXIT

# Use a known-good JSON directly (bypassing project-detect.sh) to ensure
# the generator reaches the validation step.
VAL_GUARD_OUT="$WORK_DIR/val_guard_out"
mkdir -p "$VAL_GUARD_OUT"
val_guard_exit=0
PATH="$VALIDATION_FAKE_BIN:$PATH" CI_NONINTERACTIVE=1 bash "$GENERATOR_SCRIPT" \
    --suites-json '[{"name":"unit","command":"make test-unit","speed_class":"fast","runner":"make"}]' \
    --output-dir "$VAL_GUARD_OUT" \
    2>/dev/null || val_guard_exit=$?

assert_eq "test_full_workflow_validation_blocks_write: generator exits 2 on invalid YAML" \
    "2" "$val_guard_exit"

assert_eq "test_full_workflow_validation_blocks_write: ci.yml not written on failure" \
    "no" "$(test -f "$VAL_GUARD_OUT/ci.yml" && echo yes || echo no)"

# Output dir must be empty (no stray temp files)
val_guard_stray_count="$(find "$VAL_GUARD_OUT" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "test_full_workflow_validation_blocks_write: no stray files in output dir" \
    "0" "$val_guard_stray_count"

assert_pass_if_clean "test_full_workflow_validation_blocks_write"

# ─────────────────────────────────────────────────────────────────────────────
# test_job_ids_unique_per_suite
# ─────────────────────────────────────────────────────────────────────────────
# Fixture: a Makefile project with two distinct test targets — test-api and
# test-smoke (both fast via config).  The pipeline must produce a ci.yml
# containing both "test-api" and "test-smoke" job IDs with no collision.
# ─────────────────────────────────────────────────────────────────────────────
_snapshot_fail

MULTI_PROJECT="$(_make_project "multi_suite_project")"

cat > "$MULTI_PROJECT/Makefile" << 'MAKEFILE_EOF'
.PHONY: test-api test-smoke

test-api:
	@echo "running API tests"

test-smoke:
	@echo "running smoke tests"
MAKEFILE_EOF

mkdir -p "$MULTI_PROJECT/.claude"
cat > "$MULTI_PROJECT/.claude/dso-config.conf" << 'CONF_EOF'
test.suite.api.speed_class=fast
test.suite.smoke.speed_class=fast
CONF_EOF

MULTI_OUT="$WORK_DIR/multi_out"
_run_pipeline "$MULTI_PROJECT" "$MULTI_OUT" || true

multi_ci_content=""
if [[ -f "$MULTI_OUT/ci.yml" ]]; then
    multi_ci_content="$(cat "$MULTI_OUT/ci.yml")"
fi

# Both job IDs must appear in ci.yml
assert_contains "test_job_ids_unique_per_suite: test-api job present in ci.yml" \
    "test-api" "$multi_ci_content"

assert_contains "test_job_ids_unique_per_suite: test-smoke job present in ci.yml" \
    "test-smoke" "$multi_ci_content"

# Count distinct job IDs — each must appear exactly once as a YAML key
api_count="$(printf '%s\n' "$multi_ci_content" | grep -c '^  test-api:' 2>/dev/null || echo 0)"
smoke_count="$(printf '%s\n' "$multi_ci_content" | grep -c '^  test-smoke:' 2>/dev/null || echo 0)"

assert_eq "test_job_ids_unique_per_suite: test-api job ID appears exactly once" \
    "1" "$api_count"

assert_eq "test_job_ids_unique_per_suite: test-smoke job ID appears exactly once" \
    "1" "$smoke_count"

# No collision — the two job IDs must be different strings
assert_ne "test_job_ids_unique_per_suite: job IDs are distinct" \
    "test-api" "test-smoke"

# The generated YAML must remain valid with two jobs present
multi_ci_valid="no"
if [[ -f "$MULTI_OUT/ci.yml" ]]; then
    if python3 -c "import yaml; yaml.safe_load(open('$MULTI_OUT/ci.yml'))" 2>/dev/null; then
        multi_ci_valid="yes"
    fi
fi
assert_eq "test_job_ids_unique_per_suite: ci.yml with two jobs is valid YAML" \
    "yes" "$multi_ci_valid"

assert_pass_if_clean "test_job_ids_unique_per_suite"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
