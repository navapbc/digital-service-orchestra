#!/usr/bin/env bash
# tests/scripts/test-retro-gather.sh
# Baseline tests for scripts/retro-gather.sh
#
# Usage: bash tests/scripts/test-retro-gather.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/retro-gather.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-retro-gather.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ─────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 3: Script requires git repo ─────────────────────────────────────────
echo "Test 3: Script exits non-zero when not in a git repo"
exit_code=0
TMP_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$TMP_DIR")
( cd "$TMP_DIR" && bash "$SCRIPT" 2>/dev/null ) || exit_code=$?
rmdir "$TMP_DIR" 2>/dev/null || true
if [ "$exit_code" -ne 0 ]; then
    echo "  PASS: exits non-zero outside git repo (exit $exit_code)"
    (( PASS++ ))
else
    echo "  FAIL: expected non-zero exit outside git repo" >&2
    (( FAIL++ ))
fi

# ── Test 4: Output contains === section headers ───────────────────────────────
# retro-gather.sh calls validate.sh which can hang waiting for CI.
# Use a background process with a kill-timer to prevent infinite hangs.
echo "Test 4: Output contains === section headers"
_OUTFILE=$(mktemp)
_CLEANUP_DIRS+=("$_OUTFILE")
# RETRO_SKIP_VALIDATION=1 prevents validate.sh from spawning orphan subprocesses
# that hold the Bash tool open past the ~73s ceiling (exit 144).
RETRO_SKIP_VALIDATION=1 bash "$SCRIPT" --quick >"$_OUTFILE" 2>&1 &
_PID=$!
# Timeout is injectable via RETRO_GATHER_TEST_TIMEOUT (default: 2s).
# RETRO_SKIP_VALIDATION=1 makes this fast; section headers appear within 1s.
_TIMEOUT="${RETRO_GATHER_TEST_TIMEOUT:-2}"
( sleep "$_TIMEOUT" && kill "$_PID" 2>/dev/null ) &
_TIMER=$!
wait "$_PID" 2>/dev/null || true
kill "$_TIMER" 2>/dev/null; wait "$_TIMER" 2>/dev/null || true
output=$(cat "$_OUTFILE")
rm -f "$_OUTFILE"
if [[ "$output" =~ ===\ [A-Z] ]]; then
    echo "  PASS: output contains section headers"
    (( PASS++ ))
else
    echo "  FAIL: output missing section headers" >&2
    (( FAIL++ ))
fi

# ── Test 5: --quick flag produces CLEANUP section ────────────────────────────
echo "Test 5: --quick flag produces CLEANUP section"
# Reuse output from Test 4 to avoid running the script twice
if [[ "$output" =~ CLEANUP|VALIDATION ]]; then
    echo "  PASS: --quick output contains CLEANUP and/or VALIDATION section"
    (( PASS++ ))
else
    echo "  FAIL: --quick output missing CLEANUP/VALIDATION sections" >&2
    (( FAIL++ ))
fi

# ── Test 6: Script uses section() function for structured output ──────────────
echo "Test 6: Script uses section() function for structured output"
_section_found=0; grep -q "section()" "$SCRIPT" && _section_found=1; [[ "$_section_found" -eq 0 ]] && grep -q "^section " "$SCRIPT" && _section_found=1; if [[ "$_section_found" -eq 1 ]]; then
    echo "  PASS: script uses section() function"
    (( PASS++ ))
else
    echo "  FAIL: script does not use section() function" >&2
    (( FAIL++ ))
fi

# ── Test 7: RETRO_SKIP_VALIDATION=1 skips validate.sh ────────────────────────
# When RETRO_SKIP_VALIDATION=1 is set, retro-gather.sh must emit
# VALIDATION section with "skipped" text instead of running validate.sh.
# Uses a mock CLAUDE_PLUGIN_ROOT with a no-op validate.sh to avoid orphan
# process issues from the real validate.sh spawning test-batched subprocesses.
echo "Test 7: RETRO_SKIP_VALIDATION=1 emits VALIDATION section as skipped"
_skip_val_tmpdir=$(mktemp -d)
_CLEANUP_DIRS+=("$_skip_val_tmpdir")
( cd "$_skip_val_tmpdir" && git init -q -b main && git config user.email "t@t.com" && git config user.name "T" && touch f && git add . && git commit -q -m "init" ) 2>/dev/null
# Create a mock CLAUDE_PLUGIN_ROOT with a fast no-op validate.sh.
# plugin.json must exist so retro-gather.sh does not discard CLAUDE_PLUGIN_ROOT.
_mock_plugin_root="$_skip_val_tmpdir/mock_plugin"
mkdir -p "$_mock_plugin_root/scripts"
echo '{"name":"mock"}' > "$_mock_plugin_root/plugin.json"
cat > "$_mock_plugin_root/scripts/validate.sh" << 'MOCKEOF'
#!/usr/bin/env bash
echo "MOCK VALIDATE CALLED"
exit 0
MOCKEOF
chmod +x "$_mock_plugin_root/scripts/validate.sh"
# Use no-op stubs for all helper scripts to keep Test 7 fast and isolated.
# Do NOT copy real scripts — they may be slow or spawn subprocesses.
printf '#!/usr/bin/env bash\nexit 0\n' > "$_mock_plugin_root/scripts/validate-issues.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_mock_plugin_root/scripts/cleanup-claude-session.sh"
chmod +x "$_mock_plugin_root/scripts/"* 2>/dev/null || true
_skip_val_outfile=$(mktemp)
_CLEANUP_DIRS+=("$_skip_val_outfile")
PROJECT_ROOT="$_skip_val_tmpdir" \
    TRACKER_DIR="$_skip_val_tmpdir/.tickets-tracker" \
    CLAUDE_PLUGIN_ROOT="$_mock_plugin_root" \
    CI_STATUS=pending \
    RETRO_SKIP_VALIDATION=1 \
    bash "$SCRIPT" --quick >"$_skip_val_outfile" 2>&1 &
_skip_pid=$!
( sleep "${RETRO_GATHER_TEST_TIMEOUT:-2}" && kill "$_skip_pid" 2>/dev/null ) &
_skip_timer=$!
wait "$_skip_pid" 2>/dev/null || true
kill "$_skip_timer" 2>/dev/null; wait "$_skip_timer" 2>/dev/null || true
_skip_val_out=$(cat "$_skip_val_outfile")
rm -f "$_skip_val_outfile"
rm -rf "$_skip_val_tmpdir"
if [[ "${_skip_val_out,,}" == *"validation"*"skipped"* ]]; then
    echo "  PASS: VALIDATION section says 'skipped' (validate.sh not called)"
    (( PASS++ ))
else
    echo "  FAIL: VALIDATION section did not say 'skipped' — validate.sh still runs" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
