#!/usr/bin/env bash
# tests/scripts/test-antipattern-chain-regression.sh
#
# Regression test: frozen antipattern-chain fixture set produces >=4 matches
# for the canonical Pattern 3 query signature.
#
# Antipattern query SIGNATURE (embedded constant — do NOT re-derive):
#   A CLAUDE_PLUGIN_ROOT-style variable referenced under set -u
#   WITHOUT a default guard (i.e. ${VAR} with no :- or :? guard).
#   Predicate name: unguarded PLUGIN_ROOT reference (no-default, without :- or :?).
#
# This test is GREEN after task-6 has frozen all four fixture files.
# No original environment is required — the test runs entirely against
# the frozen fixture files in tests/fixtures/antipattern-chain/.
#
# Usage: bash tests/scripts/test-antipattern-chain-regression.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/antipattern-chain"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-antipattern-chain-regression.sh ==="

# ---------------------------------------------------------------------------
# Antipattern query SIGNATURE constant (embedded — not re-derived):
#   Match any line that references ${CLAUDE_PLUGIN_ROOT} (or any PLUGIN_ROOT-
#   style variable) WITHOUT a default guard (no :- or :? operator).
#   This is the unguarded PLUGIN_ROOT reference pattern — no-default, without :-
#   or :? — that triggers "unbound variable" under set -u when CLAUDE_PLUGIN_ROOT
#   is not exported (Pattern 3 chain root cause).
#
# Guard-absence predicate: lines matching the SIGNATURE and NOT containing
#   :- (default-value guard) or :? (error-if-unset guard).
# ---------------------------------------------------------------------------

# SIGNATURE: unguarded PLUGIN_ROOT reference — no-default / without :- or :?
# Matches ${CLAUDE_PLUGIN_ROOT} and any ${..._PLUGIN_ROOT...} style reference.
SIGNATURE_PATTERN='\$\{[A-Z_]*PLUGIN_ROOT[A-Z_]*\}'

# Guard exclusion tokens (fixed-string): lines with these are guarded (safe).
# Unguarded = matches SIGNATURE but does NOT contain :- or :?
GUARD_TOKEN_DEFAULT=':-'
GUARD_TOKEN_ERROR=':?'

# ---------------------------------------------------------------------------
# Test 1: Fixture directory exists and contains exactly 4 fixture files
# ---------------------------------------------------------------------------
echo ""
echo "Test 1: fixture directory exists and contains 4 .sh fixture files"
assert_eq "fixture dir exists" "0" "$([ -d "$FIXTURE_DIR" ] && echo 0 || echo 1)"

fixture_count=$(find "$FIXTURE_DIR" -maxdepth 1 -name '*.sh' | wc -l | tr -d '[:space:]')
assert_eq "fixture count equals 4" "4" "$fixture_count"

# ---------------------------------------------------------------------------
# Test 2: Query the frozen fixtures for unguarded PLUGIN_ROOT references
#         and assert >=4 matches (the threshold for Pattern 3 chain coverage).
# ---------------------------------------------------------------------------
echo ""
echo "Test 2: unguarded PLUGIN_ROOT references (without :- or :?) yield >=4 matches"

# Count total unguarded PLUGIN_ROOT references across all 4 fixture files.
# Strategy: grep for any ${..PLUGIN_ROOT..} reference (ERE), then exclude
# lines that contain the default-guard operators :- or :?.
tmpfile=$(mktemp "${TMPDIR:-/tmp}/antipattern-regression.XXXXXX")
trap 'rm -f "$tmpfile"' EXIT

grep -rE "$SIGNATURE_PATTERN" "$FIXTURE_DIR" \
    | grep -v "$GUARD_TOKEN_DEFAULT" \
    | grep -v "$GUARD_TOKEN_ERROR" \
    > "$tmpfile" 2>/dev/null || true

match_count=$(wc -l < "$tmpfile" | tr -d '[:space:]')

# Assert the >=4 threshold: the 4 frozen fixtures must collectively contain
# at least 4 unguarded PLUGIN_ROOT references (no-default, without :- or :?).
meets_threshold="$([ "${match_count:-0}" -ge 4 ] && echo yes || echo no)"
assert_eq "unguarded PLUGIN_ROOT matches >= 4 (actual: ${match_count:-0})" "yes" "$meets_threshold"

# ---------------------------------------------------------------------------
# Test 3: Each fixture file contributes at least one unguarded PLUGIN_ROOT match
# ---------------------------------------------------------------------------
echo ""
echo "Test 3: every fixture file contributes >=1 unguarded PLUGIN_ROOT reference"

while IFS= read -r -d '' fixture; do
    fixture_name="$(basename "$fixture")"
    unguarded_per_file=$(grep -E "$SIGNATURE_PATTERN" "$fixture" 2>/dev/null \
        | grep -v "$GUARD_TOKEN_DEFAULT" \
        | grep -v "$GUARD_TOKEN_ERROR" \
        | wc -l | tr -d '[:space:]')
    has_match="$([ "${unguarded_per_file:-0}" -ge 1 ] && echo yes || echo no)"
    assert_eq "$fixture_name: has >=1 unguarded PLUGIN_ROOT reference (without :- or :?)" "yes" "$has_match"
done < <(find "$FIXTURE_DIR" -maxdepth 1 -name '*.sh' -print0 | sort -z)

# ---------------------------------------------------------------------------
# Test 4: Guard-presence sanity check — confirm no fixture line uses the
#         ${VAR:-default} shell syntax (guarded reference) for PLUGIN_ROOT.
#         (Comment lines mentioning ":- or :?" are not guarded shell references.)
# ---------------------------------------------------------------------------
echo ""
echo "Test 4: no fixture lines contain a guarded ${PLUGIN_ROOT:-...} shell syntax (sanity)"

# A guarded reference has the form: ${CLAUDE_PLUGIN_ROOT:-...} in actual shell code.
# We detect this by matching the ERE pattern for ${VAR:-anything}.
# This excludes comment lines that merely mention ":-" as text.
GUARDED_SHELL_PATTERN='\$\{[A-Z_]*PLUGIN_ROOT[A-Z_]*:-'
guarded_total=$(grep -rcE "$GUARDED_SHELL_PATTERN" "$FIXTURE_DIR" 2>/dev/null \
    | awk -F: '{sum += $NF} END {print sum+0}')
assert_eq "guarded \${PLUGIN_ROOT:-...} shell references in fixtures = 0 (intentionally unguarded)" \
    "0" "${guarded_total:-0}"

print_summary
