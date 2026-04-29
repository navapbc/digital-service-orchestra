#!/usr/bin/env bash
# tests/scripts/test-ci-llm-review-job.sh
# RED-phase structural tests for the llm-review job in
# plugins/dso/templates/ci-dso-staged.yml.
#
# Tests covered:
#   1. test_llm_review_uses_claude_code_action     — step uses anthropics/claude-code-action@<40-char SHA> (RED)
#   2. test_llm_review_timeout_minutes_set         — timeout-minutes field present (PASS — already in placeholder)
#   3. test_llm_review_validates_required_variables — run: checks 4 model vars + exits on missing (RED)
#   4. test_llm_review_tier_selection_maps_model   — run: reads DSO_LLM_TIER, writes GITHUB_ENV (RED)
#   5. test_llm_review_action_uses_api_key_from_secrets — step references secrets.ANTHROPIC_API_KEY (RED)
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

# ── test_llm_review_uses_claude_code_action ───────────────────────────────────
# The llm-review job must have at least one step whose uses: field matches
# anthropics/claude-code-action pinned to a 40-character SHA (not a mutable tag).
# RED until the real implementation is added.
_snapshot_fail
claude_action_exit=0
claude_action_output=""
claude_action_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, re, os

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])
uses_values = [s.get('uses', '') for s in steps if s.get('uses')]
sha_pattern = re.compile(r'anthropics/claude-code-action@[a-f0-9]{40}$')
matched = [u for u in uses_values if sha_pattern.match(u)]
if not matched:
    print('MISSING_SHA_PIN: no step uses anthropics/claude-code-action@<40-char-sha>; found uses: ' + str(uses_values))
    sys.exit(1)
print('OK')
PYEOF
) || claude_action_exit=$?
assert_eq "test_llm_review_uses_claude_code_action: exit 0" "0" "$claude_action_exit"
assert_eq "test_llm_review_uses_claude_code_action: SHA-pinned action present" "OK" "$claude_action_output"
assert_pass_if_clean "test_llm_review_uses_claude_code_action"

# ── test_llm_review_timeout_minutes_set ──────────────────────────────────────
# The llm-review job must have a timeout-minutes field set (any integer value).
# Already present in the placeholder — this is a regression guard (PASS).
_snapshot_fail
timeout_exit=0
timeout_output=""
timeout_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, os

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
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
PYEOF
) || timeout_exit=$?
assert_eq "test_llm_review_timeout_minutes_set: exit 0" "0" "$timeout_exit"
assert_eq "test_llm_review_timeout_minutes_set: timeout-minutes is an integer" "OK" "$timeout_output"
assert_pass_if_clean "test_llm_review_timeout_minutes_set"

# ── test_llm_review_validates_required_variables ──────────────────────────────
# The llm-review job must have a dedicated validation step whose run: body, when
# executed as a shell script, exits non-zero when a required variable is unset
# and exits zero when all four vars are set.
# RED until the variable-validation step is added to the template.
_snapshot_fail
validate_vars_exit=0
validate_vars_output=""
validate_vars_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, subprocess, os, tempfile

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])

# Find the validation step: a run: step that references DSO_LLM_LIGHT_MODEL
validation_step = None
for step in steps:
    run_body = step.get('run', '')
    if run_body and 'DSO_LLM_LIGHT_MODEL' in run_body:
        validation_step = step
        break

if validation_step is None:
    print('MISSING_STEP: validation step not found in llm-review job')
    sys.exit(1)

run_body = validation_step['run']

# Behavioral check 1: all 4 vars set → exit 0
env_all = {
    **os.environ,
    'DSO_LLM_LIGHT_MODEL': 'a',
    'DSO_LLM_STANDARD_MODEL': 'b',
    'DSO_LLM_FRONTIER_MODEL': 'c',
    'DSO_LLM_TIER': 'light',
}
result_all = subprocess.run(['bash', '-c', run_body], env=env_all, capture_output=True)
if result_all.returncode != 0:
    stderr = result_all.stderr.decode().strip()
    print(f'FAIL_ALL_SET: expected exit 0 with all vars set, got exit {result_all.returncode}: {stderr}')
    sys.exit(1)

