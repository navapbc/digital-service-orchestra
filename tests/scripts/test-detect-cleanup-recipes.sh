#!/usr/bin/env bash
# tests/scripts/test-detect-cleanup-recipes.sh
# RED-phase tests for plugins/dso/scripts/sprint/detect-cleanup-recipes.sh.
#
# The script under test does NOT exist yet; all tests must FAIL.
#
# Tests inject RECIPE_REGISTRY_PATH and DIFF_INPUT env vars to allow test isolation.
# DIFF_INPUT is a path to a file containing the simulated git diff (or empty for no diff).
# RECIPE_REGISTRY_PATH points to the test fixture registry (not the live registry).
#
# Usage: bash tests/scripts/test-detect-cleanup-recipes.sh
# Returns: exit 1 (all tests fail — RED phase)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT_UNDER_TEST="$REPO_ROOT/plugins/dso/scripts/sprint/detect-cleanup-recipes.sh"
TEST_REGISTRY="$REPO_ROOT/tests/fixtures/recipe-registry-test.yaml"

echo "=== test-detect-cleanup-recipes.sh ==="
echo "Script: $SCRIPT_UNDER_TEST"
echo "Registry: $TEST_REGISTRY"
echo ""

# ── Cleanup ───────────────────────────────────────────────────────────────────
_CLEANUP_FILES=()
_cleanup() { for f in "${_CLEANUP_FILES[@]:-}"; do rm -f "$f"; done; }
trap _cleanup EXIT

# ── (a) Python diff with unsorted/duplicate imports → outputs normalize-imports python ──
# Given: a git diff containing .py files with import disorder (duplicate/unsorted imports)
# When:  detect-cleanup-recipes.sh is invoked with that diff via DIFF_INPUT
# Then:  stdout includes "normalize-imports" and language "python"

_snapshot_fail
{
    _py_diff_file="$(mktemp "${TMPDIR:-/tmp}/test-detect-cleanup-python-diff.XXXXXX")"
    _CLEANUP_FILES+=("$_py_diff_file")
    cat > "$_py_diff_file" <<'DIFF'
diff --git a/src/api.py b/src/api.py
index abc1234..def5678 100644
--- a/src/api.py
+++ b/src/api.py
@@ -1,6 +1,8 @@
+import os
 import sys
+import os
 import json
-import os
 import sys
 from flask import Flask
DIFF

    output_py=""
    output_py="$(RECIPE_REGISTRY_PATH="$TEST_REGISTRY" DIFF_INPUT="$_py_diff_file" \
        bash "$SCRIPT_UNDER_TEST" 2>/dev/null)" || true

    assert_contains \
        "python_diff: normalize-imports recipe present" \
        "normalize-imports" \
        "$output_py"

    assert_contains \
        "python_diff: language python present" \
        "python" \
        "$output_py"
}
assert_pass_if_clean "test_python_diff_outputs_normalize_imports_python"

# ── (b) No Python/TypeScript/Ruby files → outputs nothing ─────────────────────
# Given: a git diff with only Go files changed (no py/ts/rb/js/jsx/tsx files)
# When:  detect-cleanup-recipes.sh is invoked with that diff via DIFF_INPUT
# Then:  stdout is empty (no recipes applicable) and exit code is 0

