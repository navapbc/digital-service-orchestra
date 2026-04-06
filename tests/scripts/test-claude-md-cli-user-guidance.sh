#!/usr/bin/env bash
# tests/scripts/test-claude-md-cli-user-guidance.sh
# Tests: assert CLAUDE.md contains CLI_user tag application guidance.
#
# Verifies that CLAUDE.md documents:
#   1. When a user explicitly requests a bug ticket, the agent must include
#      --tags CLI_user in the ticket create command.
#   2. Autonomously-discovered bugs must NOT use the CLI_user tag.
#
# These are agent-awareness requirements — future agents reading CLAUDE.md
# must know whether to apply CLI_user based on whether the ticket was
# user-requested or autonomously discovered.
#
# This test is expected to FAIL (RED) against an unmodified CLAUDE.md that
# does not yet contain CLI_user tag application guidance.
#
# Usage: bash tests/scripts/test-claude-md-cli-user-guidance.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-claude-md-cli-user-guidance.sh ==="
echo ""

claude_md_content="$(cat "$CLAUDE_MD")"

# ── test_cli_user_tag_user_requested ──────────────────────────────────────────
# CLAUDE.md must document that when a user explicitly requests a bug ticket,
# the agent includes --tags CLI_user in the .claude/scripts/dso ticket create
# command. Future agents must know to apply this tag for user-initiated tickets.
assert_contains \
    "test_cli_user_tag_user_requested: CLAUDE.md mentions CLI_user tag for user-requested bug tickets" \
    "CLI_user" \
    "$claude_md_content"
echo ""

# ── test_cli_user_tag_not_for_autonomous ──────────────────────────────────────
# CLAUDE.md must document that bugs found autonomously by agents (anti-pattern
# scans, debug-everything discovery) must NOT include the CLI_user tag.
# This ensures CLI_user accurately reflects user intent.
# Check for CLI_user paired with negation near "autonomous" phrasing.
# Uses a flexible pattern (grep for "Do NOT" near "CLI_user") rather than
# exact wording, so correct implementations with different phrasing still pass.
# Proximity check: within 3 lines of any CLI_user mention, must find prohibition language.
# This prevents false positives from "Do NOT" appearing elsewhere in CLAUDE.md.
_cli_context=$(echo "$claude_md_content" | grep -A3 -B3 "CLI_user")
_tmp="$_cli_context"; shopt -s nocasematch
if [[ "$_tmp" =~ "Do NOT"|"MUST NOT"|"must not"|autonomous ]]; then
    shopt -u nocasematch
    echo "PASS: test_cli_user_tag_not_for_autonomous: CLAUDE.md clarifies CLI_user must not be used for autonomously-discovered bugs"
    (( ++PASS ))
else
    shopt -u nocasematch
    echo "FAIL: test_cli_user_tag_not_for_autonomous: CLAUDE.md clarifies CLI_user must not be used for autonomously-discovered bugs"
    echo "  expected: prohibition language (Do NOT / MUST NOT / autonomous) within 3 lines of CLI_user"
    echo "  actual:   no prohibition context found near CLI_user in CLAUDE.md"
    (( ++FAIL ))
fi
echo ""

print_summary