# Behavioral check 2: one var missing → exit non-zero
env_missing = {
    **os.environ,
    'DSO_LLM_LIGHT_MODEL': '',
    'DSO_LLM_STANDARD_MODEL': 'b',
    'DSO_LLM_FRONTIER_MODEL': 'c',
    'DSO_LLM_TIER': 'light',
}
result_missing = subprocess.run(['bash', '-c', run_body], env=env_missing, capture_output=True)
if result_missing.returncode == 0:
    print('FAIL_VAR_MISSING: expected exit non-zero when DSO_LLM_LIGHT_MODEL is empty, got exit 0')
    sys.exit(1)

print('OK')
PYEOF
) || validate_vars_exit=$?
assert_eq "test_llm_review_validates_required_variables: exit 0" "0" "$validate_vars_exit"
assert_eq "test_llm_review_validates_required_variables: validation step executes correctly" "OK" "$validate_vars_output"
assert_pass_if_clean "test_llm_review_validates_required_variables"

# ── test_llm_review_tier_selection_maps_model ─────────────────────────────────
# The llm-review job must have a step that, when executed with DSO_LLM_TIER=light
# and a temp GITHUB_ENV file, writes ANTHROPIC_MODEL=<light-model-value> to
# GITHUB_ENV.
# RED until the tier-selection step is added to the template.
_snapshot_fail
tier_sel_exit=0
tier_sel_output=""
tier_sel_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, subprocess, os, tempfile

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])

# Find the tier-selection step: a run: step that references GITHUB_ENV
tier_step = None
for step in steps:
    run_body = step.get('run', '')
    if run_body and 'GITHUB_ENV' in run_body and 'DSO_LLM_TIER' in run_body:
        tier_step = step
        break

if tier_step is None:
    print('MISSING_STEP: tier selection step not found in llm-review job')
    sys.exit(1)

run_body = tier_step['run']

# Behavioral check: execute with light tier, assert ANTHROPIC_MODEL written to GITHUB_ENV
with tempfile.NamedTemporaryFile(mode='w', prefix='github_env_', suffix='.tmp', delete=False) as tmp:
    github_env_path = tmp.name

try:
    env = {
        **os.environ,
        'GITHUB_ENV': github_env_path,
        'DSO_LLM_TIER': 'light',
        'DSO_LLM_LIGHT_MODEL': 'claude-haiku',
        'DSO_LLM_STANDARD_MODEL': 'claude-sonnet',
        'DSO_LLM_FRONTIER_MODEL': 'claude-opus',
    }
    result = subprocess.run(['bash', '-c', run_body], env=env, capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.decode().strip()
        print(f'FAIL_EXEC: tier-selection step exited {result.returncode}: {stderr}')
        sys.exit(1)

    with open(github_env_path) as f:
        github_env_contents = f.read()

    if 'ANTHROPIC_MODEL=claude-haiku' not in github_env_contents:
        print(f'FAIL_OUTPUT: expected ANTHROPIC_MODEL=claude-haiku in GITHUB_ENV, got: {github_env_contents!r}')
        sys.exit(1)
finally:
    os.unlink(github_env_path)

print('OK')
PYEOF
) || tier_sel_exit=$?
assert_eq "test_llm_review_tier_selection_maps_model: exit 0" "0" "$tier_sel_exit"
assert_eq "test_llm_review_tier_selection_maps_model: light tier maps to correct model in GITHUB_ENV" "OK" "$tier_sel_output"
assert_pass_if_clean "test_llm_review_tier_selection_maps_model"

# ── test_llm_review_tier_selection_standard ───────────────────────────────────
# The tier-selection step must map DSO_LLM_TIER=standard to DSO_LLM_STANDARD_MODEL.
_snapshot_fail
tier_std_exit=0
tier_std_output=""
tier_std_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, subprocess, os, tempfile

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])

tier_step = None
for step in steps:
    run_body = step.get('run', '')
    if run_body and 'GITHUB_ENV' in run_body and 'DSO_LLM_TIER' in run_body:
        tier_step = step
        break

