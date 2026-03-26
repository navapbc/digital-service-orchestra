#!/usr/bin/env bash
# tests/scripts/test-claude-md-fix-bug-gates.sh
# Tests: assert CLAUDE.md reflects hypothesis enforcement gates added in epic b7ac-1d7f.
#
# Verifies that CLAUDE.md documents:
#   1. hypothesis_tests field in the fix-bug RESULT schema (replaces tests_run)
#   2. RED-before-fix gate (Step 5.5 blocks code modification until RED test confirmed)
#
# These are agent-awareness requirements — future agents reading CLAUDE.md must know
# the investigation RESULT must include hypothesis_tests and that code changes are
# blocked until a RED test is confirmed failing.
#
# Usage: bash tests/scripts/test-claude-md-fix-bug-gates.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-claude-md-fix-bug-gates.sh ==="
echo ""

# ── test_claude_md_hypothesis_tests_field ─────────────────────────────────────
# CLAUDE.md must reference hypothesis_tests as the RESULT schema field
# for fix-bug investigation results. This replaces the old tests_run field.
# Future agents need to know investigation results require hypothesis_tests.
claude_md_content="$(cat "$CLAUDE_MD")"

assert_contains \
    "test_claude_md_hypothesis_tests_field: CLAUDE.md mentions hypothesis_tests" \
    "hypothesis_tests" \
    "$claude_md_content"
echo ""

# ── test_claude_md_red_before_fix_gate ────────────────────────────────────────
# CLAUDE.md must reference the RED-before-fix gate so agents know that
# code modification (Edit, Write, fix sub-agent dispatch) is blocked until
# a RED test is confirmed failing.
assert_contains \
    "test_claude_md_red_before_fix_gate: CLAUDE.md mentions RED-before-fix gate" \
    "RED-before-fix" \
    "$claude_md_content"
echo ""

print_summary
