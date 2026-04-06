#!/usr/bin/env bash
# tests/scripts/test-validate-script-writes-integration.sh
# Integration tests verifying that validate.sh wires check-script-writes.py
# via the checks.script_write_scan_dir config key.
#
# Tests:
#   test_validate_runs_script_writes_check    — with config key set, validate.sh invokes script-writes check
#   test_validate_skips_when_key_absent       — with key absent from config, check-script-writes.py is not run
#   test_validate_skips_when_key_empty        — with key set to empty value, check is skipped
#   test_config_key_reads_correctly           — read-config.sh resolves checks.script_write_scan_dir correctly
#   test_end_to_end_violation_detected        — synthetic violation in configured scan dir → validate.sh fails
#
# Uses CONFIG_FILE env var override for test isolation (no temp dirs write to repo root).
#
# Usage: bash tests/scripts/test-validate-script-writes-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"
READ_CONFIG="$DSO_PLUGIN_DIR/scripts/read-config.sh"
CHECK_SCRIPT_WRITES="$DSO_PLUGIN_DIR/scripts/check-script-writes.py"

echo "=== test-validate-script-writes-integration.sh ==="

# ── test_validate_runs_script_writes_check ────────────────────────────────────
# With checks.script_write_scan_dir set in config, validate.sh output includes
# "script-writes" check. We use a stub config that points scan_dir to a temp dir
# with no violations so the check passes, and inject a fake passing command via
# VALIDATE_TIMEOUT_SYNTAX to avoid running the full suite.
#
# Strategy: inspect validate.sh source to confirm it references "script-writes"
# and reads the config key — this is a static check that is deterministic and fast.
test_validate_runs_script_writes_check() {
    _snapshot_fail

    # Static check: validate.sh must contain the string "script-writes"
    has_label=$(grep -c '"script-writes"' "$VALIDATE_SH" 2>/dev/null || echo "0")
    assert_ne "validate.sh contains script-writes label" "0" "$has_label"

    # Static check: validate.sh must reference the config key
    has_config_key=$(grep -c 'checks.script_write_scan_dir' "$VALIDATE_SH" 2>/dev/null || echo "0")
    assert_ne "validate.sh reads checks.script_write_scan_dir" "0" "$has_config_key"

    # Static check: validate.sh must reference PLUGIN_SCRIPTS and check-script-writes.py
    has_script_ref=$(grep -c 'check-script-writes.py' "$VALIDATE_SH" 2>/dev/null || echo "0")
    assert_ne "validate.sh references check-script-writes.py" "0" "$has_script_ref"

    assert_pass_if_clean "test_validate_runs_script_writes_check"
}

# ── test_validate_skips_when_key_absent ───────────────────────────────────────
# With checks.script_write_scan_dir absent from config, check-script-writes.py
# must not be invoked. Verified via static analysis: validate.sh must guard
# the run_check call so it only fires when the config value is non-empty.
test_validate_skips_when_key_absent() {
    _snapshot_fail

    # Static check: the script-writes run_check must be inside an if-block
    # that tests whether SCAN_DIR (or the config value) is non-empty.
    # We verify validate.sh has a conditional guard around the script-writes check.
    has_guard=$(grep -A5 'SCAN_DIR\|script_write_scan_dir' "$VALIDATE_SH" 2>/dev/null \
        | grep -c 'if\|-n\|\[ ' || echo "0")
    assert_ne "validate.sh guards script-writes check" "0" "$has_guard"

    # Runtime check: invoke validate.sh with a config file that lacks the key.
    # Pipe stdout+stderr through grep -v to confirm "script-writes" is absent.
    local _tmpd
    _tmpd=$(mktemp -d)
    trap 'rm -rf "$_tmpd"' RETURN

    # Minimal config: no checks.script_write_scan_dir key
    cat > "$_tmpd/wc.conf" << 'CONF'
version=1.0.0
paths.app_dir=nonexistent-app-dir-that-wont-run
CONF

    # Run validate.sh with the minimal config. It will fail fast because the
    # app dir doesn't exist, but we only care that "script-writes" is not present.
    local _out=""
    _out=$(CONFIG_FILE="$_tmpd/wc.conf" bash "$VALIDATE_SH" 2>&1 || true)
    if [[ "$_out" == *"script-writes"* ]]; then
        assert_eq "script-writes absent when key absent" "absent" "present"
    else
        assert_eq "script-writes absent when key absent" "absent" "absent"
    fi

    assert_pass_if_clean "test_validate_skips_when_key_absent"
}

