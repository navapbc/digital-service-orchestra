#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-audit-skill-resolution.sh
# Portability smoke test for audit-skill-resolution.sh.
#
# Verifies the script runs correctly from the plugin directory alone.
#
# Tests covered:
#   A. Prerequisite: canonical script exists and is executable
#   B. PASS output with valid repo context
#   C. --verbose flag shows per-command output
#   D. Wrapper script exists, is thin (< 15 lines), and contains exec delegation
#   E. audit-skill-resolution.sh is listed in test-plugin-self-sufficiency.sh MIGRATED_SCRIPTS
#
# Manual run:
#   bash lockpick-workflow/tests/plugin/test-audit-skill-resolution.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/audit-skill-resolution.sh"

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
# Section D: Wrapper script exists, is thin (< 15 lines), and delegates via exec
# ---------------------------------------------------------------------------
echo ""
echo "--- Section D: wrapper script is thin and delegates via exec ---"

REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/audit-skill-resolution.sh"

assert_eq "scripts/audit-skill-resolution.sh wrapper exists" "true" \
    "$(test -f "$WRAPPER_SCRIPT" && echo true || echo false)"

assert_eq "scripts/audit-skill-resolution.sh wrapper is executable" "true" \
    "$(test -x "$WRAPPER_SCRIPT" && echo true || echo false)"

wrapper_has_exec=$(grep -c 'exec.*audit-skill-resolution\.sh' "$WRAPPER_SCRIPT" 2>/dev/null || echo "0")
assert_ne "wrapper contains exec delegation to plugin" "0" "$wrapper_has_exec"

LINE_COUNT="$(wc -l < "$WRAPPER_SCRIPT" 2>/dev/null || echo 999)"
assert_eq "wrapper is thin (< 15 lines)" "true" \
    "$([ "$LINE_COUNT" -lt 15 ] && echo true || echo false)"

# ---------------------------------------------------------------------------
# Section E: audit-skill-resolution.sh is listed in MIGRATED_SCRIPTS
# ---------------------------------------------------------------------------
echo ""
echo "--- Section E: listed in test-plugin-self-sufficiency.sh MIGRATED_SCRIPTS ---"

SELF_SUFFICIENCY_TEST="$PLUGIN_ROOT/tests/test-plugin-self-sufficiency.sh"

assert_eq "test-plugin-self-sufficiency.sh exists" "true" \
    "$(test -f "$SELF_SUFFICIENCY_TEST" && echo true || echo false)"

listed_count=$(grep -c 'audit-skill-resolution\.sh' "$SELF_SUFFICIENCY_TEST" 2>/dev/null || echo "0")
assert_ne "audit-skill-resolution.sh listed in MIGRATED_SCRIPTS" "0" "$listed_count"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
