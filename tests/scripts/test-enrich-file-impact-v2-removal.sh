#!/usr/bin/env bash
# tests/scripts/test-enrich-file-impact-v2-removal.sh
# Tests asserting that enrich-file-impact.sh has no v2 (flat-file) code paths.
#
# Validates (RED tests — will FAIL until v2 code is removed from enrich-file-impact.sh):
#   - No TK= variable assignment (v2 used tk binary directly)
#   - No TICKETS_DIR-based .md fallback branch (v2 flat-file pattern)
#   - No _use_v3 internal variable (v2/v3 branch logic no longer needed)
#
# Usage: bash tests/scripts/test-enrich-file-impact-v2-removal.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENRICH_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/enrich-file-impact.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-enrich-file-impact-v2-removal.sh ==="

# ── test_enrich_file_impact_no_TK_variable ────────────────────────────────────
# After v2 removal, enrich-file-impact.sh should NOT contain a TK= variable
# assignment (the v2 code used `TK` to invoke the tk binary directly).
# RED: currently the script has `TK="${TK:-$SCRIPT_DIR/tk}"` → grep exits 0 → assert fails.
test_enrich_file_impact_no_TK_variable() {
    local exit_code
    grep -q '^TK=' "$ENRICH_SCRIPT" 2>/dev/null
    exit_code=$?
    # We expect grep to find NO match (exit non-zero) after v2 removal.
    # In RED state (v2 still present), grep finds the match → exit 0 → assert_eq fails.
    assert_eq "test_enrich_file_impact_no_TK_variable: no ^TK= line in enrich-file-impact.sh" "1" "$exit_code"
}

# ── test_enrich_file_impact_no_v2_fallback_branch ────────────────────────────
# After v2 removal, the flat-file fallback branch (TICKETS_DIR/<ID>.md) should
# be gone. The pattern `ticket_file=` identifies the direct-append path.
# RED: currently the script contains `ticket_file="${TICKETS_DIR:-...}/${ID}.md"` → grep exits 0 → assert fails.
test_enrich_file_impact_no_v2_fallback_branch() {
    local exit_code
    grep -q 'ticket_file=' "$ENRICH_SCRIPT" 2>/dev/null
    exit_code=$?
    # We expect grep to find NO match (exit non-zero) after v2 removal.
    assert_eq "test_enrich_file_impact_no_v2_fallback_branch: no ticket_file= (v2 flat-file pattern) in enrich-file-impact.sh" "1" "$exit_code"
}

# ── test_enrich_file_impact_no_use_v3_variable ───────────────────────────────
# After v2 removal, the _use_v3 branching variable should no longer exist in
# enrich-file-impact.sh. The script should always use the v3 ticket CLI.
# RED: currently the script has `_use_v3=false` and related logic → grep exits 0 → assert fails.
test_enrich_file_impact_no_use_v3_variable() {
    local exit_code
    grep -q '_use_v3' "$ENRICH_SCRIPT" 2>/dev/null
    exit_code=$?
    # We expect grep to find NO match (exit non-zero) after v2 removal.
    assert_eq "test_enrich_file_impact_no_use_v3_variable: no _use_v3 variable in enrich-file-impact.sh" "1" "$exit_code"
}

# Run all tests
test_enrich_file_impact_no_TK_variable
test_enrich_file_impact_no_v2_fallback_branch
test_enrich_file_impact_no_use_v3_variable

print_summary
