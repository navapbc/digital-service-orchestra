#!/usr/bin/env bash
# tests/scripts/test-write-reviewer-findings-output-flag.sh
# Bug a119-cfe7: Deep tier sonnet agents ignore FINDINGS_OUTPUT — write to
# canonical path instead of slot files. write-reviewer-findings.sh must support
# --output <path> to allow parallel agents to write to slot-specific paths.
#
# Usage: bash tests/scripts/test-write-reviewer-findings-output-flag.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-write-reviewer-findings-output-flag.sh ==="
echo ""

SCRIPT="$REPO_ROOT/plugins/dso/scripts/write-reviewer-findings.sh"

# ── Test 1: write-reviewer-findings.sh accepts --output flag ─────────────────
echo "--- test_accepts_output_flag ---"
_snapshot_fail
_has_output_flag=0
if grep -qE '\-\-output|FINDINGS_OUTPUT' "$SCRIPT"; then
    _has_output_flag=1
fi
assert_eq "test_accepts_output_flag: write-reviewer-findings.sh must support --output or FINDINGS_OUTPUT" \
    "1" "$_has_output_flag"
assert_pass_if_clean "test_accepts_output_flag"

# ── Test 2: reviewer agent base template references FINDINGS_OUTPUT ──────────
echo ""
echo "--- test_agent_template_uses_findings_output ---"
_snapshot_fail
BASE_TEMPLATE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-base.md"
_template_has_findings_output=0
if [ -f "$BASE_TEMPLATE" ] && grep -qE 'FINDINGS_OUTPUT|--output' "$BASE_TEMPLATE"; then
    _template_has_findings_output=1
fi
assert_eq "test_agent_template_uses_findings_output: reviewer-base.md must reference FINDINGS_OUTPUT or --output" \
    "1" "$_template_has_findings_output"
assert_pass_if_clean "test_agent_template_uses_findings_output"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
