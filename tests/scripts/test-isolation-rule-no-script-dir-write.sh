#!/usr/bin/env bash
# tests/scripts/test-isolation-rule-no-script-dir-write.sh
# Tests for scripts/test-isolation-rules/no-script-dir-write.sh
#
# Verifies:
#   1. Direct $SCRIPT_DIR writes are detected (output contains violation)
#   2. Variable aliases derived from $SCRIPT_DIR (e.g. FIXTURES_DIR="$SCRIPT_DIR/x")
#      are also detected when used as write targets (the core bug being fixed)
#   3. Good files (reads only, writes to /tmp) pass without violations
#
# Note: the rule exits 0 always; violations are reported via stdout.
# The harness (check-test-isolation.sh) interprets stdout and returns non-zero.
#
# Usage: bash tests/scripts/test-isolation-rule-no-script-dir-write.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
RULE="$DSO_PLUGIN_DIR/scripts/test-isolation-rules/no-script-dir-write.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-isolation-rule-no-script-dir-write.sh ==="

# ── test_rule_exists_and_executable ──────────────────────────────────────────
_snapshot_fail
rule_exec=0
[ -x "$RULE" ] && rule_exec=1
assert_eq "test_rule_exists_and_executable" "1" "$rule_exec"
assert_pass_if_clean "test_rule_exists_and_executable"

# ── test_direct_script_dir_write_detected ────────────────────────────────────
# A file that writes directly to $SCRIPT_DIR should trigger violations (output non-empty)
_snapshot_fail
TMPDIR_TEST=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST'" EXIT

cat > "$TMPDIR_TEST/test-direct-write.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "data" > "$SCRIPT_DIR/result.txt"
EOF

output=$("$RULE" "$TMPDIR_TEST/test-direct-write.sh" 2>/dev/null)
assert_contains "test_direct_script_dir_write_detected: has rule name" "no-script-dir-write" "$output"
assert_pass_if_clean "test_direct_script_dir_write_detected"

# ── test_alias_write_detected ─────────────────────────────────────────────────
# A file that assigns FIXTURES_DIR="$SCRIPT_DIR/fixtures" and then writes to
# $FIXTURES_DIR should also be detected (the core bug being fixed).
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/test-bad-script-dir-alias-write.sh" 2>/dev/null)
assert_contains "test_alias_write_detected: has rule name" "no-script-dir-write" "$output"
assert_pass_if_clean "test_alias_write_detected"

# ── test_alias_read_not_flagged ───────────────────────────────────────────────
# A file that reads from a SCRIPT_DIR alias but writes to /tmp should pass (no output)
_snapshot_fail
output=$("$RULE" "$FIXTURES_DIR/test-good-script-dir-alias-read.sh" 2>/dev/null)
assert_eq "test_alias_read_not_flagged: no violations" "" "$output"
assert_pass_if_clean "test_alias_read_not_flagged"

# ── test_redirect_to_alias_detected ──────────────────────────────────────────
# Redirect (>>) to a variable derived from SCRIPT_DIR should be detected
_snapshot_fail
TMPDIR_TEST2=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST2'" EXIT

cat > "$TMPDIR_TEST2/test-alias-redirect.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
echo "log entry" >> "$OUTPUT_DIR/run.log"
EOF

output=$("$RULE" "$TMPDIR_TEST2/test-alias-redirect.sh" 2>/dev/null)
assert_contains "test_redirect_to_alias_detected: has rule name" "no-script-dir-write" "$output"
assert_pass_if_clean "test_redirect_to_alias_detected"

# ── test_touch_to_alias_detected ─────────────────────────────────────────────
# touch to a path derived from SCRIPT_DIR should be detected
_snapshot_fail
TMPDIR_TEST3=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST3'" EXIT

cat > "$TMPDIR_TEST3/test-alias-touch.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENTINEL_DIR="$SCRIPT_DIR/sentinels"
touch "$SENTINEL_DIR/done"
EOF

output=$("$RULE" "$TMPDIR_TEST3/test-alias-touch.sh" 2>/dev/null)
assert_contains "test_touch_to_alias_detected: has rule name" "no-script-dir-write" "$output"
assert_pass_if_clean "test_touch_to_alias_detected"

# ── test_isolation_ok_suppresses_alias ────────────────────────────────────────
# Lines with # isolation-ok: should suppress alias-write violations too
_snapshot_fail
TMPDIR_TEST4=$(mktemp -d)
trap "rm -rf '$TMPDIR_TEST4'" EXIT

cat > "$TMPDIR_TEST4/test-alias-suppressed.sh" << 'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
echo "data" > "$FIXTURES_DIR/result.txt" # isolation-ok: updating test fixture intentionally
EOF

output=$("$RULE" "$TMPDIR_TEST4/test-alias-suppressed.sh" 2>/dev/null)
assert_eq "test_isolation_ok_suppresses_alias: no violations" "" "$output"
assert_pass_if_clean "test_isolation_ok_suppresses_alias"

# ── test_integration_with_harness ─────────────────────────────────────────────
# Verify alias-write violation is caught when invoked via the harness
_snapshot_fail
harness="$DSO_PLUGIN_DIR/scripts/check-test-isolation.sh"
if [ -x "$harness" ]; then
    harness_output=$(bash "$harness" "$FIXTURES_DIR/test-bad-script-dir-alias-write.sh" 2>/dev/null)
    harness_exit=$?
    assert_eq "test_integration_with_harness: exit 1 for bad file" "1" "$harness_exit"
    assert_contains "test_integration_with_harness: harness finds violations" "no-script-dir-write" "$harness_output"
else
    echo "SKIP: test_integration_with_harness (harness not found)"
fi
assert_pass_if_clean "test_integration_with_harness"

print_summary
