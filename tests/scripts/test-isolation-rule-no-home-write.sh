#!/usr/bin/env bash
# tests/scripts/test-isolation-rule-no-home-write.sh
# Tests for scripts/test-isolation-rules/no-home-write.sh
#
# Usage: bash tests/scripts/test-isolation-rule-no-home-write.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
RULE="$DSO_PLUGIN_DIR/scripts/test-isolation-rules/no-home-write.sh"
FIXTURES="$SCRIPT_DIR/fixtures/isolation-rules"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-isolation-rule-no-home-write.sh ==="

# ── test_no_home_write_catches_dollar_home ───────────────────────────────────
# The bad fixture writes to $HOME without temp override
_snapshot_fail
output=$("$RULE" "$FIXTURES/bad-home-write.sh" 2>/dev/null)
exit_code=$?
assert_eq "test_catches_dollar_home: exits non-zero for HOME writes" "1" "$exit_code"
assert_contains "test_catches_dollar_home: catches > \$HOME" "no-home-write" "$output"
assert_contains "test_catches_dollar_home: reports line number" ":6:" "$output"
assert_pass_if_clean "test_no_home_write_catches_dollar_home"

# ── test_no_home_write_catches_tilde ─────────────────────────────────────────
# The bad fixture also has ~/path writes
_snapshot_fail
assert_contains "test_catches_tilde: catches cp to ~/" ":8:" "$output"
assert_contains "test_catches_tilde: catches > ~/" ":10:" "$output"
assert_pass_if_clean "test_no_home_write_catches_tilde"

# ── test_no_home_write_passes_temp_override ──────────────────────────────────
# The good fixture overrides HOME with mktemp before using it
_snapshot_fail
output=$("$RULE" "$FIXTURES/good-home-write.sh" 2>/dev/null)
exit_code=$?
assert_eq "test_passes_temp_override: exits zero when HOME is overridden" "0" "$exit_code"
assert_eq "test_passes_temp_override: no violations output" "" "$output"
assert_pass_if_clean "test_no_home_write_passes_temp_override"

# ── test_no_home_write_respects_suppression ──────────────────────────────────
# Create a temp fixture with suppression comment
_snapshot_fail
TMPFILE=$(mktemp /tmp/test-home-write-XXXXXX.sh)
trap 'rm -f "$TMPFILE"' EXIT
cat > "$TMPFILE" << 'FIXTURE'
#!/usr/bin/env bash
echo "data" > $HOME/.config  # isolation-ok: intentional
FIXTURE
output=$("$RULE" "$TMPFILE" 2>/dev/null)
exit_code=$?
assert_eq "test_respects_suppression: exits zero with suppression" "0" "$exit_code"
assert_eq "test_respects_suppression: no violations with suppression" "" "$output"
assert_pass_if_clean "test_no_home_write_respects_suppression"

# ── test_no_home_write_structured_output_format ──────────────────────────────
# Verify the output format is file:line:rule-name:message
_snapshot_fail
output=$("$RULE" "$FIXTURES/bad-home-write.sh" 2>/dev/null)
first_line=$(echo "$output" | head -1)
# Should have 4 colon-separated fields
field_count=$(echo "$first_line" | awk -F: '{print NF}')
# At least 4 fields (file path may contain colons on some systems)
if [[ "$field_count" -ge 4 ]]; then
    (( PASS++ ))
else
    (( FAIL++ ))
    echo "FAIL: test_structured_output_format: expected 4+ fields, got $field_count" >&2
    echo "  line: $first_line" >&2
fi
assert_pass_if_clean "test_no_home_write_structured_output_format"

print_summary
