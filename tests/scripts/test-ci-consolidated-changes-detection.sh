#!/usr/bin/env bash
# tests/scripts/test-ci-consolidated-changes-detection.sh
# RED-phase structural tests asserting the post-fix shape of .github/workflows/ci.yml
# and the absence of the soon-to-be-deleted ci-skip.yml + parity script.
#
# Bug: cb67-2265-0a04-425b — ci-skip.yml paths filter overlaps with ci.yml paths-ignore
# on mixed PRs, producing duplicate check-context emissions and a branch-protection
# bypass via the no-op llm-review stub.
#
# Approved fix (Fix 1): consolidate to a single ci.yml with a top-level `changes` job
# that gates all required-check jobs' steps on code_changed output.
#
# Tests covered:
#   1. test_ci_skip_yml_absent              — .github/workflows/ci-skip.yml does NOT exist (RED)
#   2. test_validate_parity_script_absent   — validate-ci-skip-parity.sh does NOT exist (RED)
#   3. test_validate_parity_test_absent     — test-validate-ci-skip-parity.sh does NOT exist (RED)
#   4. test_ci_yml_has_changes_job          — ci.yml jobs map contains a changes job with outputs.code_changed (RED)
#   5. test_required_jobs_depend_on_changes — each required-check job has changes in its needs: list (RED)
#   6. test_required_jobs_gate_steps_on_code_changed — each required-check job has at least one step
#                                             gated on needs.changes.outputs.code_changed (RED)
#
# Usage: bash tests/scripts/test-ci-consolidated-changes-detection.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
export REPO_ROOT CI_YML

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-consolidated-changes-detection.sh ==="

# ── test_ci_skip_yml_absent ───────────────────────────────────────────────────
# After Fix 1 is applied, ci-skip.yml must be deleted entirely.
# GREEN: ci-skip.yml has been deleted as part of consolidation.
_snapshot_fail
ci_skip_absent_exit=0
ci_skip_absent_result=""
if [[ -f "$REPO_ROOT/.github/workflows/ci-skip.yml" ]]; then
    ci_skip_absent_result="FAIL: .github/workflows/ci-skip.yml still exists — must be deleted by Fix 1"
    ci_skip_absent_exit=1
else
    ci_skip_absent_result="OK"
fi
assert_eq "test_ci_skip_yml_absent: ci-skip.yml does not exist" "OK" "$ci_skip_absent_result"
assert_pass_if_clean "test_ci_skip_yml_absent"

# ── test_validate_parity_script_absent ───────────────────────────────────────
# After Fix 1, validate-ci-skip-parity.sh must be deleted.
# GREEN: the parity script has been deleted.
_snapshot_fail
parity_script_absent_result=""
if [[ -f "$REPO_ROOT/plugins/dso/scripts/onboarding/validate-ci-skip-parity.sh" ]]; then
    parity_script_absent_result="FAIL: plugins/dso/scripts/onboarding/validate-ci-skip-parity.sh still exists — must be deleted by Fix 1"
else
    parity_script_absent_result="OK"
fi
assert_eq "test_validate_parity_script_absent: validate-ci-skip-parity.sh does not exist" "OK" "$parity_script_absent_result"
assert_pass_if_clean "test_validate_parity_script_absent"

# ── test_validate_parity_test_absent ─────────────────────────────────────────
# After Fix 1, test-validate-ci-skip-parity.sh must be deleted.
# GREEN: the parity test has been deleted.
_snapshot_fail
parity_test_absent_result=""
if [[ -f "$REPO_ROOT/tests/scripts/test-validate-ci-skip-parity.sh" ]]; then
    parity_test_absent_result="FAIL: tests/scripts/test-validate-ci-skip-parity.sh still exists — must be deleted by Fix 1"
else
    parity_test_absent_result="OK"
fi
assert_eq "test_validate_parity_test_absent: test-validate-ci-skip-parity.sh does not exist" "OK" "$parity_test_absent_result"
assert_pass_if_clean "test_validate_parity_test_absent"

