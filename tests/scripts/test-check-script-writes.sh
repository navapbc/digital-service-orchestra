#!/usr/bin/env bash
# tests/scripts/test-check-script-writes.sh
# TDD tests for check-script-writes.py — shfmt AST-based file-write detector.
#
# Tests:
#  1. test_no_shfmt_skips_gracefully        — --shfmt-path=/nonexistent → exit 0 + "shfmt not found"
#  2. test_clean_script_passes              — no writes → exit 0
#  3. test_redirect_to_repo_root_detected   — echo x > ./state/foo.txt → exit 1, FAIL output
#  4. test_append_redirect_detected         — echo x >> ./log.txt → exit 1
#  5. test_tee_to_repo_root_detected        — echo x | tee ./out.txt → exit 1
#  6. test_cp_to_repo_root_detected         — cp /tmp/a ./b → exit 1
#  7. test_mv_to_repo_root_detected         — mv /tmp/a ./b → exit 1
#  8. test_tmp_path_not_flagged             — echo x > /tmp/foo → exit 0
#  9. test_dev_null_not_flagged             — echo x > /dev/null → exit 0
# 10. test_write_ok_suppresses              — same-line # write-ok: reason → exit 0
# 11. test_write_ok_adjacent_not_suppressed — write-ok on prior line, write on next → exit 1
# 12. test_variable_resolution_repo_root   — OUTDIR="./results"; echo x > "$OUTDIR/f" → exit 1
# 13. test_cross_file_variable_tracing     — File A: STATE_DIR="./state", File B: write to $STATE_DIR/f → exit 1
# 14. test_discover_ops_happy_path          — real shfmt discovers Op codes → redirect detected
# 15. test_discover_ops_shfmt_error_fallback — fake shfmt errors → fallback, no crash
# 16. test_discover_ops_uses_discovered_codes — fake shfmt returns Op=999 → discovery uses it
#
# Usage: bash tests/scripts/test-check-script-writes.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/check-script-writes.py"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-script-writes.sh ==="

# Check if shfmt is available — tests that require AST parsing need it
_shfmt_available=false
if command -v shfmt >/dev/null 2>&1; then
    _shfmt_available=true
fi

# Helper: skip test if shfmt is not available
_require_shfmt() {
    if [ "$_shfmt_available" = false ]; then
        echo "test_$1 ... SKIP (shfmt not installed)"
        return 1
    fi
    return 0
}

# ── test_no_shfmt_skips_gracefully ────────────────────────────────────────────
# When --shfmt-path points to a nonexistent binary, exit 0 and output "shfmt not found"
test_no_shfmt_skips_gracefully() {
    _snapshot_fail
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="${CLAUDE_PLUGIN_ROOT}" --shfmt-path=/nonexistent 2>&1) || _exit=$?
    assert_eq "test_no_shfmt_skips_gracefully: exit 0" "0" "$_exit"
    assert_contains "test_no_shfmt_skips_gracefully: output contains 'shfmt not found'" "shfmt not found" "$_out"
    assert_pass_if_clean "test_no_shfmt_skips_gracefully"
}

# ── test_clean_script_passes ──────────────────────────────────────────────────
# A script with no writes should exit 0
test_clean_script_passes() {
    _require_shfmt "clean_script_passes" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/clean.sh" << 'EOF'
#!/usr/bin/env bash
echo "hello world"
FOO=bar
VAL=$(echo "$FOO")
echo "$VAL"
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_clean_script_passes: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_clean_script_passes"
}

# ── test_redirect_to_repo_root_detected ──────────────────────────────────────
# echo x > ./state/foo.txt → exit 1, FAIL [file:line] write to repo-root path:
test_redirect_to_repo_root_detected() {
    _require_shfmt "redirect_to_repo_root_detected" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/redirect.sh" << 'EOF'
#!/usr/bin/env bash
echo x > ./state/foo.txt
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_redirect_to_repo_root_detected: exit 1" "1" "$_exit"
    if echo "$_out" | grep -qE 'FAIL \[.*:[0-9]+\] write to repo-root path:'; then
        assert_eq "test_redirect_to_repo_root_detected: FAIL format" "yes" "yes"
    else
        assert_eq "test_redirect_to_repo_root_detected: FAIL format" "FAIL [file:line] write to repo-root path:" "$_out"
    fi
    assert_pass_if_clean "test_redirect_to_repo_root_detected"
}

