#!/usr/bin/env bash
# tests/scripts/test-scaffold-adapter.sh
# Behavioral tests for scaffold-adapter.sh
#
# Testing mode: RED — scaffold-adapter.sh does not yet exist.
# These tests must FAIL before scaffold-adapter.sh is created.
#
# Uses RECIPE_TEMPLATES_DIR env var to point to mock or real templates.
#
# Usage: bash tests/scripts/test-scaffold-adapter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ADAPTER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/recipe-adapters/scaffold-adapter.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scaffold-adapter.sh ==="

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Helper: create mock flask templates ──────────────────────────────────────
_make_mock_flask_templates() {
    local base_dir="$1"
    local flask_dir="$base_dir/flask"
    mkdir -p "$flask_dir"
    cat > "$flask_dir/route.py.tmpl" <<'TMPL'
from flask import Blueprint, jsonify

{{ROUTE_NAME}}_blueprint = Blueprint('{{ROUTE_NAME}}', __name__, url_prefix='/{{ROUTE_NAME}}')

@{{ROUTE_NAME}}_blueprint.route('/', methods=['GET'])
def list_{{ROUTE_NAME}}():
    """List {{ROUTE_NAME}} resources."""
    return jsonify({'{{ROUTE_NAME}}': []})
TMPL
    cat > "$flask_dir/template.html.tmpl" <<'TMPL'
{% extends "base.html" %}
{% block title %}{{RouteName}}{% endblock %}
{% block content %}
<h1>{{RouteName}}</h1>
{% endblock %}
TMPL
}

# ── Helper: create mock nextjs templates ─────────────────────────────────────
_make_mock_nextjs_templates() {
    local base_dir="$1"
    local nextjs_dir="$base_dir/nextjs"
    mkdir -p "$nextjs_dir"
    cat > "$nextjs_dir/page.tsx.tmpl" <<'TMPL'
export default function {{RouteName}}Page() {
  return (
    <main>
      <h1>{{RouteName}}</h1>
    </main>
  )
}
TMPL
    cat > "$nextjs_dir/api-route.ts.tmpl" <<'TMPL'
import type { NextApiRequest, NextApiResponse } from 'next'

export default function handler(req: NextApiRequest, res: NextApiResponse) {
  if (req.method === 'GET') {
    res.status(200).json({ {{ROUTE_NAME}}: [] })
  } else {
    res.status(405).json({ error: 'Method not allowed' })
  }
}
TMPL
}

# ── test_adapter_invocation_flask ─────────────────────────────────────────────
# Given: scaffold-adapter.sh, RECIPE_PARAM_FRAMEWORK=flask, RECIPE_PARAM_ROUTE=users
# When:  adapter is invoked
# Then:  exits 0, output JSON has files_changed with expected paths
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_adapter_invocation_flask: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_flask_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        inv_exit=0
        inv_output=""
        inv_output=$(RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_FRAMEWORK=flask \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
            RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
            bash "$ADAPTER_SCRIPT" 2>&1) || inv_exit=$?

        assert_eq "test_adapter_invocation_flask: exits 0" "0" "$inv_exit"

        files_nonempty=0
        echo "$inv_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
fc = d.get('files_changed', [])
assert len(fc) > 0, f'files_changed should be non-empty, got {fc}'
" 2>/dev/null && files_nonempty=1 || true
        assert_eq "test_adapter_invocation_flask: files_changed non-empty" "1" "$files_nonempty"
    fi
}
assert_pass_if_clean "test_adapter_invocation_flask"

# ── test_adapter_output_is_valid_json ─────────────────────────────────────────
# Given: scaffold-adapter.sh invoked with valid params
# When:  we parse the output
# Then:  output is valid JSON with required fields: files_changed, transforms_applied, errors, exit_code
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_adapter_output_is_valid_json: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_flask_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        json_output=$(RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_FRAMEWORK=flask \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
            RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
            bash "$ADAPTER_SCRIPT" 2>&1) || true

        valid_schema=0
        echo "$json_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
