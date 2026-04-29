#!/usr/bin/env bash
# tests/scripts/test-ci-llm-review-job.sh
# RED-phase structural tests for the llm-review job in
# plugins/dso/templates/ci-dso-staged.yml.
#
# Tests covered:
#   1. test_llm_review_uses_classifier_runner      — run: step invokes ci-llm-review-runner.sh (RED)
#   2. test_llm_review_timeout_minutes_set         — timeout-minutes field present (PASS — already in placeholder)
#   3. test_llm_review_exposes_anthropic_api_key   — run: step env contains ANTHROPIC_API_KEY (RED)
#   4. test_llm_review_uses_gh_pr_diff             — run: step invokes `gh pr diff |` (RED)
#   5. test_llm_review_github_token_in_env         — run: step env contains GITHUB_TOKEN (RED)
#
# Usage: bash tests/scripts/test-ci-llm-review-job.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEMPLATE="$REPO_ROOT/plugins/dso/templates/ci-dso-staged.yml"
export TEMPLATE

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-llm-review-job.sh ==="

# ── test_llm_review_uses_classifier_runner ────────────────────────────────────
# The llm-review job must have at least one step whose run: field invokes
# ci-llm-review-runner.sh (the classifier-driven runner script).
# RED until the claude-code-action step is replaced with the runner script step.
_snapshot_fail
classifier_runner_exit=0
classifier_runner_output=""
classifier_runner_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])
run_steps = [s for s in steps if s.get('run')]
matched = [s for s in run_steps if 'ci-llm-review-runner.sh' in s.get('run', '')]
if not matched:
    run_values = [s.get('run', '')[:80] for s in run_steps]
    print('MISSING_RUNNER: no run: step invokes ci-llm-review-runner.sh; found run steps: ' + str(run_values))
    sys.exit(1)
print('OK')
" 2>&1) || classifier_runner_exit=$?
assert_eq "test_llm_review_uses_classifier_runner: exit 0" "0" "$classifier_runner_exit"
assert_eq "test_llm_review_uses_classifier_runner: run step invokes ci-llm-review-runner.sh" "OK" "$classifier_runner_output"
assert_pass_if_clean "test_llm_review_uses_classifier_runner"

# ── test_llm_review_timeout_minutes_set ──────────────────────────────────────
# The llm-review job must have a timeout-minutes field set (any integer value).
# Already present in the placeholder — this is a regression guard (PASS).
_snapshot_fail
timeout_exit=0
timeout_output=""
timeout_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
timeout = llm_job.get('timeout-minutes')
if timeout is None:
    print('MISSING_TIMEOUT: llm-review job has no timeout-minutes field')
    sys.exit(1)
if not isinstance(timeout, int):
    print('INVALID_TIMEOUT: timeout-minutes must be an integer, got: ' + str(type(timeout).__name__))
    sys.exit(1)
print('OK')
" 2>&1) || timeout_exit=$?
assert_eq "test_llm_review_timeout_minutes_set: exit 0" "0" "$timeout_exit"
assert_eq "test_llm_review_timeout_minutes_set: timeout-minutes is an integer" "OK" "$timeout_output"
assert_pass_if_clean "test_llm_review_timeout_minutes_set"

# ── test_llm_review_exposes_anthropic_api_key ─────────────────────────────────
# The llm-review job must have a run: step whose env: block contains
# ANTHROPIC_API_KEY (so the runner script can authenticate to the Anthropic API).
# RED until the classifier-driven runner step is added with ANTHROPIC_API_KEY in env.
_snapshot_fail
api_key_env_exit=0
api_key_env_output=""
api_key_env_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])
run_steps = [s for s in steps if s.get('run')]
matched = [s for s in run_steps if 'ANTHROPIC_API_KEY' in s.get('env', {})]
if not matched:
    env_keys = [list(s.get('env', {}).keys()) for s in run_steps]
    print('MISSING_API_KEY: no run: step env block contains ANTHROPIC_API_KEY; run step env keys: ' + str(env_keys))
    sys.exit(1)
