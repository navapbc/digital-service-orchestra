#!/usr/bin/env bash
# tests/hooks/test-compute-diff-hash-unbound-var.sh
# Tests that compute-diff-hash.sh works without CLAUDE_PLUGIN_ROOT set.
#
# The pre-commit hooks run outside Claude Code context where CLAUDE_PLUGIN_ROOT
# is not set. compute-diff-hash.sh must fall back to BASH_SOURCE-relative
# path resolution without crashing on unbound variable.
#
# Tests:
#   test_compute_diff_hash_succeeds_without_claude_plugin_root
#   test_compute_diff_hash_fallback_resolves_config

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PLUGIN_ROOT/plugins/dso/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-compute-diff-hash-unbound-var.sh ==="

# ── Test 1: compute-diff-hash.sh exits 0 without CLAUDE_PLUGIN_ROOT ─────────
echo "Test 1: compute-diff-hash.sh succeeds without CLAUDE_PLUGIN_ROOT"

# Work in a temp git repo so there's a valid HEAD
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cd "$TMPDIR_TEST"
git init -q -b main
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > README.md
git add -A && git commit -q -m "init"

# Stage a change so there's something to hash
echo "change" >> README.md
git add -A

# Run compute-diff-hash.sh with CLAUDE_PLUGIN_ROOT explicitly UNSET
_output=""
_exit_code=0
_output=$(unset CLAUDE_PLUGIN_ROOT && bash "$HOOK" 2>&1) || _exit_code=$?

assert_eq "test_compute_diff_hash_succeeds_without_claude_plugin_root" "0" "$_exit_code"

# ── Test 2: output is a non-empty hash string ───────────────────────────────
echo "Test 2: output is a non-empty hash when CLAUDE_PLUGIN_ROOT unset"

# Extract just the hash (last line of output, filter out warnings)
_hash=$(unset CLAUDE_PLUGIN_ROOT && bash "$HOOK" 2>/dev/null) || true

if [[ -n "$_hash" ]]; then
    assert_eq "test_hash_is_non_empty" "non_empty" "non_empty"
else
    assert_eq "test_hash_is_non_empty" "non_empty" "empty"
fi

print_summary
