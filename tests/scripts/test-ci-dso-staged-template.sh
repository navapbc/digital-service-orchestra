#!/usr/bin/env bash
# tests/scripts/test-ci-dso-staged-template.sh
# RED-phase structural tests for plugins/dso/templates/ci-dso-staged.yml
#
# All tests that depend on the template file will FAIL (RED) until
# plugins/dso/templates/ci-dso-staged.yml is created.
# test_template_file_exists is the hard RED gate — it fails when the file is missing,
# causing the suite to exit non-zero before any further assertions run.
#
# Tests covered:
#   1. test_template_file_exists           — file missing → RED
#   2. test_yaml_is_parseable              — python3 yaml.safe_load succeeds
#   3. test_four_required_jobs             — lint-format, tests, llm-review, validate-ci present
#   4. test_tests_job_needs_lint_format    — jobs.tests.needs contains "lint-format"
#   5. test_llm_review_needs_tests         — jobs.llm-review.needs contains "tests"
#   6. test_validate_ci_needs_tests        — jobs.validate-ci.needs contains "tests"
#   7. test_lint_format_has_no_needs       — jobs.lint-format has no needs field
#   8. test_no_dso_plugin_refs             — no read-config.sh or CLAUDE_PLUGIN_ROOT refs
#   9. test_lint_format_uses_github_variables — lint-format run: references ${{ vars. pattern
#  10. test_validate_ci_runs_validate_sh   — validate-ci step run: contains validate.sh
#
# Usage: bash tests/scripts/test-ci-dso-staged-template.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$PLUGIN_ROOT/plugins/dso/templates/ci-dso-staged.yml"

# shellcheck source=../lib/assert.sh
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ci-dso-staged-template.sh ==="