print('OK')
" 2>&1) || api_key_env_exit=$?
assert_eq "test_llm_review_exposes_anthropic_api_key: exit 0" "0" "$api_key_env_exit"
assert_eq "test_llm_review_exposes_anthropic_api_key: run step env contains ANTHROPIC_API_KEY" "OK" "$api_key_env_output"
assert_pass_if_clean "test_llm_review_exposes_anthropic_api_key"

# ── test_llm_review_uses_gh_pr_diff ───────────────────────────────────────────
# The llm-review job must have a run: step whose body contains `gh pr diff |`
# so the PR diff is piped into the classifier-driven runner.
# RED until the runner step is added to the template.
_snapshot_fail
gh_pr_diff_exit=0
gh_pr_diff_output=""
gh_pr_diff_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])
run_steps = [s for s in steps if s.get('run')]
matched = [s for s in run_steps if 'gh pr diff |' in s.get('run', '')]
if not matched:
    run_snippets = [s.get('run', '')[:80] for s in run_steps]
    print('MISSING_GH_PR_DIFF: no run: step contains \"gh pr diff |\"; found run steps: ' + str(run_snippets))
    sys.exit(1)
print('OK')
" 2>&1) || gh_pr_diff_exit=$?
assert_eq "test_llm_review_uses_gh_pr_diff: exit 0" "0" "$gh_pr_diff_exit"
assert_eq "test_llm_review_uses_gh_pr_diff: run step contains gh pr diff pipe" "OK" "$gh_pr_diff_output"
assert_pass_if_clean "test_llm_review_uses_gh_pr_diff"

# ── test_llm_review_no_legacy_tier_vars ───────────────────────────────────────
# DSO_LLM_TIER and DSO_LLM_*_MODEL vars must NOT appear in the new classifier-driven job.
# Tier selection is now internal to ci-llm-review-runner.sh.
_snapshot_fail
no_tier_vars_exit=0
no_tier_vars_output=""
no_tier_vars_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, os, json

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)

# Check only the functional YAML structure (not comments) for legacy env vars
llm_job = doc.get('jobs', {}).get('llm-review', {})
job_str = json.dumps(llm_job)
forbidden = ['DSO_LLM_LIGHT_MODEL', 'DSO_LLM_STANDARD_MODEL', 'DSO_LLM_FRONTIER_MODEL', 'DSO_LLM_TIER']
found = [v for v in forbidden if v in job_str]
if found:
    print(f'FAIL: deprecated vars found in llm-review job YAML: {found}')
    sys.exit(1)
print('OK')
PYEOF
) || no_tier_vars_exit=$?
assert_eq "test_llm_review_no_legacy_tier_vars: exit 0" "0" "$no_tier_vars_exit"
assert_eq "test_llm_review_no_legacy_tier_vars: deprecated DSO_LLM_* vars absent from template" "OK" "$no_tier_vars_output"
assert_pass_if_clean "test_llm_review_no_legacy_tier_vars"

# ── test_llm_review_exactly_two_steps ─────────────────────────────────────────
# The new classifier-driven llm-review job has exactly 2 steps: checkout + run LLM review.
_snapshot_fail
step_count_exit=0
step_count_output=""
step_count_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, os

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
steps = doc.get('jobs', {}).get('llm-review', {}).get('steps', [])
if len(steps) != 2:
    print(f'FAIL: expected exactly 2 steps in llm-review job, got {len(steps)}')
    sys.exit(1)
print('OK')
PYEOF
) || step_count_exit=$?
assert_eq "test_llm_review_exactly_two_steps: exit 0" "0" "$step_count_exit"
assert_eq "test_llm_review_exactly_two_steps: llm-review job has exactly 2 steps" "OK" "$step_count_output"
assert_pass_if_clean "test_llm_review_exactly_two_steps"

