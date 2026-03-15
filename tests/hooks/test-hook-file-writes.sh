#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-hook-file-writes.sh
# Tests for check-hook-file-writes.py — AST-based static analysis of hook file writes.
#
# Validates:
#   1. The checker passes on the real hook directory (no false positives)
#   2. The checker detects violations in synthetic test fixtures
#   3. The --check flag works for single-file scanning
#   4. The # write-ok suppression annotation works
#   5. Performance: completes within 2 seconds
#
# Usage: bash lockpick-workflow/tests/hooks/test-hook-file-writes.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$REPO_ROOT/lockpick-workflow/scripts/check-hook-file-writes.py"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== Test: check-hook-file-writes.py ==="

# --- Test 1: Checker script exists and is runnable ---
echo ""
echo "--- Test 1: Script exists and runs ---"
assert_eq "checker exists" "true" "$(test -f "$CHECKER" && echo true || echo false)"

OUTPUT=$(python3 "$CHECKER" --hook-dir "$REPO_ROOT/lockpick-workflow/hooks" 2>&1)
EXIT_CODE=$?
assert_eq "checker passes on real hooks" "0" "$EXIT_CODE"
assert_contains "checker reports OK" "OK: no disallowed writes" "$OUTPUT"

# --- Test 2: Detects a disallowed redirect (> to repo path) ---
echo ""
echo "--- Test 2: Detects disallowed redirect ---"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

cat > "$TMPDIR_TEST/bad-redirect.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "hello" > "$REPO_ROOT/some-config.txt"
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/bad-redirect.sh" 2>&1)
EXIT_CODE=$?
assert_eq "detects bad redirect" "1" "$EXIT_CODE"
assert_contains "reports FAIL" "FAIL" "$OUTPUT"
assert_contains "shows target" "REPO_ROOT" "$OUTPUT"

# --- Test 3: Detects disallowed write command (cp to repo path) ---
echo ""
echo "--- Test 3: Detects disallowed write command ---"
cat > "$TMPDIR_TEST/bad-cp.sh" <<'FIXTURE'
#!/usr/bin/env bash
cp /tmp/source.txt "$HOME/Documents/dest.txt"
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/bad-cp.sh" 2>&1)
EXIT_CODE=$?
assert_eq "detects bad cp" "1" "$EXIT_CODE"

# --- Test 4: Allows writes to ARTIFACTS_DIR ---
echo ""
echo "--- Test 4: Allows writes to ARTIFACTS_DIR ---"
cat > "$TMPDIR_TEST/good-artifacts.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "data" > "$ARTIFACTS_DIR/state.txt"
mkdir -p "$ARTIFACTS_DIR/subdir"
echo "log" >> "$_HOOK_TIMING_LOG"
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/good-artifacts.sh" 2>&1)
EXIT_CODE=$?
assert_eq "allows artifacts writes" "0" "$EXIT_CODE"

# --- Test 5: Allows writes to /tmp/ ---
echo ""
echo "--- Test 5: Allows writes to /tmp/ ---"
cat > "$TMPDIR_TEST/good-tmp.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "data" > /tmp/some-file.txt
mkdir -p /tmp/workflow-plugin-abc123
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/good-tmp.sh" 2>&1)
EXIT_CODE=$?
assert_eq "allows /tmp/ writes" "0" "$EXIT_CODE"

# --- Test 6: Allows writes to /dev/null ---
echo ""
echo "--- Test 6: Allows /dev/null ---"
cat > "$TMPDIR_TEST/good-devnull.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "discard" > /dev/null
some_cmd 2>/dev/null
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/good-devnull.sh" 2>&1)
EXIT_CODE=$?
assert_eq "allows /dev/null" "0" "$EXIT_CODE"

# --- Test 7: write-ok suppression works ---
echo ""
echo "--- Test 7: Suppression annotation ---"
cat > "$TMPDIR_TEST/suppressed.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "data" > "$SOME_UNKNOWN_VAR/file.txt" # write-ok
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/suppressed.sh" 2>&1)
EXIT_CODE=$?
assert_eq "write-ok suppresses violation" "0" "$EXIT_CODE"

# --- Test 8: JSON output mode ---
echo ""
echo "--- Test 8: JSON output ---"
OUTPUT=$(python3 "$CHECKER" --json --hook-dir "$REPO_ROOT/lockpick-workflow/hooks" 2>&1)
EXIT_CODE=$?
assert_eq "json mode exits 0" "0" "$EXIT_CODE"
assert_contains "json has ok field" '"ok": true' "$OUTPUT"
assert_contains "json has stats" '"violations": 0' "$OUTPUT"

# --- Test 9: Performance (under 2 seconds) ---
echo ""
echo "--- Test 9: Performance ---"
START_TIME=$(date +%s)
python3 "$CHECKER" --hook-dir "$REPO_ROOT/lockpick-workflow/hooks" > /dev/null 2>&1
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))
if [[ "$ELAPSED" -le 2 ]]; then
    assert_eq "performance: completes within 2s" "true" "true"
else
    assert_eq "performance: completes within 2s (took ${ELAPSED}s)" "true" "false"
fi

# --- Test 10: Detects tee to disallowed path ---
echo ""
echo "--- Test 10: Detects disallowed tee ---"
cat > "$TMPDIR_TEST/bad-tee.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "data" | tee /var/log/output.log
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/bad-tee.sh" 2>&1)
EXIT_CODE=$?
assert_eq "detects bad tee" "1" "$EXIT_CODE"

# --- Test 11: Comments and blank lines are skipped ---
echo ""
echo "--- Test 11: Skips comments/blanks ---"
cat > "$TMPDIR_TEST/comments-only.sh" <<'FIXTURE'
#!/usr/bin/env bash
# This is a comment with > redirect syntax
# echo "bad" > /etc/passwd

FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/comments-only.sh" 2>&1)
EXIT_CODE=$?
assert_eq "skips comments" "0" "$EXIT_CODE"

# --- Test 12: Compound path with allowed variable ---
echo ""
echo "--- Test 12: Compound path with allowed variable ---"
cat > "$TMPDIR_TEST/compound-path.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo "data" > "$REPO_ROOT/$CHECKPOINT_MARKER_FILE"
FIXTURE

OUTPUT=$(python3 "$CHECKER" --check "$TMPDIR_TEST/compound-path.sh" 2>&1)
EXIT_CODE=$?
assert_eq "compound path with allowed var" "0" "$EXIT_CODE"

print_summary