if tier_step is None:
    print('MISSING_STEP: tier selection step not found in llm-review job')
    sys.exit(1)

run_body = tier_step['run']

with tempfile.NamedTemporaryFile(mode='w', prefix='github_env_', suffix='.tmp', delete=False) as tmp:
    github_env_path = tmp.name

try:
    env = {
        **os.environ,
        'GITHUB_ENV': github_env_path,
        'DSO_LLM_TIER': 'standard',
        'DSO_LLM_LIGHT_MODEL': 'claude-haiku',
        'DSO_LLM_STANDARD_MODEL': 'claude-sonnet',
        'DSO_LLM_FRONTIER_MODEL': 'claude-opus',
    }
    result = subprocess.run(['bash', '-c', run_body], env=env, capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.decode().strip()
        print(f'FAIL_EXEC: tier-selection step exited {result.returncode}: {stderr}')
        sys.exit(1)

    with open(github_env_path) as f:
        github_env_contents = f.read()

    if 'ANTHROPIC_MODEL=claude-sonnet' not in github_env_contents:
        print(f'FAIL_OUTPUT: expected ANTHROPIC_MODEL=claude-sonnet in GITHUB_ENV, got: {github_env_contents!r}')
        sys.exit(1)
finally:
    os.unlink(github_env_path)

print('OK')
PYEOF
) || tier_std_exit=$?
assert_eq "test_llm_review_tier_selection_standard: exit 0" "0" "$tier_std_exit"
assert_eq "test_llm_review_tier_selection_standard: standard tier maps to correct model in GITHUB_ENV" "OK" "$tier_std_output"
assert_pass_if_clean "test_llm_review_tier_selection_standard"

# ── test_llm_review_tier_selection_frontier ───────────────────────────────────
# The tier-selection step must map DSO_LLM_TIER=frontier to DSO_LLM_FRONTIER_MODEL.
_snapshot_fail
tier_frontier_exit=0
tier_frontier_output=""
tier_frontier_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, subprocess, os, tempfile

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])

tier_step = None
for step in steps:
    run_body = step.get('run', '')
    if run_body and 'GITHUB_ENV' in run_body and 'DSO_LLM_TIER' in run_body:
        tier_step = step
        break

if tier_step is None:
    print('MISSING_STEP: tier selection step not found in llm-review job')
    sys.exit(1)

run_body = tier_step['run']

with tempfile.NamedTemporaryFile(mode='w', prefix='github_env_', suffix='.tmp', delete=False) as tmp:
    github_env_path = tmp.name

try:
    env = {
        **os.environ,
        'GITHUB_ENV': github_env_path,
        'DSO_LLM_TIER': 'frontier',
        'DSO_LLM_LIGHT_MODEL': 'claude-haiku',
        'DSO_LLM_STANDARD_MODEL': 'claude-sonnet',
        'DSO_LLM_FRONTIER_MODEL': 'claude-opus',
    }
    result = subprocess.run(['bash', '-c', run_body], env=env, capture_output=True)
    if result.returncode != 0:
        stderr = result.stderr.decode().strip()
        print(f'FAIL_EXEC: tier-selection step exited {result.returncode}: {stderr}')
        sys.exit(1)

    with open(github_env_path) as f:
        github_env_contents = f.read()

    if 'ANTHROPIC_MODEL=claude-opus' not in github_env_contents:
        print(f'FAIL_OUTPUT: expected ANTHROPIC_MODEL=claude-opus in GITHUB_ENV, got: {github_env_contents!r}')
        sys.exit(1)
finally:
    os.unlink(github_env_path)

print('OK')
PYEOF
) || tier_frontier_exit=$?
assert_eq "test_llm_review_tier_selection_frontier: exit 0" "0" "$tier_frontier_exit"
assert_eq "test_llm_review_tier_selection_frontier: frontier tier maps to correct model in GITHUB_ENV" "OK" "$tier_frontier_output"
assert_pass_if_clean "test_llm_review_tier_selection_frontier"