# ── test_append_redirect_detected ─────────────────────────────────────────────
# echo x >> ./log.txt → exit 1
test_append_redirect_detected() {
    _require_shfmt "append_redirect_detected" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/append.sh" << 'EOF'
#!/usr/bin/env bash
echo x >> ./log.txt
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_append_redirect_detected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_append_redirect_detected"
}

# ── test_tee_to_repo_root_detected ───────────────────────────────────────────
# echo x | tee ./out.txt → exit 1
test_tee_to_repo_root_detected() {
    _require_shfmt "tee_to_repo_root_detected" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/tee.sh" << 'EOF'
#!/usr/bin/env bash
echo x | tee ./out.txt
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_tee_to_repo_root_detected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_tee_to_repo_root_detected"
}

# ── test_cp_to_repo_root_detected ────────────────────────────────────────────
# cp /tmp/a ./b → exit 1
test_cp_to_repo_root_detected() {
    _require_shfmt "cp_to_repo_root_detected" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/cp_cmd.sh" << 'EOF'
#!/usr/bin/env bash
cp /tmp/a ./b
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_cp_to_repo_root_detected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_cp_to_repo_root_detected"
}

# ── test_mv_to_repo_root_detected ────────────────────────────────────────────
# mv /tmp/a ./b → exit 1
test_mv_to_repo_root_detected() {
    _require_shfmt "mv_to_repo_root_detected" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/mv_cmd.sh" << 'EOF'
#!/usr/bin/env bash
mv /tmp/a ./b
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_mv_to_repo_root_detected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_mv_to_repo_root_detected"
}

# ── test_tmp_path_not_flagged ─────────────────────────────────────────────────
# echo x > /tmp/foo → exit 0 (not a repo-root path)
test_tmp_path_not_flagged() {
    _require_shfmt "tmp_path_not_flagged" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/tmp_write.sh" << 'EOF'
#!/usr/bin/env bash
echo x > /tmp/foo
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_tmp_path_not_flagged: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_tmp_path_not_flagged"
}

# ── test_dev_null_not_flagged ─────────────────────────────────────────────────
# echo x > /dev/null → exit 0
test_dev_null_not_flagged() {
    _require_shfmt "dev_null_not_flagged" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/devnull.sh" << 'EOF'
#!/usr/bin/env bash
echo x > /dev/null
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_dev_null_not_flagged: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_dev_null_not_flagged"
}

# ── test_write_ok_suppresses ──────────────────────────────────────────────────
# Same-line # write-ok: reason → exit 0
test_write_ok_suppresses() {
    _require_shfmt "write_ok_suppresses" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/suppressed.sh" << 'EOF'
#!/usr/bin/env bash
echo x > ./foo.txt # write-ok: needed for state
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_write_ok_suppresses: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_write_ok_suppresses"
}

# ── test_write_ok_adjacent_not_suppressed ─────────────────────────────────────
# write-ok on line above does NOT suppress the write on the next line → exit 1
test_write_ok_adjacent_not_suppressed() {
    _require_shfmt "write_ok_adjacent_not_suppressed" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/not_suppressed.sh" << 'EOF'
#!/usr/bin/env bash
# write-ok: this comment is on a different line
echo x > ./foo.txt
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_write_ok_adjacent_not_suppressed: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_write_ok_adjacent_not_suppressed"
}

# ── test_variable_resolution_repo_root ───────────────────────────────────────
# OUTDIR="./results"; echo x > "$OUTDIR/f" → exit 1 (Tier 1 literal resolution)
test_variable_resolution_repo_root() {
    _require_shfmt "variable_resolution_repo_root" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/varwrite.sh" << 'EOF'
#!/usr/bin/env bash
OUTDIR="./results"
echo x > "$OUTDIR/f"
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_variable_resolution_repo_root: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_variable_resolution_repo_root"
}

# ── test_cross_file_variable_tracing ──────────────────────────────────────────
# File A: STATE_DIR="./state", File B: echo x > "$STATE_DIR/f" → exit 1 (Tier 2)
test_cross_file_variable_tracing() {
    _require_shfmt "cross_file_variable_tracing" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/definitions.sh" << 'EOF'
#!/usr/bin/env bash
STATE_DIR="./state"
EOF
    cat > "$_dir/writer.sh" << 'EOF'
#!/usr/bin/env bash
echo x > "$STATE_DIR/f"
EOF
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_cross_file_variable_tracing: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_cross_file_variable_tracing"
}

