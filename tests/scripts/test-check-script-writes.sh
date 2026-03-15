#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-check-script-writes.sh
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
#
# Usage: bash lockpick-workflow/tests/scripts/test-check-script-writes.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/check-script-writes.py"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-check-script-writes.sh ==="

# ── test_no_shfmt_skips_gracefully ────────────────────────────────────────────
# When --shfmt-path points to a nonexistent binary, exit 0 and output "shfmt not found"
test_no_shfmt_skips_gracefully() {
    _snapshot_fail
    local _exit=0
    local _out=""
    _out=$(python3 "$SCRIPT" --scan-dir="$REPO_ROOT/lockpick-workflow" --shfmt-path=/nonexistent 2>&1) || _exit=$?
    assert_eq "test_no_shfmt_skips_gracefully: exit 0" "0" "$_exit"
    assert_contains "test_no_shfmt_skips_gracefully: output contains 'shfmt not found'" "shfmt not found" "$_out"
    assert_pass_if_clean "test_no_shfmt_skips_gracefully"
}

# ── test_clean_script_passes ──────────────────────────────────────────────────
# A script with no writes should exit 0
test_clean_script_passes() {
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

print_summary
