#!/usr/bin/env bash
# tests/scripts/test-validate-phase-v2-removal.sh
# RED tests: assert no v2 code in validate-phase.sh and agent-batch-lifecycle.sh.
#
# TDD RED phase (bff3-b98e): all tests FAIL until the GREEN story (1a0b-3955)
# removes v2 code (TK= variable, tk ready/blocked calls, find TICKETS_DIR scan)
# from validate-phase.sh and agent-batch-lifecycle.sh.
#
# These tests assert that v2 code is ABSENT. They currently FAIL because v2
# code IS present. After story 1a0b-3955 removes the v2 code, they will pass.
#
# Usage: bash tests/scripts/test-validate-phase-v2-removal.sh
# Returns: exit 1 in RED state (v2 code present), exit 0 in GREEN state (v2 removed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
VALIDATE_PHASE="$DSO_PLUGIN_DIR/scripts/validate-phase.sh"
AGENT_BATCH="$DSO_PLUGIN_DIR/scripts/agent-batch-lifecycle.sh"

PASS=0
FAIL=0

echo "=== test-validate-phase-v2-removal.sh ==="
echo ""

# ── test_validate_phase_no_TK_variable ───────────────────────────────────────
# validate-phase.sh must NOT define the TK= variable (v2 pattern).
# RED: FAIL because validate-phase.sh still has 'TK="${TK:-$SCRIPT_DIR/tk}"' on line 23.
echo "Test: test_validate_phase_no_TK_variable"
if grep -q '^TK=' "$VALIDATE_PHASE"; then
    echo "  FAIL: validate-phase.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed (story 1a0b-3955)" >&2
    (( FAIL++ ))
else
    echo "  PASS: validate-phase.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# ── test_validate_phase_no_tk_ready_call ─────────────────────────────────────
# validate-phase.sh must NOT call '"$TK" ready' (v2 pattern).
# RED: FAIL because validate-phase.sh still calls "$TK" ready on line ~345.
echo "Test: test_validate_phase_no_tk_ready_call"
if grep -q '"$TK" ready' "$VALIDATE_PHASE"; then
    echo '  FAIL: validate-phase.sh still contains '"'"'"$TK" ready'"'"' call (v2 pattern)' >&2
    echo "        Expected v2 tk ready call to be removed (story 1a0b-3955)" >&2
    (( FAIL++ ))
else
    echo '  PASS: validate-phase.sh does not contain '"'"'"$TK" ready'"'"' call'
    (( PASS++ ))
fi
echo ""

# ── test_validate_phase_no_tk_blocked_call ───────────────────────────────────
# validate-phase.sh must NOT call '"$TK" blocked' (v2 pattern).
# RED: FAIL because validate-phase.sh still calls "$TK" blocked on line ~345.
echo "Test: test_validate_phase_no_tk_blocked_call"
if grep -q '"$TK" blocked' "$VALIDATE_PHASE"; then
    echo '  FAIL: validate-phase.sh still contains '"'"'"$TK" blocked'"'"' call (v2 pattern)' >&2
    echo "        Expected v2 tk blocked call to be removed (story 1a0b-3955)" >&2
    (( FAIL++ ))
else
    echo '  PASS: validate-phase.sh does not contain '"'"'"$TK" blocked'"'"' call'
    (( PASS++ ))
fi
echo ""

# ── test_agent_batch_no_TK_variable ──────────────────────────────────────────
# agent-batch-lifecycle.sh must NOT define the TK= variable (v2 pattern).
# RED: FAIL because agent-batch-lifecycle.sh still has 'TK="${TK:-$SCRIPT_DIR/tk}"' on line 28.
echo "Test: test_agent_batch_no_TK_variable"
if grep -q '^TK=' "$AGENT_BATCH"; then
    echo "  FAIL: agent-batch-lifecycle.sh still contains 'TK=' assignment (v2 pattern)" >&2
    echo "        Expected v2 TK variable to be removed (story 1a0b-3955)" >&2
    (( FAIL++ ))
else
    echo "  PASS: agent-batch-lifecycle.sh does not contain 'TK=' assignment"
    (( PASS++ ))
fi
echo ""

# ── test_agent_batch_no_TICKETS_DIR_scan ─────────────────────────────────────
# agent-batch-lifecycle.sh must NOT scan the filesystem via 'find "$TICKETS_DIR"'
# (v2 pattern that reads raw markdown files instead of using the ticket CLI).
# RED: FAIL because agent-batch-lifecycle.sh still uses find TICKETS_DIR on lines 269/352.
echo "Test: test_agent_batch_no_TICKETS_DIR_scan"
if grep -q 'find "\$TICKETS_DIR"' "$AGENT_BATCH"; then
    echo "  FAIL: agent-batch-lifecycle.sh still contains 'find \"\$TICKETS_DIR\"' scan (v2 pattern)" >&2
    echo "        Expected v2 filesystem scan to be removed (story 1a0b-3955)" >&2
    (( FAIL++ ))
else
    echo "  PASS: agent-batch-lifecycle.sh does not contain 'find \"\$TICKETS_DIR\"' scan"
    (( PASS++ ))
fi
echo ""

# ── test_agent_batch_lock_acquire_uses_ticket_cli ────────────────────────────
# After story 1a0b-3955, agent-batch-lifecycle.sh MUST use 'ticket create' for
# lock acquisition (v3 ticket CLI pattern), not raw filesystem scanning.
# RED: FAIL because lock-acquire currently uses find "$TICKETS_DIR" instead of
#      ticket CLI calls. When v2 code is removed, 'ticket create' will be used.
echo "Test: test_agent_batch_lock_acquire_uses_ticket_cli"
if grep -q 'ticket create' "$AGENT_BATCH"; then
    echo "  PASS: agent-batch-lifecycle.sh uses 'ticket create' (v3 CLI pattern)"
    (( PASS++ ))
else
    echo "  FAIL: agent-batch-lifecycle.sh does not yet call 'ticket create' for lock acquisition" >&2
    echo "        Expected v3 ticket CLI call to be present (story 1a0b-3955)" >&2
    (( FAIL++ ))
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "RESULT: FAIL ($FAIL test(s) failed — expected in RED phase; GREEN after story 1a0b-3955)"
    exit 1
else
    echo "RESULT: PASS (all tests passed — v2 code successfully removed)"
    exit 0
fi
