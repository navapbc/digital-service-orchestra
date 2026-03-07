#!/usr/bin/env bash
# test-estimate-context-load.sh
# Tests for lockpick-workflow/scripts/estimate-context-load.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../scripts/estimate-context-load.sh"
FAILURES=0
TESTS=0

pass() { TESTS=$((TESTS + 1)); echo "  PASS: $1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); echo "  FAIL: $1"; }

echo "=== Tests for estimate-context-load.sh ==="

# --- Test: no arguments prints usage and exits 1 ---
if output=$("$SCRIPT" 2>&1); then
    fail "No arguments should exit non-zero"
else
    if echo "$output" | grep -qi "usage"; then
        pass "No arguments prints usage and exits 1"
    else
        fail "No arguments should print usage (got: $output)"
    fi
fi

# --- Test: --help prints usage and exits 0 ---
if output=$("$SCRIPT" --help 2>&1); then
    if echo "$output" | grep -qi "usage"; then
        pass "--help prints usage and exits 0"
    else
        fail "--help should print usage (got: $output)"
    fi
else
    fail "--help should exit 0"
fi

# --- Test: accepts skill name argument ---
if output=$("$SCRIPT" debug-everything 2>&1); then
    if echo "$output" | grep -q "Static Context Load Estimate"; then
        pass "Accepts skill name argument and produces output"
    else
        fail "Expected 'Static Context Load Estimate' header in output"
    fi
else
    fail "Should exit 0 with valid skill name"
fi

# --- Test: skill name appears in output ---
if output=$("$SCRIPT" debug-everything 2>&1); then
    if echo "$output" | grep -q "debug-everything"; then
        pass "Skill name appears in output"
    else
        fail "Skill name should appear in output"
    fi
else
    fail "Should exit 0 with valid skill name"
fi

# --- Test: --window flag overrides default ---
if output=$("$SCRIPT" debug-everything --window=100000 2>&1); then
    if echo "$output" | grep -q "100000"; then
        pass "--window=N overrides context window"
    else
        fail "--window=100000 should appear in output (got: $output)"
    fi
else
    fail "Should exit 0 with --window flag"
fi

# --- Test: --threshold flag overrides default ---
if output=$("$SCRIPT" debug-everything --threshold=5000 2>&1); then
    if echo "$output" | grep -q "5,000\|5000"; then
        pass "--threshold=N overrides warning threshold"
    else
        # Threshold only appears in WARNING/OK message, check logic:
        # If total < 5000, should say "OK: Static load within healthy range (<5,000 tokens)"
        # If total >= 5000, should say "WARNING: Static load >5,000 tokens"
        if echo "$output" | grep -qE "(WARNING|OK).*5.000"; then
            pass "--threshold=N overrides warning threshold"
        else
            fail "--threshold=5000 should affect WARNING/OK message (got: $output)"
        fi
    fi
else
    fail "Should exit 0 with --threshold flag"
fi

# --- Test: --window and --threshold together ---
if output=$("$SCRIPT" debug-everything --window=100000 --threshold=5000 2>&1); then
    if echo "$output" | grep -q "100000"; then
        pass "--window and --threshold work together"
    else
        fail "Combined flags should work (got: $output)"
    fi
else
    fail "Should exit 0 with both flags"
fi

# --- Test: no hardcoded skill names, window, or threshold in script body ---
# (Skip shebang and comments, check the actual code)
if grep -qE 'debug-everything|200000|10000' "$SCRIPT"; then
    fail "Script contains hardcoded values (debug-everything, 200000, or 10000)"
else
    pass "No hardcoded skill names, window size, or threshold in script"
fi

# --- Test: non-existent skill name still runs without error ---
if output=$("$SCRIPT" nonexistent-skill 2>&1); then
    if echo "$output" | grep -q "Static Context Load Estimate"; then
        pass "Non-existent skill name runs without error"
    else
        fail "Should still produce output for non-existent skill"
    fi
else
    fail "Should exit 0 even with non-existent skill name"
fi

# --- Test: non-existent skill shows ~0 tokens for SKILL.md and prompts/ ---
if output=$("$SCRIPT" nonexistent-skill-xyz 2>&1); then
    if echo "$output" | grep -E 'SKILL.md|prompts/' | grep -q '~0 tokens'; then
        pass "Non-existent skill shows ~0 tokens for SKILL.md/prompts/"
    else
        fail "SKILL.md and prompts/ should show ~0 tokens for non-existent skill"
    fi
else
    fail "Should exit 0 for non-existent skill ~0 token check"
fi

# --- Test: non-existent skill produces no stderr ---
if stderr=$("$SCRIPT" nonexistent-skill-xyz 2>&1 1>/dev/null); then
    # Note: redirect order means stdout goes to /dev/null first, then stderr merges.
    # We need a subshell approach to properly capture stderr only.
    true
fi
stderr_lines=$({ "$SCRIPT" nonexistent-skill-xyz 1>/dev/null; } 2>&1 | wc -l | tr -d ' ')
if [[ "$stderr_lines" = "0" ]]; then
    pass "Non-existent skill produces no stderr output"
else
    fail "Non-existent skill should produce no stderr (got $stderr_lines lines)"
fi

# --- Test: output contains expected sections ---
if output=$("$SCRIPT" debug-everything 2>&1); then
    ok=true
    for section in "CLAUDE.md:" "MEMORY.md:" "SKILL.md" "prompts/" "Static total:" "Context window:" "Pre-conversation static load:"; do
        if ! echo "$output" | grep -q "$section"; then
            fail "Missing expected section: $section"
            ok=false
            break
        fi
    done
    if $ok; then
        pass "Output contains all expected sections"
    fi
else
    fail "Should exit 0 for output section check"
fi

echo ""
echo "=== Results: $((TESTS - FAILURES))/$TESTS passed ==="
if (( FAILURES > 0 )); then
    echo "FAILED: $FAILURES test(s) failed"
    exit 1
else
    echo "All tests passed."
    exit 0
fi