# ── test_llm_review_tier_selection_invalid_tier ───────────────────────────────
# The tier-selection step must exit non-zero when DSO_LLM_TIER is unrecognized.
_snapshot_fail
tier_invalid_exit=0
tier_invalid_output=""
tier_invalid_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, subprocess, os, tempfile

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])

tier_step = None
for step in steps:
    run_body = step.get('run', '')
    if run_body and 'GITHUB_ENV' in run_body and 'DSO_LLM_TIER' in run_body:
        tier_step = step
        break

if tier_step is None:
    print('MISSING_STEP: tier selection step not found in llm-review job')
    sys.exit(1)

run_body = tier_step['run']

with tempfile.NamedTemporaryFile(mode='w', prefix='github_env_', suffix='.tmp', delete=False) as tmp:
    github_env_path = tmp.name

try:
    env = {
        **os.environ,
        'GITHUB_ENV': github_env_path,
        'DSO_LLM_TIER': 'invalid-tier-xyz',
        'DSO_LLM_LIGHT_MODEL': 'claude-haiku',
        'DSO_LLM_STANDARD_MODEL': 'claude-sonnet',
        'DSO_LLM_FRONTIER_MODEL': 'claude-opus',
    }
    result = subprocess.run(['bash', '-c', run_body], env=env, capture_output=True)
    if result.returncode == 0:
        print('FAIL_INVALID_TIER: expected non-zero exit for unrecognized DSO_LLM_TIER, got exit 0')
        sys.exit(1)
finally:
    os.unlink(github_env_path)

print('OK')
PYEOF
) || tier_invalid_exit=$?
assert_eq "test_llm_review_tier_selection_invalid_tier: exit 0" "0" "$tier_invalid_exit"
assert_eq "test_llm_review_tier_selection_invalid_tier: invalid tier exits non-zero" "OK" "$tier_invalid_output"
assert_pass_if_clean "test_llm_review_tier_selection_invalid_tier"

# ── test_llm_review_action_uses_api_key_from_secrets ─────────────────────────
# The claude-code-action step must reference secrets.ANTHROPIC_API_KEY in its
# env: or with: block.
# RED until the real step is added with the API key wired in.
_snapshot_fail
api_key_exit=0
api_key_output=""
api_key_output=$(python3 - <<'PYEOF' 2>&1
import yaml, sys, os

template = os.environ.get('TEMPLATE', '')
with open(template) as f:
    raw = f.read()
    doc = yaml.safe_load(raw)
jobs = doc.get('jobs', {})
llm_job = jobs.get('llm-review', {})
steps = llm_job.get('steps', [])
# Check each step that uses the claude-code-action for the API key reference.
# We check both parsed YAML (env/with blocks) and the raw text for the
# ${{ secrets.ANTHROPIC_API_KEY }} expression.
found = False
for step in steps:
    uses = step.get('uses', '')
    if 'claude-code-action' not in uses:
        continue
    env_block = step.get('env', {})
    with_block = step.get('with', {})
    env_values = ' '.join(str(v) for v in env_block.values())
    with_values = ' '.join(str(v) for v in with_block.values())
    combined = env_values + ' ' + with_values
    if 'secrets.ANTHROPIC_API_KEY' in combined:
        found = True
        break
# Fallback: check raw YAML text near the action reference
if not found:
    idx = raw.find('claude-code-action')
    if idx != -1:
        surrounding = raw[max(0, idx-200):idx+500]
        if 'secrets.ANTHROPIC_API_KEY' in surrounding:
            found = True
if not found:
    print('MISSING_API_KEY: no claude-code-action step references secrets.ANTHROPIC_API_KEY')
    sys.exit(1)
print('OK')
PYEOF
) || api_key_exit=$?
assert_eq "test_llm_review_action_uses_api_key_from_secrets: exit 0" "0" "$api_key_exit"
assert_eq "test_llm_review_action_uses_api_key_from_secrets: secrets.ANTHROPIC_API_KEY referenced" "OK" "$api_key_output"
assert_pass_if_clean "test_llm_review_action_uses_api_key_from_secrets"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