# ── test_ci_yml_has_changes_job ───────────────────────────────────────────────
# ci.yml's jobs map must contain a `changes` job that declares
# outputs.code_changed so downstream jobs can gate on it.
# GREEN: ci.yml now contains a changes job that emits code_changed.
_snapshot_fail
changes_job_exit=0
changes_job_output=""
changes_job_output=$(python3 -c "
import yaml, sys

with open('$CI_YML') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
if 'changes' not in jobs:
    job_keys = list(jobs.keys())
    print('MISSING_JOB: ci.yml has no changes job; found jobs: ' + str(job_keys))
    sys.exit(1)
changes_job = jobs['changes']
outputs = changes_job.get('outputs', {})
if 'code_changed' not in outputs:
    print('MISSING_OUTPUT: changes job exists but has no outputs.code_changed; outputs: ' + str(list(outputs.keys())))
    sys.exit(1)
print('OK')
" 2>&1) || changes_job_exit=$?
assert_eq "test_ci_yml_has_changes_job: exit 0" "0" "$changes_job_exit"
assert_eq "test_ci_yml_has_changes_job: changes job with outputs.code_changed exists" "OK" "$changes_job_output"
assert_pass_if_clean "test_ci_yml_has_changes_job"

# ── test_required_jobs_depend_on_changes ─────────────────────────────────────
# Each required-check job must list `changes` in its needs: list so it waits
# for the changes detection output before running.
# Canonical job-key list: actionlint shellcheck lint-python test-hooks test-scripts llm-review
# GREEN: each required-check job now declares changes in its needs list.
_snapshot_fail
needs_exit=0
needs_output=""
needs_output=$(python3 -c "
import yaml, sys

with open('$CI_YML') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
required_jobs = ['actionlint', 'shellcheck', 'lint-python', 'test-hooks', 'test-scripts', 'llm-review']
errors = []
for job_key in required_jobs:
    if job_key not in jobs:
        errors.append('MISSING_JOB: job ' + repr(job_key) + ' not found in ci.yml')
        continue
    job = jobs[job_key]
    needs_raw = job.get('needs', [])
    # needs: can be a string (single dep) or list
    if isinstance(needs_raw, str):
        needs_list = [needs_raw]
    else:
        needs_list = list(needs_raw)
    if 'changes' not in needs_list:
        errors.append('MISSING_NEEDS: ' + job_key + ' job has no changes in needs; needs: ' + str(needs_list))
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print('OK')
" 2>&1) || needs_exit=$?
assert_eq "test_required_jobs_depend_on_changes: exit 0" "0" "$needs_exit"
assert_eq "test_required_jobs_depend_on_changes: all required-check jobs have changes in needs" "OK" "$needs_output"
assert_pass_if_clean "test_required_jobs_depend_on_changes"

# ── test_required_jobs_gate_steps_on_code_changed ────────────────────────────
# For each required-check job, at least one step must have an if: condition
# containing needs.changes.outputs.code_changed so the substantive work is
# skipped on doc-only changes (NOT the job itself — skipped jobs don't satisfy
# required checks; a running no-op job does).
# GREEN: each required-check job gates substantive steps on the changes output.
_snapshot_fail
gate_exit=0
gate_output=""
gate_output=$(python3 -c "
import yaml, sys

with open('$CI_YML') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
required_jobs = ['actionlint', 'shellcheck', 'lint-python', 'test-hooks', 'test-scripts', 'llm-review']
errors = []
for job_key in required_jobs:
    if job_key not in jobs:
        # already reported in previous test; skip here
        continue
    job = jobs[job_key]
    steps = job.get('steps', [])
    # Strict equality match — substring containment would accept any
    # if-condition containing the env-var name, which is too permissive.
    # REVIEW-DEFENSE (PR #62 finding 6): the YAML is parsed via PyYAML before
    # comparison, which normalizes whitespace and quoting (single vs double).
    # The 'brittle to formatting' concern doesn't materialize because the
    # comparison is against the parsed Python string, not the raw YAML source.
    # Pass-2 of the prior cb67-2265 review explicitly required this strict-equality
    # check to replace a too-permissive substring match — this is a deliberate
    # contract assertion, not a stylistic preference.
    expected_if = 'needs.changes.outputs.code_changed == ' + chr(39) + 'true' + chr(39)
    gated_steps = [
        s for s in steps
        if str(s.get('if', '')).strip() == expected_if
    ]
    if not gated_steps:
        step_ifs = [str(s.get('if', '(no if)'))[:60] for s in steps]
        errors.append(
            'MISSING_GATE: ' + job_key + ' job has no step gated on needs.changes.outputs.code_changed; '
            'step if conditions: ' + str(step_ifs)
        )
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print('OK')
" 2>&1) || gate_exit=$?
assert_eq "test_required_jobs_gate_steps_on_code_changed: exit 0" "0" "$gate_exit"
assert_eq "test_required_jobs_gate_steps_on_code_changed: all required-check jobs gate steps on code_changed" "OK" "$gate_output"
assert_pass_if_clean "test_required_jobs_gate_steps_on_code_changed"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