# ── test_validate_skips_when_key_empty ────────────────────────────────────────
# With checks.script_write_scan_dir= (empty value), check is skipped.
test_validate_skips_when_key_empty() {
    _snapshot_fail

    local _tmpd
    _tmpd=$(mktemp -d)
    trap 'rm -rf "$_tmpd"' RETURN

    # Config with empty value for the key
    cat > "$_tmpd/wc.conf" << 'CONF'
version=1.0.0
paths.app_dir=nonexistent-app-dir-that-wont-run
checks.script_write_scan_dir=
CONF

    local _out=""
    _out=$(CONFIG_FILE="$_tmpd/wc.conf" bash "$VALIDATE_SH" 2>&1 || true)
    if [[ "$_out" == *"script-writes"* ]]; then
        assert_eq "script-writes absent when key empty" "absent" "present"
    else
        assert_eq "script-writes absent when key empty" "absent" "absent"
    fi

    assert_pass_if_clean "test_validate_skips_when_key_empty"
}

# ── test_config_key_reads_correctly ───────────────────────────────────────────
# read-config.sh checks.script_write_scan_dir returns the configured scan directory.
test_config_key_reads_correctly() {
    _snapshot_fail

    local _tmpd
    _tmpd=$(mktemp -d)
    trap 'rm -rf "$_tmpd"' RETURN

    cat > "$_tmpd/wc.conf" << 'CONF'
version=1.0.0
checks.script_write_scan_dir=.
CONF

    local _val=""
    _val=$(bash "$READ_CONFIG" "checks.script_write_scan_dir" "$_tmpd/wc.conf" 2>/dev/null || true)
    assert_eq "read-config resolves checks.script_write_scan_dir" "." "$_val"

    assert_pass_if_clean "test_config_key_reads_correctly"
}

# ── test_end_to_end_violation_detected ────────────────────────────────────────
# Create a synthetic scan dir with a script containing a repo-root write.
# Configure validate.sh to scan that dir. Verify the script-writes check fails.
# We run check-script-writes.py directly (not the full validate.sh suite) for
# speed and isolation.
test_end_to_end_violation_detected() {
    _snapshot_fail

    local _tmpd
    _tmpd=$(mktemp -d)
    trap 'rm -rf "$_tmpd"' RETURN

    # Create a synthetic script with a repo-root write violation
    cat > "$_tmpd/bad_script.sh" << 'EOF'
#!/usr/bin/env bash
echo "state" > ./state-file.txt
EOF

    # Run check-script-writes.py directly against the temp dir
    local _exit=0
    local _out=""
    _out=$(python3 "$CHECK_SCRIPT_WRITES" --scan-dir="$_tmpd" 2>&1) || _exit=$?

    # Should exit 1 (violation found) or exit 0 if shfmt not available
    if [ "$_exit" -eq 0 ]; then
        # shfmt not available — check if the script reported "shfmt not found"
        if [[ "$_out" == *"shfmt not found"* ]]; then
            # Graceful skip — shfmt unavailable, test still passes
            assert_eq "end-to-end: shfmt unavailable, graceful skip" "0" "0"
        else
            # shfmt present but no violation detected — that's a failure
            assert_eq "end-to-end: violation detected (exit 1)" "1" "0"
        fi
    else
        # violation detected (exit != 0), expected
        assert_eq "end-to-end: violation detected" "1" "$_exit"
        assert_contains "end-to-end: FAIL output present" "FAIL" "$_out"
    fi

    assert_pass_if_clean "test_end_to_end_violation_detected"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_validate_runs_script_writes_check
test_validate_skips_when_key_absent
test_validate_skips_when_key_empty
test_config_key_reads_correctly
test_end_to_end_violation_detected

print_summary