# ── test_template_file_exists ─────────────────────────────────────────────────
# The template must exist — this is the RED gate. When the file is missing,
# this test fails and the suite exits non-zero, establishing RED state.
_snapshot_fail
if [[ -f "$TEMPLATE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_template_file_exists: file present" "exists" "$actual_exists"
assert_pass_if_clean "test_template_file_exists"

# ── test_yaml_is_parseable ────────────────────────────────────────────────────
# python3 yaml.safe_load must succeed (exit 0) on the template.
_snapshot_fail
yaml_parse_exit=0
yaml_parse_output=""
yaml_parse_output=$(python3 -c "
import yaml, sys
try:
    with open('$TEMPLATE') as f:
        yaml.safe_load(f)
    print('OK')
except Exception as e:
    print('PARSE_ERROR: ' + str(e))
    sys.exit(1)
" 2>&1) || yaml_parse_exit=$?
assert_eq "test_yaml_is_parseable: exit 0" "0" "$yaml_parse_exit"
assert_eq "test_yaml_is_parseable: output is OK" "OK" "$yaml_parse_output"
assert_pass_if_clean "test_yaml_is_parseable"

# ── test_four_required_jobs ───────────────────────────────────────────────────
# jobs.lint-format, jobs.tests, jobs.llm-review, jobs.validate-ci must all be present.
_snapshot_fail
jobs_exit=0
jobs_output=""
jobs_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
required = ['lint-format', 'tests', 'llm-review', 'validate-ci']
missing = [j for j in required if j not in jobs]
if missing:
    print('MISSING_JOBS: ' + ', '.join(missing))
    sys.exit(1)
print('OK')
" 2>&1) || jobs_exit=$?
assert_eq "test_four_required_jobs: exit 0" "0" "$jobs_exit"
assert_eq "test_four_required_jobs: all required jobs present" "OK" "$jobs_output"
assert_pass_if_clean "test_four_required_jobs"

# ── test_tests_job_needs_lint_format ─────────────────────────────────────────
# jobs.tests.needs must contain "lint-format".
_snapshot_fail
tests_needs_exit=0
tests_needs_output=""
tests_needs_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
tests_job = jobs.get('tests', {})
needs = tests_job.get('needs', [])
if isinstance(needs, str):
    needs = [needs]
if 'lint-format' not in needs:
    print('MISSING_NEED: lint-format not in tests.needs: ' + str(needs))
    sys.exit(1)
print('OK')
" 2>&1) || tests_needs_exit=$?
assert_eq "test_tests_job_needs_lint_format: exit 0" "0" "$tests_needs_exit"
assert_eq "test_tests_job_needs_lint_format: lint-format in tests.needs" "OK" "$tests_needs_output"
assert_pass_if_clean "test_tests_job_needs_lint_format"

# ── test_llm_review_needs_tests ───────────────────────────────────────────────
# jobs.llm-review.needs must contain "tests".
_snapshot_fail
llm_needs_exit=0
llm_needs_output=""
llm_needs_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
needs = llm_job.get('needs', [])
if isinstance(needs, str):
    needs = [needs]
if 'tests' not in needs:
    print('MISSING_NEED: tests not in llm-review.needs: ' + str(needs))
    sys.exit(1)
print('OK')
" 2>&1) || llm_needs_exit=$?
assert_eq "test_llm_review_needs_tests: exit 0" "0" "$llm_needs_exit"
assert_eq "test_llm_review_needs_tests: tests in llm-review.needs" "OK" "$llm_needs_output"
assert_pass_if_clean "test_llm_review_needs_tests"

# ── test_validate_ci_needs_tests ──────────────────────────────────────────────
# jobs.validate-ci.needs must contain "tests".
_snapshot_fail
valci_needs_exit=0
valci_needs_output=""
valci_needs_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
valci_job = jobs.get('validate-ci', {})
needs = valci_job.get('needs', [])
if isinstance(needs, str):
    needs = [needs]
if 'tests' not in needs:
    print('MISSING_NEED: tests not in validate-ci.needs: ' + str(needs))
    sys.exit(1)
print('OK')
" 2>&1) || valci_needs_exit=$?
assert_eq "test_validate_ci_needs_tests: exit 0" "0" "$valci_needs_exit"
assert_eq "test_validate_ci_needs_tests: tests in validate-ci.needs" "OK" "$valci_needs_output"
assert_pass_if_clean "test_validate_ci_needs_tests"

# ── test_lint_format_has_no_needs ─────────────────────────────────────────────
# jobs.lint-format must NOT have a needs field (it is the root/first job).
_snapshot_fail
lf_no_needs_exit=0
lf_no_needs_output=""
lf_no_needs_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
lf_job = jobs.get('lint-format', {})
if 'needs' in lf_job:
    print('HAS_NEEDS: lint-format.needs should not exist, got: ' + str(lf_job['needs']))
    sys.exit(1)
print('OK')
" 2>&1) || lf_no_needs_exit=$?
assert_eq "test_lint_format_has_no_needs: exit 0" "0" "$lf_no_needs_exit"
assert_eq "test_lint_format_has_no_needs: no needs field on lint-format" "OK" "$lf_no_needs_output"
assert_pass_if_clean "test_lint_format_has_no_needs"

# ── test_no_dso_plugin_refs ───────────────────────────────────────────────────
# The template must contain no references to read-config.sh or CLAUDE_PLUGIN_ROOT.
_snapshot_fail
no_dso_refs_output=""
no_plugin_root="ok"
no_read_config="ok"
if grep -q 'CLAUDE_PLUGIN_ROOT' "$TEMPLATE" 2>/dev/null; then
    no_plugin_root="found"
fi
if grep -q 'read-config\.sh' "$TEMPLATE" 2>/dev/null; then
    no_read_config="found"
fi
assert_eq "test_no_dso_plugin_refs: no CLAUDE_PLUGIN_ROOT in template" "ok" "$no_plugin_root"
assert_eq "test_no_dso_plugin_refs: no read-config.sh in template" "ok" "$no_read_config"
assert_pass_if_clean "test_no_dso_plugin_refs"

# ── test_lint_format_uses_github_variables ────────────────────────────────────
# The lint-format job's run: command must reference ${{ vars. (GitHub Actions variable syntax).
_snapshot_fail
lf_vars_exit=0
lf_vars_output=""
lf_vars_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
lf_job = jobs.get('lint-format', {})
steps = lf_job.get('steps', [])
run_commands = [s.get('run', '') for s in steps if s.get('run')]
combined = ' '.join(run_commands)
if '\${{ vars.' not in combined:
    print('MISSING_VARS: no \${{ vars. pattern found in lint-format steps run commands')
    sys.exit(1)
print('OK')
" 2>&1) || lf_vars_exit=$?
assert_eq "test_lint_format_uses_github_variables: exit 0" "0" "$lf_vars_exit"
assert_eq "test_lint_format_uses_github_variables: \${{ vars. pattern present" "OK" "$lf_vars_output"
assert_pass_if_clean "test_lint_format_uses_github_variables"

# ── test_validate_ci_runs_validate_sh ────────────────────────────────────────
# The validate-ci job's steps run: commands must contain validate.sh.
_snapshot_fail
valci_sh_exit=0
valci_sh_output=""
valci_sh_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
valci_job = jobs.get('validate-ci', {})
steps = valci_job.get('steps', [])
run_commands = [s.get('run', '') for s in steps if s.get('run')]
combined = ' '.join(run_commands)
if 'validate.sh' not in combined:
    print('MISSING: validate.sh not found in validate-ci steps run commands')
    sys.exit(1)
print('OK')
" 2>&1) || valci_sh_exit=$?
assert_eq "test_validate_ci_runs_validate_sh: exit 0" "0" "$valci_sh_exit"
assert_eq "test_validate_ci_runs_validate_sh: validate.sh in validate-ci steps" "OK" "$valci_sh_output"
assert_pass_if_clean "test_validate_ci_runs_validate_sh"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
