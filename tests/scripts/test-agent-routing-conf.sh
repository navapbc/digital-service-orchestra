#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-agent-routing-conf.sh
# TDD tests for lockpick-workflow/config/agent-routing.conf
#
# Usage: bash lockpick-workflow/tests/scripts/test-agent-routing-conf.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until agent-routing.conf is created.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CONF_FILE="$REPO_ROOT/lockpick-workflow/config/agent-routing.conf"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-agent-routing-conf.sh ==="

# ── test_routing_conf_exists ─────────────────────────────────────────────────
# agent-routing.conf must exist at lockpick-workflow/config/agent-routing.conf
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_routing_conf_exists: file exists" "exists" "$actual_exists"
assert_pass_if_clean "test_routing_conf_exists"

# ── test_routing_conf_format_valid ───────────────────────────────────────────
# Every non-comment, non-empty line must match: ^[a-z_]+=.+|general-purpose$
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    bad_lines=0
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        echo "$line" | grep -qE '^[a-z_]+=.+\|general-purpose$' || (( bad_lines++ ))
    done < "$CONF_FILE"
    if [[ "$bad_lines" -eq 0 ]]; then
        actual_format="valid"
    else
        actual_format="invalid"
    fi
else
    actual_format="invalid"
fi
assert_eq "test_routing_conf_format_valid: all data lines match format" "valid" "$actual_format"
assert_pass_if_clean "test_routing_conf_format_valid"

# ── test_all_expected_categories_present ─────────────────────────────────────
# All 7 categories must be defined.
EXPECTED_CATEGORIES=(test_fix_unit test_fix_e_to_e test_write mechanical_fix complex_debug code_simplify security_audit)
_snapshot_fail
for cat in "${EXPECTED_CATEGORIES[@]}"; do
    if [[ -f "$CONF_FILE" ]] && grep -qE "^${cat}=" "$CONF_FILE"; then
        actual_cat="present"
    else
        actual_cat="missing"
    fi
    assert_eq "test_all_expected_categories_present: category '$cat'" "present" "$actual_cat"
done
assert_pass_if_clean "test_all_expected_categories_present"

# ── test_fallback_sentinel_always_last ───────────────────────────────────────
# Each routing chain must end with general-purpose.
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    sentinel_ok="yes"
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        # Extract the value after the =
        value="${line#*=}"
        # Check last element in pipe-delimited chain
        last="${value##*|}"
        if [[ "$last" != "general-purpose" ]]; then
            sentinel_ok="no"
        fi
    done < "$CONF_FILE"
else
    sentinel_ok="no"
fi
assert_eq "test_fallback_sentinel_always_last: every chain ends with general-purpose" "yes" "$sentinel_ok"
assert_pass_if_clean "test_fallback_sentinel_always_last"

# ── test_header_documents_interface_contract ─────────────────────────────────
# Header must contain key interface contract terms.
_snapshot_fail
if [[ -f "$CONF_FILE" ]]; then
    header=$(head -30 "$CONF_FILE")
else
    header=""
fi
for term in "format" "category" "preference chain" "fallback"; do
    if echo "$header" | grep -qi "$term"; then
        actual_term="present"
    else
        actual_term="missing"
    fi
    assert_eq "test_header_documents_interface_contract: term '$term' in header" "present" "$actual_term"
done
assert_pass_if_clean "test_header_documents_interface_contract"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
