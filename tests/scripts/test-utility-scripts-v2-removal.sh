#!/usr/bin/env bash
# tests/scripts/test-utility-scripts-v2-removal.sh
# RED tests: assert no v2 code in 6 utility scripts:
#   issue-quality-check.sh, check-acceptance-criteria.sh, issue-summary.sh,
#   issue-batch.sh, release-debug-lock.sh, qualify-ticket-refs.sh
#
# TDD RED phase (8385-dd5b): all tests that check TK= or functional 'tk ' usage
# FAIL until the GREEN story removes v2 code from these scripts.
#
# These tests assert that v2 code is ABSENT. They currently FAIL because v2
# code IS present. After the GREEN story removes the v2 code, they will pass.
#
# Usage: bash tests/scripts/test-utility-scripts-v2-removal.sh
# Returns: exit 1 in RED state (v2 code present), exit 0 in GREEN state (v2 removed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_SCRIPTS="$PLUGIN_ROOT/plugins/dso/scripts"

ISSUE_QUALITY_CHECK="$DSO_SCRIPTS/issue-quality-check.sh"
CHECK_AC="$DSO_SCRIPTS/check-acceptance-criteria.sh"
ISSUE_SUMMARY="$DSO_SCRIPTS/issue-summary.sh"
ISSUE_BATCH="$DSO_SCRIPTS/issue-batch.sh"
RELEASE_DEBUG_LOCK="$DSO_SCRIPTS/release-debug-lock.sh"
QUALIFY_TICKET_REFS="$DSO_SCRIPTS/qualify-ticket-refs.sh"

PASS=0
FAIL=0

echo "=== test-utility-scripts-v2-removal.sh ==="
echo ""

# ── issue-quality-check.sh ────────────────────────────────────────────────────

# test_issue_quality_check_no_TK_variable
# issue-quality-check.sh must NOT define the TK= variable (v2 pattern).
# RED: FAIL because issue-quality-check.sh still has 'TK="${TK:-$SCRIPT_DIR/tk}"' on line 22.
echo "Test: test_issue_quality_check_no_TK_variable"
if grep -q '^TK=' "$ISSUE_QUALITY_CHECK"; then
    echo "  FAIL: issue-quality-check.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: issue-quality-check.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# test_issue_quality_check_no_tk_call
# issue-quality-check.sh must NOT invoke the bare 'tk' command (v2 pattern).
# RED: check for functional tk calls (non-comment lines invoking tk).
echo "Test: test_issue_quality_check_no_tk_call"
if grep -qE '^[^#]*\btk ' "$ISSUE_QUALITY_CHECK"; then
    echo "  FAIL: issue-quality-check.sh still contains functional 'tk ' invocation (v2 pattern)" >&2
    echo "        Expected v2 tk calls to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: issue-quality-check.sh does not contain functional 'tk ' invocation"
    (( PASS++ ))
fi
echo ""

# ── check-acceptance-criteria.sh ─────────────────────────────────────────────

# test_check_ac_no_TK_variable
# check-acceptance-criteria.sh must NOT define the TK= variable (v2 pattern).
# RED: FAIL because check-acceptance-criteria.sh still has 'TK="${TK:-$SCRIPT_DIR/tk}"' on line 11.
echo "Test: test_check_ac_no_TK_variable"
if grep -q '^TK=' "$CHECK_AC"; then
    echo "  FAIL: check-acceptance-criteria.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: check-acceptance-criteria.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# test_check_ac_no_tk_call
# check-acceptance-criteria.sh must NOT invoke the bare 'tk' command (v2 pattern).
echo "Test: test_check_ac_no_tk_call"
if grep -qE '^[^#]*\btk ' "$CHECK_AC"; then
    echo "  FAIL: check-acceptance-criteria.sh still contains functional 'tk ' invocation (v2 pattern)" >&2
    echo "        Expected v2 tk calls to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: check-acceptance-criteria.sh does not contain functional 'tk ' invocation"
    (( PASS++ ))
fi
echo ""

# ── issue-summary.sh ──────────────────────────────────────────────────────────

# test_issue_summary_no_TK_variable
# issue-summary.sh must NOT define the TK= variable (v2 pattern).
# RED: FAIL because issue-summary.sh still has 'TK="${TK:-$SCRIPT_DIR/tk}"' on line 20.
echo "Test: test_issue_summary_no_TK_variable"
if grep -q '^TK=' "$ISSUE_SUMMARY"; then
    echo "  FAIL: issue-summary.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: issue-summary.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# test_issue_summary_no_tk_call