required = ['files_changed', 'transforms_applied', 'errors', 'exit_code']
missing = [k for k in required if k not in d]
assert not missing, f'Missing fields: {missing}'
assert isinstance(d['files_changed'], list)
assert isinstance(d['errors'], list)
assert isinstance(d['exit_code'], int)
" 2>/dev/null && valid_schema=1 || true
        assert_eq "test_adapter_output_is_valid_json: valid JSON schema" "1" "$valid_schema"
    fi
}
assert_pass_if_clean "test_adapter_output_is_valid_json"

# ── test_missing_framework_returns_error ──────────────────────────────────────
# Given: scaffold-adapter.sh invoked WITHOUT RECIPE_PARAM_FRAMEWORK
# When:  adapter is invoked
# Then:  exits non-zero, JSON has exit_code=1 with error message
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_missing_framework_returns_error: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _output_dir="$_tmpdir/output"
        mkdir -p "$_output_dir"

        err_exit=0
        err_output=""
        err_output=$(RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
            bash "$ADAPTER_SCRIPT" 2>&1) || err_exit=$?

        assert_ne "test_missing_framework_returns_error: exits non-zero" "0" "$err_exit"

        has_error=0
        echo "$err_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('exit_code', 0) == 1, 'exit_code must be 1'
assert len(d.get('errors', [])) > 0, 'errors must be non-empty'
" 2>/dev/null && has_error=1 || true
        assert_eq "test_missing_framework_returns_error: error JSON with exit_code=1" "1" "$has_error"
    fi
}
assert_pass_if_clean "test_missing_framework_returns_error"

# ── test_idempotency ──────────────────────────────────────────────────────────
# Given: scaffold-adapter.sh run twice with same params
# When:  second run executes
# Then:  files_changed=[] on second run (files already exist, skip)
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_idempotency: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_flask_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        # First run
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=flask \
        RECIPE_PARAM_ROUTE=users \
        RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
        RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true

        # Second run
        second_output=$(RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_FRAMEWORK=flask \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
            RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
            bash "$ADAPTER_SCRIPT" 2>&1) || true

        idempotent=0
        echo "$second_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
fc = d.get('files_changed', ['non-empty'])
assert fc == [], f'Second run files_changed should be [], got {fc}'
" 2>/dev/null && idempotent=1 || true
        assert_eq "test_idempotency: second run files_changed=[]" "1" "$idempotent"
    fi
}
assert_pass_if_clean "test_idempotency"

# ── test_determinism ──────────────────────────────────────────────────────────
# Given: scaffold-adapter.sh run 3 times with OVERWRITE=1
# When:  we hash output files each run
# Then:  all 3 hashes are equal (deterministic output)
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_determinism: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _make_mock_flask_templates "$_templates_dir"

        _get_hash() {
            local out_dir="$1"
            RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_FRAMEWORK=flask \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$out_dir" \
            RECIPE_PARAM_OVERWRITE=1 \
            RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
            bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true
            # Hash content only (not paths) to ensure determinism across different output dirs
            find "$out_dir" -type f | sort | xargs md5sum 2>/dev/null | awk '{print $1}' | md5sum
        }

        _out1="$_tmpdir/out1"; _out2="$_tmpdir/out2"; _out3="$_tmpdir/out3"
        mkdir -p "$_out1" "$_out2" "$_out3"

        hash1=$(_get_hash "$_out1")
        hash2=$(_get_hash "$_out2")
        hash3=$(_get_hash "$_out3")

        assert_eq "test_determinism: run1==run2" "$hash1" "$hash2"
        assert_eq "test_determinism: run2==run3" "$hash2" "$hash3"
    fi
}
assert_pass_if_clean "test_determinism"

# ── test_overwrite_flag ───────────────────────────────────────────────────────
# Given: scaffold-adapter.sh run once, then run again with RECIPE_PARAM_OVERWRITE=1
# When:  second run executes
# Then:  files_changed is non-empty (files were overwritten)
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_overwrite_flag: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_flask_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        # First run (create files)
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=flask \
        RECIPE_PARAM_ROUTE=users \
        RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
        RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true

        # Second run with OVERWRITE=1
        overwrite_output=$(RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_FRAMEWORK=flask \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
            RECIPE_PARAM_OVERWRITE=1 \
            RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
            bash "$ADAPTER_SCRIPT" 2>&1) || true

        overwrite_ok=0
        echo "$overwrite_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
