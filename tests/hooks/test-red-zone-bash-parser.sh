#!/usr/bin/env bash
# tests/hooks/test-red-zone-bash-parser.sh
# RED test for bug 091a-368f: parse_failing_tests_from_output extracts
# partial words from assert_eq multi-word labels instead of function names.
#
# Validates that the parser correctly handles bash test output formats:
# - "FAIL: multi word label" should NOT extract "multi" as a test name
# - "FAIL: test_function_name" (single identifier) SHOULD be extracted
# - "test_name ... FAIL" should be extracted
# - "test_name: FAIL" should be extracted

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/plugins/dso/hooks/lib/red-zone.sh"

echo "=== test-red-zone-bash-parser.sh ==="

PASSED=0
FAILED=0

# ── Test 1: Multi-word FAIL label should NOT produce partial word extraction ──
echo "Test 1: FAIL: multi-word label does not extract partial first word"
test_multiword_fail_no_partial() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << 'EOF'
=== test-ticket-create.sh ===
Test 15 (RED): ticket create --tags writes tags
FAIL: ticket ID returned for --tags test
  expected: non-empty
  actual:   empty
PASSED: 25  FAILED: 1
EOF

    local result
    result=$(parse_failing_tests_from_output "$tmp")
    rm -f "$tmp"

    # "ticket" should NOT appear as an extracted test name
    if echo "$result" | grep -qx "ticket"; then
        echo "  FAIL: extracted 'ticket' from multi-word label"
        FAILED=$((FAILED + 1))
    else
        echo "  PASS: did not extract partial word from multi-word label"
        PASSED=$((PASSED + 1))
    fi
}
test_multiword_fail_no_partial

# ── Test 2: Single-identifier FAIL line SHOULD be extracted ──────────────────
echo "Test 2: FAIL: test_function_name (single identifier) is extracted"
test_single_identifier_extracted() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << 'EOF'
FAIL: test_tags_flag_creates_ticket_with_tags
PASSED: 25  FAILED: 1
EOF

    local result
    result=$(parse_failing_tests_from_output "$tmp")
    rm -f "$tmp"

    if echo "$result" | grep -qx "test_tags_flag_creates_ticket_with_tags"; then
        echo "  PASS: extracted single-identifier function name"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: did not extract 'test_tags_flag_creates_ticket_with_tags' (got: '$result')"
        FAILED=$((FAILED + 1))
    fi
}
test_single_identifier_extracted

# ── Test 3: Mixed output — only function names extracted, not label words ────
echo "Test 3: Mixed output extracts only function names, not label words"
test_mixed_output() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << 'EOF'
=== test-ticket-create.sh ===
FAIL: ticket ID returned for --tags test
  expected: non-empty
  actual:   empty
FAIL: test_tags_flag_creates_ticket_with_tags
test_other_thing: FAIL
PASSED: 25  FAILED: 2
EOF

    local result
    result=$(parse_failing_tests_from_output "$tmp")
    rm -f "$tmp"

    local has_function_name=false
    local has_partial_word=false

    if echo "$result" | grep -qx "test_tags_flag_creates_ticket_with_tags"; then
        has_function_name=true
    fi
    if echo "$result" | grep -qx "test_other_thing"; then
        has_function_name=true
    fi
    if echo "$result" | grep -qx "ticket"; then
        has_partial_word=true
    fi

    if [ "$has_function_name" = true ] && [ "$has_partial_word" = false ]; then
        echo "  PASS: extracted function names only"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: function=$has_function_name, partial=$has_partial_word (output: '$result')"
        FAILED=$((FAILED + 1))
    fi
}
test_mixed_output

# ── Test 4: Indented FAIL line with single identifier is extracted ───────────
echo "Test 4: Indented FAIL: test_name is extracted"
test_indented_fail() {
    local tmp
    tmp=$(mktemp)
    cat > "$tmp" << 'EOF'
  FAIL: test_indented_function
PASSED: 0  FAILED: 1
EOF

    local result
    result=$(parse_failing_tests_from_output "$tmp")
    rm -f "$tmp"

    if echo "$result" | grep -qx "test_indented_function"; then
        echo "  PASS: extracted indented single-identifier"
        PASSED=$((PASSED + 1))
    else
        echo "  FAIL: did not extract indented function name (got: '$result')"
        FAILED=$((FAILED + 1))
    fi
}
test_indented_fail

echo ""
printf "PASSED: %d  FAILED: %d\n" "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