_snapshot_fail
{
    _go_diff_file="$(mktemp "${TMPDIR:-/tmp}/test-detect-cleanup-go-diff.XXXXXX")"
    _CLEANUP_FILES+=("$_go_diff_file")
    cat > "$_go_diff_file" <<'DIFF'
diff --git a/main.go b/main.go
index abc1234..def5678 100644
--- a/main.go
+++ b/main.go
@@ -1,4 +1,5 @@
 package main
+
 import "fmt"

 func main() {
DIFF

    output_go=""
    exit_code_go=0
    output_go="$(RECIPE_REGISTRY_PATH="$TEST_REGISTRY" DIFF_INPUT="$_go_diff_file" \
        bash "$SCRIPT_UNDER_TEST" 2>/dev/null)" || exit_code_go=$?

    assert_eq \
        "no_py_ts_rb_diff: exits 0" \
        "0" \
        "$exit_code_go"

    assert_eq \
        "no_py_ts_rb_diff: output is empty" \
        "" \
        "$output_go"
}
assert_pass_if_clean "test_no_py_ts_rb_diff_outputs_nothing"

# ── (c) TypeScript-only diff → outputs normalize-imports typescript ────────────
# Given: a git diff with only .ts/.tsx files changed, containing import disorder
# When:  detect-cleanup-recipes.sh is invoked with that diff via DIFF_INPUT
# Then:  stdout includes "normalize-imports" and language "typescript"

_snapshot_fail
{
    _ts_diff_file="$(mktemp "${TMPDIR:-/tmp}/test-detect-cleanup-ts-diff.XXXXXX")"
    _CLEANUP_FILES+=("$_ts_diff_file")
    cat > "$_ts_diff_file" <<'DIFF'
diff --git a/src/components/Button.tsx b/src/components/Button.tsx
index abc1234..def5678 100644
--- a/src/components/Button.tsx
+++ b/src/components/Button.tsx
@@ -1,5 +1,6 @@
+import React from 'react';
 import { useState } from 'react';
+import React from 'react';
-import React from 'react';
 import { useEffect } from 'react';
DIFF

    output_ts=""
    output_ts="$(RECIPE_REGISTRY_PATH="$TEST_REGISTRY" DIFF_INPUT="$_ts_diff_file" \
        bash "$SCRIPT_UNDER_TEST" 2>/dev/null)" || true

    assert_contains \
        "ts_diff: normalize-imports recipe present" \
        "normalize-imports" \
        "$output_ts"

    assert_contains \
        "ts_diff: language typescript present" \
        "typescript" \
        "$output_ts"

    assert_not_contains \
        "ts_diff: python not present" \
        "python" \
        "$output_ts"
}
assert_pass_if_clean "test_ts_diff_outputs_normalize_imports_typescript"

# ── (d) --format=json flag → outputs JSON array with name and language ─────────
# Given: a git diff with Python files having import disorder
# When:  detect-cleanup-recipes.sh is invoked with --format=json
# Then:  stdout is a JSON array containing {"name":"normalize-imports","language":"python"}

_snapshot_fail
{
    _json_diff_file="$(mktemp "${TMPDIR:-/tmp}/test-detect-cleanup-json-diff.XXXXXX")"
    _CLEANUP_FILES+=("$_json_diff_file")
    cat > "$_json_diff_file" <<'DIFF'
diff --git a/src/models.py b/src/models.py
index abc1234..def5678 100644
--- a/src/models.py
+++ b/src/models.py
@@ -1,5 +1,6 @@
+import uuid
 import os
+import os
-import uuid
 import sys
 from dataclasses import dataclass
DIFF

    output_json=""
    output_json="$(RECIPE_REGISTRY_PATH="$TEST_REGISTRY" DIFF_INPUT="$_json_diff_file" \
        bash "$SCRIPT_UNDER_TEST" --format=json 2>/dev/null)" || true

    # Must be valid JSON
    json_valid=0
    echo "$output_json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d, list)" \
        2>/dev/null && json_valid=1 || true
    assert_eq \
        "json_format: output is valid JSON array" \
        "1" \
        "$json_valid"

    # Must contain the expected recipe entry
    json_has_entry=0
    echo "$output_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
matches = [e for e in d if e.get('name') == 'normalize-imports' and e.get('language') == 'python']
assert len(matches) >= 1, f'Expected normalize-imports/python in: {d}'
" 2>/dev/null && json_has_entry=1 || true

    assert_eq \
        "json_format: JSON array contains normalize-imports/python entry" \
        "1" \
        "$json_has_entry"
}
assert_pass_if_clean "test_format_json_outputs_json_array"

# ── (e) Empty diff → outputs nothing, exit 0 ──────────────────────────────────
# Given: an empty file as diff input (no staged files, no changes)
# When:  detect-cleanup-recipes.sh is invoked with that empty diff via DIFF_INPUT
# Then:  stdout is empty and exit code is 0

_snapshot_fail
{
    _empty_diff_file="$(mktemp "${TMPDIR:-/tmp}/test-detect-cleanup-empty-diff.XXXXXX")"
    _CLEANUP_FILES+=("$_empty_diff_file")
    # Empty file — no diff content

    output_empty=""
    exit_code_empty=0
    output_empty="$(RECIPE_REGISTRY_PATH="$TEST_REGISTRY" DIFF_INPUT="$_empty_diff_file" \
        bash "$SCRIPT_UNDER_TEST" 2>/dev/null)" || exit_code_empty=$?

    assert_eq \
        "empty_diff: exits 0" \
        "0" \
        "$exit_code_empty"

    assert_eq \
        "empty_diff: output is empty" \
        "" \
        "$output_empty"
}
assert_pass_if_clean "test_empty_diff_outputs_nothing"

print_summary
