#!/usr/bin/env bash
# tests/scripts/test-ticket-cli-reference-md-tags.sh
# Tests: assert ticket-cli-reference.md documents --tags flag for ticket create.
#
# This test is expected to FAIL (RED) against an unmodified ticket-cli-reference.md
# that has no --tags documentation.
#
# Usage: bash tests/scripts/test-ticket-cli-reference-md-tags.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
REFERENCE_MD="$REPO_ROOT/plugins/dso/docs/ticket-cli-reference.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ticket-cli-reference-md-tags.sh ==="
echo ""

ref_content="$(cat "$REFERENCE_MD")"

# ── test_ticket_cli_reference_has_tags_flag ───────────────────────────────────
# ticket-cli-reference.md is injected into agent prompts at tool-use time.
# Agents consulting this reference must know --tags exists on ticket create.
# RED: will FAIL until --tags is documented anywhere in the reference.
assert_contains \
    "test_ticket_cli_reference_has_tags_flag: ticket-cli-reference.md documents --tags flag" \
    "--tags" \
    "$ref_content"
echo ""

# ── test_ticket_cli_reference_tags_in_create_section ─────────────────────────
# --tags must be documented in proximity to the ticket create subcommand so
# agents know it applies specifically to create, not some other subcommand.
# RED: will FAIL until --tags appears near a ticket create example.
_tags_context=$(printf '%s' "$ref_content" | grep -A20 -B2 "ticket create\|create.*bug\|create.*story\|create.*task\|create.*epic")
if [[ "$_tags_context" == *"--tags"* ]]; then
    echo "PASS: test_ticket_cli_reference_tags_in_create_section: --tags appears near ticket create section"
    (( ++PASS ))
else
    echo "FAIL: test_ticket_cli_reference_tags_in_create_section: --tags not found near ticket create section"
    echo "  expected: --tags documented in the ticket create subcommand section"
    echo "  actual:   --tags not found within 20 lines of ticket create examples"
    (( ++FAIL ))
fi
echo ""

# ── test_ticket_cli_reference_cli_user_example ───────────────────────────────
# ticket-cli-reference.md must include a CLI_user example so agents know the
# specific tag value to use when a user explicitly requests a ticket.
# RED: will FAIL until CLI_user appears in the reference doc.
assert_contains \
    "test_ticket_cli_reference_cli_user_example: ticket-cli-reference.md includes CLI_user tag example" \
    "CLI_user" \
    "$ref_content"
echo ""

print_summary