fc = d.get('files_changed', [])
assert len(fc) > 0, f'OVERWRITE=1 should produce files_changed, got {fc}'
" 2>/dev/null && overwrite_ok=1 || true
        assert_eq "test_overwrite_flag: files_changed non-empty with OVERWRITE=1" "1" "$overwrite_ok"
    fi
}
assert_pass_if_clean "test_overwrite_flag"

# ── test_generative_rollback ──────────────────────────────────────────────────
# Given: adapter creates files then encounters a failure
# When:  adapter exits non-zero (simulated by missing route param mid-run)
# Then:  adapter cleans up files it created (no orphan files)
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_generative_rollback: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_flask_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        # Run with missing ROUTE param (should fail and rollback)
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=flask \
        RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
        RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true

        # Output dir should be empty (failed run left no files)
        file_count=$(find "$_output_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
        assert_eq "test_generative_rollback: no files created on failure" "0" "$file_count"
    fi
}
assert_pass_if_clean "test_generative_rollback"

# ── test_nextjs_framework ─────────────────────────────────────────────────────
# Given: scaffold-adapter.sh invoked with RECIPE_PARAM_FRAMEWORK=nextjs
# When:  adapter executes
# Then:  different output files compared to flask (page.tsx, api-route.ts)
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_nextjs_framework: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_nextjs_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        nextjs_exit=0
        nextjs_output=$(RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_FRAMEWORK=nextjs \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
            RECIPE_TEMPLATES_DIR="$_templates_dir/nextjs" \
            bash "$ADAPTER_SCRIPT" 2>&1) || nextjs_exit=$?

        assert_eq "test_nextjs_framework: exits 0" "0" "$nextjs_exit"

        has_tsx=0
        [[ -f "$_output_dir/page.tsx" ]] && has_tsx=1 || true
        assert_eq "test_nextjs_framework: page.tsx created" "1" "$has_tsx"
    fi
}
assert_pass_if_clean "test_nextjs_framework"

# ── test_injection_safety ─────────────────────────────────────────────────────
# Given: RECIPE_PARAM_ROUTE contains shell metacharacters
# When:  adapter is invoked
# Then:  no injection occurs (process exits without running injected command)
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_injection_safety: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_flask_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        _sentinel="$_tmpdir/injection_sentinel"

        # Route name with shell metacharacters that could inject a touch command
        inject_exit=0
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=flask \
        "RECIPE_PARAM_ROUTE=users; touch $_sentinel" \
        RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
        RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || inject_exit=$?

        # Sentinel file should NOT exist (no injection)
        sentinel_exists=0
        [[ -f "$_sentinel" ]] && sentinel_exists=1 || true
        assert_eq "test_injection_safety: sentinel not created (no injection)" "0" "$sentinel_exists"
    fi
}
assert_pass_if_clean "test_injection_safety"

# ── test_params_via_env ───────────────────────────────────────────────────────
# Given: all params arrive via RECIPE_PARAM_* env vars
# When:  adapter is invoked with no positional args
# Then:  adapter succeeds using only env vars
_snapshot_fail
{
    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_params_via_env: adapter exists" "exists" "missing"
    else
        _tmpdir="$(mktemp -d)"
        _CLEANUP_DIRS+=("$_tmpdir")
        _templates_dir="$_tmpdir/templates"
        _output_dir="$_tmpdir/output"
        _make_mock_flask_templates "$_templates_dir"
        mkdir -p "$_output_dir"

        env_exit=0
        env_output=""
        # Invoke with ZERO positional args — all config via env vars
        env_output=$(RECIPE_NAME=scaffold-route \
            RECIPE_PARAM_FRAMEWORK=flask \
            RECIPE_PARAM_ROUTE=users \
            RECIPE_PARAM_OUTPUT_DIR="$_output_dir" \
            RECIPE_TEMPLATES_DIR="$_templates_dir/flask" \
            bash "$ADAPTER_SCRIPT" 2>&1) || env_exit=$?

        assert_eq "test_params_via_env: exits 0 with env vars only" "0" "$env_exit"

        valid_output=0
        echo "$env_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d.get('exit_code') == 0
" 2>/dev/null && valid_output=1 || true
        assert_eq "test_params_via_env: valid JSON output" "1" "$valid_output"
    fi
}
assert_pass_if_clean "test_params_via_env"

print_summary