# ── test_discover_ops_happy_path ──────────────────────────────────────────────
# When a working shfmt is provided via --shfmt-path, discover_write_redirect_ops
# finds the correct Op codes, so redirects to repo-root paths are detected.
test_discover_ops_happy_path() {
    _require_shfmt "discover_ops_happy_path" || return 0
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    # Create a script with a redirect that should be caught
    cat > "$_dir/write.sh" << 'EOF'
#!/usr/bin/env bash
echo data > ./output.txt
EOF
    local _exit=0
    local _out=""
    # Use the real shfmt — discovery should find the right Op codes
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" 2>&1) || _exit=$?
    assert_eq "test_discover_ops_happy_path: exit 1 (redirect detected)" "1" "$_exit"
    assert_contains "test_discover_ops_happy_path: FAIL in output" "FAIL" "$_out"
    assert_pass_if_clean "test_discover_ops_happy_path"
}

# ── test_discover_ops_shfmt_error_fallback ───────────────────────────────────
# When --shfmt-path points to a program that always errors, the script falls back
# to hardcoded Op codes {54, 55} and does not crash.
test_discover_ops_shfmt_error_fallback() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    # Create a fake shfmt that always fails
    cat > "$_dir/fake_shfmt" << 'SHFMT'
#!/usr/bin/env bash
exit 1
SHFMT
    chmod +x "$_dir/fake_shfmt"
    # Create a script with a redirect
    cat > "$_dir/write.sh" << 'EOF'
#!/usr/bin/env bash
echo data > ./output.txt
EOF
    local _exit=0
    local _out=""
    # The fake shfmt errors on discovery AND on parsing — so no AST, no violations, exit 0
    # Key: it should NOT crash (no unhandled exception)
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" --shfmt-path="$_dir/fake_shfmt" 2>&1) || _exit=$?
    assert_eq "test_discover_ops_shfmt_error_fallback: exit 0 (no crash)" "0" "$_exit"
    assert_pass_if_clean "test_discover_ops_shfmt_error_fallback"
}

# ── test_discover_ops_uses_discovered_codes ──────────────────────────────────
# A fake shfmt that returns a custom Op code for '>' proves discovery works:
# the script uses the discovered code (not hardcoded {54, 55}).
test_discover_ops_uses_discovered_codes() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    # Create a fake shfmt that:
    # - For discovery probes: returns AST with a custom Op code (999)
    # - For actual file parsing: returns AST with Op=999 for the redirect
    cat > "$_dir/fake_shfmt" << 'SHFMT'
#!/usr/bin/env bash
# Read stdin
input=$(cat)
# Return a minimal AST with a redirect Op=999
cat << 'AST'
{"Stmts":[{"Pos":{"Line":2},"Cmd":{"Type":"CallExpr","Args":[{"Parts":[{"Type":"Lit","Value":"echo"}]},{"Parts":[{"Type":"Lit","Value":"data"}]}]},"Redirs":[{"Op":999,"Pos":{"Line":2},"Word":{"Parts":[{"Type":"Lit","Value":"./output.txt"}]}}]}]}
AST
SHFMT
    chmod +x "$_dir/fake_shfmt"
    # Create a script with a redirect
    cat > "$_dir/write.sh" << 'EOF'
#!/usr/bin/env bash
echo data > ./output.txt
EOF
    local _exit=0
    local _out=""
    # The fake shfmt returns Op=999 — discovery should pick it up, then detect the violation
    _out=$(python3 "$SCRIPT" --scan-dir="$_dir" --shfmt-path="$_dir/fake_shfmt" 2>&1) || _exit=$?
    assert_eq "test_discover_ops_uses_discovered_codes: exit 1 (custom op detected)" "1" "$_exit"
    assert_contains "test_discover_ops_uses_discovered_codes: FAIL in output" "FAIL" "$_out"
    assert_pass_if_clean "test_discover_ops_uses_discovered_codes"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_no_shfmt_skips_gracefully
test_clean_script_passes
test_redirect_to_repo_root_detected
test_append_redirect_detected
test_tee_to_repo_root_detected
test_cp_to_repo_root_detected
test_mv_to_repo_root_detected
test_tmp_path_not_flagged
test_dev_null_not_flagged
test_write_ok_suppresses
test_write_ok_adjacent_not_suppressed
test_variable_resolution_repo_root
test_cross_file_variable_tracing
test_discover_ops_happy_path
test_discover_ops_shfmt_error_fallback
test_discover_ops_uses_discovered_codes

print_summary
