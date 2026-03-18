#!/usr/bin/env bash
# tests/plugin/test-audit-skill-resolution.sh
# Portability smoke test for audit-skill-resolution.sh.
#
# Verifies the script runs correctly from the plugin directory alone.
#
# Tests covered:
#   A. Prerequisite: canonical script exists and is executable
#   B. PASS output with valid repo context
#   C. --verbose flag shows per-command output
#
# Manual run:
#   bash tests/plugin/test-audit-skill-resolution.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
CANONICAL_SCRIPT="$DSO_PLUGIN_DIR/scripts/audit-skill-resolution.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== audit-skill-resolution.sh tests ==="
echo ""

# ---------------------------------------------------------------------------
# Section A: Prerequisite — canonical script exists and is executable
# ---------------------------------------------------------------------------
echo "--- Section A: canonical script exists and is executable ---"

assert_eq "audit-skill-resolution.sh exists" "true" \
    "$(test -f "$CANONICAL_SCRIPT" && echo true || echo false)"

assert_eq "audit-skill-resolution.sh is executable" "true" \
    "$(test -x "$CANONICAL_SCRIPT" && echo true || echo false)"

# ---------------------------------------------------------------------------
# Section B: PASS output with valid repo context
# ---------------------------------------------------------------------------
echo ""
echo "--- Section B: PASS output with valid repo context ---"

exit_b=0
output_b=$(bash "$CANONICAL_SCRIPT" 2>&1) || exit_b=$?
assert_eq "audit-skill-resolution.sh exits 0 in valid repo" "0" "$exit_b"
assert_contains "output contains PASS:" "PASS:" "$output_b"

# ---------------------------------------------------------------------------
# Section C: --verbose flag shows per-command output
# ---------------------------------------------------------------------------
echo ""
echo "--- Section C: --verbose flag shows per-command output ---"

exit_c=0
output_c=$(bash "$CANONICAL_SCRIPT" --verbose 2>&1) || exit_c=$?
assert_eq "audit-skill-resolution.sh --verbose exits 0" "0" "$exit_c"
assert_contains "--verbose output shows OK: per-command lines" "OK:" "$output_c"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