# issue-summary.sh must NOT invoke the bare 'tk' command (v2 pattern).
echo "Test: test_issue_summary_no_tk_call"
if grep -qE '^[^#]*\btk ' "$ISSUE_SUMMARY"; then
    echo "  FAIL: issue-summary.sh still contains functional 'tk ' invocation (v2 pattern)" >&2
    echo "        Expected v2 tk calls to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: issue-summary.sh does not contain functional 'tk ' invocation"
    (( PASS++ ))
fi
echo ""

# ── issue-batch.sh ────────────────────────────────────────────────────────────

# test_issue_batch_no_TK_variable
# issue-batch.sh must NOT define the TK= variable (v2 pattern).
# RED: FAIL because issue-batch.sh still has 'TK="${TK:-$SCRIPT_DIR/tk}"' on line 39.
echo "Test: test_issue_batch_no_TK_variable"
if grep -q '^TK=' "$ISSUE_BATCH"; then
    echo "  FAIL: issue-batch.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: issue-batch.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# test_issue_batch_no_tk_call
# issue-batch.sh must NOT invoke the bare 'tk' command (v2 pattern).
echo "Test: test_issue_batch_no_tk_call"
if grep -qE '^[^#]*\btk ' "$ISSUE_BATCH"; then
    echo "  FAIL: issue-batch.sh still contains functional 'tk ' invocation (v2 pattern)" >&2
    echo "        Expected v2 tk calls to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: issue-batch.sh does not contain functional 'tk ' invocation"
    (( PASS++ ))
fi
echo ""

# ── release-debug-lock.sh ─────────────────────────────────────────────────────

# test_release_debug_lock_no_TK_variable
# release-debug-lock.sh must NOT define the TK= variable (v2 pattern).
# NOTE: release-debug-lock.sh has no TK= assignment currently — this test starts GREEN.
echo "Test: test_release_debug_lock_no_TK_variable"
if grep -q '^TK=' "$RELEASE_DEBUG_LOCK"; then
    echo "  FAIL: release-debug-lock.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: release-debug-lock.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# test_release_debug_lock_no_tk_call
# release-debug-lock.sh must NOT invoke the bare 'tk' command (v2 pattern).
# RED: FAIL because release-debug-lock.sh has 'tk show "$LOCK_ID"' on line 25.
echo "Test: test_release_debug_lock_no_tk_call"
if grep -qE '^[^#]*\btk ' "$RELEASE_DEBUG_LOCK"; then
    echo "  FAIL: release-debug-lock.sh still contains functional 'tk ' invocation (v2 pattern)" >&2
    echo "        Expected v2 tk calls to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: release-debug-lock.sh does not contain functional 'tk ' invocation"
    (( PASS++ ))
fi
echo ""

# ── qualify-ticket-refs.sh ────────────────────────────────────────────────────

# test_qualify_ticket_refs_no_TK_variable
# qualify-ticket-refs.sh must NOT define the TK= variable (v2 pattern).
# NOTE: qualify-ticket-refs.sh has no TK= assignment currently — this test starts GREEN.
echo "Test: test_qualify_ticket_refs_no_TK_variable"
if grep -q '^TK=' "$QUALIFY_TICKET_REFS"; then
    echo "  FAIL: qualify-ticket-refs.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: qualify-ticket-refs.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# test_qualify_ticket_refs_no_tk_call
# qualify-ticket-refs.sh must NOT invoke the bare 'tk' command in functional code (v2 pattern).
# NOTE: qualify-ticket-refs.sh references 'tk ' only in comments and string replacements —
# no functional invocation. This test starts GREEN.
echo "Test: test_qualify_ticket_refs_no_tk_call"
if grep -qE '^[^#]*\btk ' "$QUALIFY_TICKET_REFS"; then
    echo "  FAIL: qualify-ticket-refs.sh still contains functional 'tk ' invocation (v2 pattern)" >&2
    echo "        Expected v2 tk calls to be removed" >&2
    (( FAIL++ ))
else
    echo "  PASS: qualify-ticket-refs.sh does not contain functional 'tk ' invocation"
    (( PASS++ ))
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAIL ($FAIL test(s) failed — expected in RED phase; GREEN after v2 code removal)"
    exit 1
else
    echo "RESULT: PASS (all tests passed — v2 code successfully removed)"
    exit 0
fi
