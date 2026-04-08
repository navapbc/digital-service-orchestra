#!/usr/bin/env bash
# tests/scripts/test-scaffold-templates.sh
# Behavioral tests for scaffold-adapter.sh template output.
#
# Testing mode: RED — scaffold-adapter.sh and template files do not yet exist.
# These tests must FAIL before templates and adapter are created.
#
# Usage: bash tests/scripts/test-scaffold-templates.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# Env var overrides:
#   RECIPE_TEMPLATES_DIR — override default template directory

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ADAPTER_SCRIPT="$REPO_ROOT/plugins/dso/scripts/recipe-adapters/scaffold-adapter.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scaffold-templates.sh ==="

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── test_flask_blueprint_syntax ───────────────────────────────────────────────
# Given: scaffold-adapter.sh exists and RECIPE_TEMPLATES_DIR points to real templates
# When:  we generate a flask/users route
# Then:  the generated blueprint.py is syntactically valid Python
_snapshot_fail
{
    _tmpout="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpout")

    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_flask_blueprint_syntax: adapter exists" "exists" "missing"
    else
        gen_exit=0
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=flask \
        RECIPE_PARAM_ROUTE=users \
        RECIPE_PARAM_OUTPUT_DIR="$_tmpout" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || gen_exit=$?

        # Check generated route.py file (named users.py after substitution)
        blueprint_file="$_tmpout/users.py"
        if [[ ! -f "$blueprint_file" ]]; then
            # Try route.py
            blueprint_file="$_tmpout/route.py"
        fi
        compile_exit=0
        python3 -m py_compile "$blueprint_file" 2>/dev/null || compile_exit=$?
        assert_eq "test_flask_blueprint_syntax: py_compile exit 0" "0" "$compile_exit"
    fi
}
assert_pass_if_clean "test_flask_blueprint_syntax"

# ── test_flask_template_html ──────────────────────────────────────────────────
# Given: scaffold-adapter.sh generates templates for flask/users
# When:  we check the output directory
# Then:  template.html exists and contains expected HTML structure
_snapshot_fail
{
    _tmpout="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpout")

    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_flask_template_html: adapter exists" "exists" "missing"
    else
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=flask \
        RECIPE_PARAM_ROUTE=users \
        RECIPE_PARAM_OUTPUT_DIR="$_tmpout" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true

        html_file="$_tmpout/template.html"
        if [[ -f "$html_file" ]]; then
            has_h1=0
            grep -q '<h1>' "$html_file" && has_h1=1 || true
            assert_eq "test_flask_template_html: contains <h1>" "1" "$has_h1"
        else
            assert_eq "test_flask_template_html: template.html exists" "exists" "missing"
        fi
    fi
}
assert_pass_if_clean "test_flask_template_html"

# ── test_nextjs_page_syntax ───────────────────────────────────────────────────
# Given: scaffold-adapter.sh generates output for nextjs/users
# When:  we check the generated page.tsx
# Then:  it exists and contains expected React function export
_snapshot_fail
{
    _tmpout="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpout")

    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_nextjs_page_syntax: adapter exists" "exists" "missing"
    else
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=nextjs \
        RECIPE_PARAM_ROUTE=users \
        RECIPE_PARAM_OUTPUT_DIR="$_tmpout" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true

        page_file="$_tmpout/page.tsx"
        if [[ -f "$page_file" ]]; then
            has_export=0
            grep -q 'export default function' "$page_file" && has_export=1 || true
            assert_eq "test_nextjs_page_syntax: contains 'export default function'" "1" "$has_export"
        else
            assert_eq "test_nextjs_page_syntax: page.tsx exists" "exists" "missing"
        fi
    fi
}
assert_pass_if_clean "test_nextjs_page_syntax"

# ── test_nextjs_api_route_syntax ──────────────────────────────────────────────
# Given: scaffold-adapter.sh generates output for nextjs/users
# When:  we check the generated api-route.ts
# Then:  it exists and contains a handler function
_snapshot_fail
{
    _tmpout="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpout")

    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_nextjs_api_route_syntax: adapter exists" "exists" "missing"
    else
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=nextjs \
        RECIPE_PARAM_ROUTE=users \
        RECIPE_PARAM_OUTPUT_DIR="$_tmpout" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true

        api_file="$_tmpout/api-route.ts"
        if [[ -f "$api_file" ]]; then
            has_handler=0
            grep -q 'function handler' "$api_file" && has_handler=1 || true
            assert_eq "test_nextjs_api_route_syntax: contains 'function handler'" "1" "$has_handler"
        else
            assert_eq "test_nextjs_api_route_syntax: api-route.ts exists" "exists" "missing"
        fi
    fi
}
assert_pass_if_clean "test_nextjs_api_route_syntax"

# ── test_route_name_substituted ───────────────────────────────────────────────
# Given: scaffold-adapter.sh generates output with RECIPE_PARAM_ROUTE=orders
# When:  we check the generated files
# Then:  {{ROUTE_NAME}} placeholder is NOT present; "orders" IS present
_snapshot_fail
{
    _tmpout="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_tmpout")

    if [[ ! -f "$ADAPTER_SCRIPT" ]]; then
        assert_eq "test_route_name_substituted: adapter exists" "exists" "missing"
    else
        RECIPE_NAME=scaffold-route \
        RECIPE_PARAM_FRAMEWORK=flask \
        RECIPE_PARAM_ROUTE=orders \
        RECIPE_PARAM_OUTPUT_DIR="$_tmpout" \
        bash "$ADAPTER_SCRIPT" >/dev/null 2>&1 || true

        # Check that no file contains the unreplaced placeholder
        placeholder_found=0
        grep -rl '{{ROUTE_NAME}}' "$_tmpout" 2>/dev/null && placeholder_found=1 || true
        assert_eq "test_route_name_substituted: no {{ROUTE_NAME}} placeholder remaining" "0" "$placeholder_found"

        # Check that "orders" appears in at least one generated file
        route_name_found=0
        grep -rl 'orders' "$_tmpout" 2>/dev/null | grep -q . && route_name_found=1 || true
        assert_eq "test_route_name_substituted: route name 'orders' appears in output" "1" "$route_name_found"
    fi
}
assert_pass_if_clean "test_route_name_substituted"

print_summary