# ── test_llm_review_no_claude_code_action_ref ─────────────────────────────────
# anthropics/claude-code-action must not appear anywhere in the llm-review job.
_snapshot_fail
no_action_exit=0
no_action_output=""
no_action_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, os

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    content = f.read()
if 'claude-code-action' in content:
    print('FAIL: claude-code-action reference found in template')
    sys.exit(1)
print('OK')
PYEOF
) || no_action_exit=$?
assert_eq "test_llm_review_no_claude_code_action_ref: exit 0" "0" "$no_action_exit"
assert_eq "test_llm_review_no_claude_code_action_ref: claude-code-action absent from template" "OK" "$no_action_output"
assert_pass_if_clean "test_llm_review_no_claude_code_action_ref"

# ── test_llm_review_github_token_in_env ───────────────────────────────────────
# The llm-review job must have a run: step whose env: block contains GITHUB_TOKEN
# so the runner script can call `gh pr diff` and post review comments.
# RED until the classifier-driven runner step is added with GITHUB_TOKEN in env.
_snapshot_fail
github_token_exit=0
github_token_output=""
github_token_output=$(python3 -c "
import yaml, sys
with open('$TEMPLATE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])
run_steps = [s for s in steps if s.get('run')]
matched = [s for s in run_steps if 'GITHUB_TOKEN' in s.get('env', {})]
if not matched:
    env_keys = [list(s.get('env', {}).keys()) for s in run_steps]
    print('MISSING_GITHUB_TOKEN: no run: step env block contains GITHUB_TOKEN; run step env keys: ' + str(env_keys))
    sys.exit(1)
print('OK')
" 2>&1) || github_token_exit=$?
assert_eq "test_llm_review_github_token_in_env: exit 0" "0" "$github_token_exit"
assert_eq "test_llm_review_github_token_in_env: run step env contains GITHUB_TOKEN" "OK" "$github_token_output"
assert_pass_if_clean "test_llm_review_github_token_in_env"

# ── test_llm_review_pr_only_condition ────────────────────────────────────────
# The llm-review job must have an if: condition restricting execution to
# pull_request events so gh pr diff does not fail on push/workflow_dispatch.
_snapshot_fail
pr_only_exit=0
pr_only_output=""
pr_only_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, os

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
llm_job = doc.get('jobs', {}).get('llm-review', {})
job_if = llm_job.get('if', '')
if 'pull_request' not in str(job_if):
    print(f'MISSING_PR_GUARD: llm-review job has no if: condition restricting to pull_request events; got: {repr(job_if)}')
    sys.exit(1)
print('OK')
PYEOF
) || pr_only_exit=$?
assert_eq "test_llm_review_pr_only_condition: exit 0" "0" "$pr_only_exit"
assert_eq "test_llm_review_pr_only_condition: if condition restricts to pull_request" "OK" "$pr_only_output"
assert_pass_if_clean "test_llm_review_pr_only_condition"

# ── test_llm_review_pipefail_shell ────────────────────────────────────────────
# The Run LLM review step must use shell: bash -eo pipefail so gh pr diff
# failures are not silently masked by the pipe.
_snapshot_fail
pipefail_exit=0
pipefail_output=""
pipefail_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, os

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
steps = doc.get('jobs', {}).get('llm-review', {}).get('steps', [])
run_steps = [s for s in steps if s.get('run')]
matched = [s for s in run_steps if 'pipefail' in s.get('shell', '')]
if not matched:
    shells = [s.get('shell', '(absent)') for s in run_steps]
    print(f'MISSING_PIPEFAIL: no run: step sets shell with pipefail; shells: {shells}')
    sys.exit(1)
print('OK')
PYEOF
) || pipefail_exit=$?
assert_eq "test_llm_review_pipefail_shell: exit 0" "0" "$pipefail_exit"
assert_eq "test_llm_review_pipefail_shell: run step uses pipefail shell" "OK" "$pipefail_output"
assert_pass_if_clean "test_llm_review_pipefail_shell"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
