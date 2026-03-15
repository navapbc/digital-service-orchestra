#!/usr/bin/env bash
# Test parse_json_field hardening: array detection, deep nesting, warnings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/assert.sh"

REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
unset _DEPS_LOADED
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

# ── Test 1: Array value should return empty with warning to stderr ──
stderr_output=$(parse_json_field '{"items":["a","b","c"],"name":"test"}' '.items' 2>&1 1>/dev/null || true)
result=$(parse_json_field '{"items":["a","b","c"],"name":"test"}' '.items' 2>/dev/null)
assert_eq "array_returns_empty" "" "$result"
assert_contains "array_warns_stderr" "array" "$stderr_output"

# ── Test 2: Existing behavior preserved — top-level string ──
result=$(parse_json_field '{"name":"hello","age":"30"}' '.name' 2>/dev/null)
assert_eq "top_level_string" "hello" "$result"

# ── Test 3: Existing behavior preserved — nested string ──
result=$(parse_json_field '{"tool_input":{"command":"git status"}}' '.tool_input.command' 2>/dev/null)
assert_eq "nested_string" "git status" "$result"

# ── Test 4: Deep nesting (2+ levels) — support .a.b.c ──
result=$(parse_json_field '{"a":{"b":{"c":"deep_value"}}}' '.a.b.c' 2>/dev/null)
assert_eq "deep_nesting_2level" "deep_value" "$result"

# ── Test 5: Empty input returns empty ──
result=$(parse_json_field '' '.name' 2>/dev/null)
assert_eq "empty_input" "" "$result"

# ── Test 6: Malformed JSON returns empty ──
result=$(parse_json_field '{broken' '.name' 2>/dev/null)
assert_eq "malformed_json" "" "$result"

# ── Test 7: Boolean value preserved ──
result=$(parse_json_field '{"enabled":true}' '.enabled' 2>/dev/null)
assert_eq "boolean_value" "true" "$result"

# ── Test 8: Numeric value preserved ──
result=$(parse_json_field '{"count":42}' '.count' 2>/dev/null)
assert_eq "numeric_value" "42" "$result"

# ── Test 9: Null value preserved ──
result=$(parse_json_field '{"val":null}' '.val' 2>/dev/null)
assert_eq "null_value" "null" "$result"

# ── Test 10: Missing field returns empty ──
result=$(parse_json_field '{"name":"test"}' '.missing' 2>/dev/null)
assert_eq "missing_field" "" "$result"

print_summary
