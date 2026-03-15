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
_snapshot_fail
_t1_exit=0
_t1_out=""
_t1_out=$(python3 "$SCRIPT" --scan-dir="$REPO_ROOT/lockpick-workflow" --shfmt-path=/nonexistent 2>&1) || _t1_exit=$?
assert_eq "test_no_shfmt_skips_gracefully: exit 0" "0" "$_t1_exit"
assert_contains "test_no_shfmt_skips_gracefully: output contains 'shfmt not found'" "shfmt not found" "$_t1_out"
assert_pass_if_clean "test_no_shfmt_skips_gracefully"

# ── test_clean_script_passes ──────────────────────────────────────────────────
# A script with no writes should exit 0
_snapshot_fail
_t2_dir=$(mktemp -d)
trap 'rm -rf "$_t2_dir"' EXIT
cat > "$_t2_dir/clean.sh" << 'EOF'
#!/usr/bin/env bash
echo "hello world"
FOO=bar
VAL=$(echo "$FOO")
echo "$VAL"
EOF
_t2_exit=0
_t2_out=""
_t2_out=$(python3 "$SCRIPT" --scan-dir="$_t2_dir" 2>&1) || _t2_exit=$?
assert_eq "test_clean_script_passes: exit 0" "0" "$_t2_exit"
assert_pass_if_clean "test_clean_script_passes"

# ── test_redirect_to_repo_root_detected ──────────────────────────────────────
# echo x > ./state/foo.txt → exit 1, FAIL [file:line] write to repo-root path:
_snapshot_fail
_t3_dir=$(mktemp -d)
trap 'rm -rf "$_t3_dir"' EXIT
cat > "$_t3_dir/redirect.sh" << 'EOF'
#!/usr/bin/env bash
echo x > ./state/foo.txt
EOF
_t3_exit=0
_t3_out=""
_t3_out=$(python3 "$SCRIPT" --scan-dir="$_t3_dir" 2>&1) || _t3_exit=$?
assert_eq "test_redirect_to_repo_root_detected: exit 1" "1" "$_t3_exit"
if [[ "$_t3_out" =~ "FAIL "[^:]*:[0-9]*"]" ]]; then
    assert_eq "test_redirect_to_repo_root_detected: FAIL format" "yes" "yes"
elif echo "$_t3_out" | grep -qE 'FAIL \[.*:[0-9]+\] write to repo-root path:'; then
    assert_eq "test_redirect_to_repo_root_detected: FAIL format" "yes" "yes"
else
    assert_eq "test_redirect_to_repo_root_detected: FAIL format" "FAIL [file:line] write to repo-root path:" "$_t3_out"
fi
assert_pass_if_clean "test_redirect_to_repo_root_detected"

# ── test_append_redirect_detected ─────────────────────────────────────────────
# echo x >> ./log.txt → exit 1
_snapshot_fail
_t4_dir=$(mktemp -d)
trap 'rm -rf "$_t4_dir"' EXIT
cat > "$_t4_dir/append.sh" << 'EOF'
#!/usr/bin/env bash
echo x >> ./log.txt
EOF
_t4_exit=0
_t4_out=""
_t4_out=$(python3 "$SCRIPT" --scan-dir="$_t4_dir" 2>&1) || _t4_exit=$?
assert_eq "test_append_redirect_detected: exit 1" "1" "$_t4_exit"
assert_pass_if_clean "test_append_redirect_detected"

# ── test_tee_to_repo_root_detected ───────────────────────────────────────────
# echo x | tee ./out.txt → exit 1
_snapshot_fail
_t5_dir=$(mktemp -d)
trap 'rm -rf "$_t5_dir"' EXIT
cat > "$_t5_dir/tee.sh" << 'EOF'
#!/usr/bin/env bash
echo x | tee ./out.txt
EOF
_t5_exit=0
_t5_out=""
_t5_out=$(python3 "$SCRIPT" --scan-dir="$_t5_dir" 2>&1) || _t5_exit=$?
assert_eq "test_tee_to_repo_root_detected: exit 1" "1" "$_t5_exit"
assert_pass_if_clean "test_tee_to_repo_root_detected"

# ── test_cp_to_repo_root_detected ────────────────────────────────────────────
# cp /tmp/a ./b → exit 1
_snapshot_fail
_t6_dir=$(mktemp -d)
trap 'rm -rf "$_t6_dir"' EXIT
cat > "$_t6_dir/cp_cmd.sh" << 'EOF'
#!/usr/bin/env bash
cp /tmp/a ./b
EOF
_t6_exit=0
_t6_out=""
_t6_out=$(python3 "$SCRIPT" --scan-dir="$_t6_dir" 2>&1) || _t6_exit=$?
assert_eq "test_cp_to_repo_root_detected: exit 1" "1" "$_t6_exit"
assert_pass_if_clean "test_cp_to_repo_root_detected"

# ── test_mv_to_repo_root_detected ────────────────────────────────────────────
# mv /tmp/a ./b → exit 1
_snapshot_fail
_t7_dir=$(mktemp -d)
trap 'rm -rf "$_t7_dir"' EXIT
cat > "$_t7_dir/mv_cmd.sh" << 'EOF'
#!/usr/bin/env bash
mv /tmp/a ./b
EOF
_t7_exit=0
_t7_out=""
_t7_out=$(python3 "$SCRIPT" --scan-dir="$_t7_dir" 2>&1) || _t7_exit=$?
assert_eq "test_mv_to_repo_root_detected: exit 1" "1" "$_t7_exit"
assert_pass_if_clean "test_mv_to_repo_root_detected"

# ── test_tmp_path_not_flagged ─────────────────────────────────────────────────
# echo x > /tmp/foo → exit 0 (not a repo-root path)
_snapshot_fail
_t8_dir=$(mktemp -d)
trap 'rm -rf "$_t8_dir"' EXIT
cat > "$_t8_dir/tmp_write.sh" << 'EOF'
#!/usr/bin/env bash
echo x > /tmp/foo
EOF
_t8_exit=0
_t8_out=""
_t8_out=$(python3 "$SCRIPT" --scan-dir="$_t8_dir" 2>&1) || _t8_exit=$?
assert_eq "test_tmp_path_not_flagged: exit 0" "0" "$_t8_exit"
assert_pass_if_clean "test_tmp_path_not_flagged"

# ── test_dev_null_not_flagged ─────────────────────────────────────────────────
# echo x > /dev/null → exit 0
_snapshot_fail
_t9_dir=$(mktemp -d)
trap 'rm -rf "$_t9_dir"' EXIT
cat > "$_t9_dir/devnull.sh" << 'EOF'
#!/usr/bin/env bash
echo x > /dev/null
EOF
_t9_exit=0
_t9_out=""
_t9_out=$(python3 "$SCRIPT" --scan-dir="$_t9_dir" 2>&1) || _t9_exit=$?
assert_eq "test_dev_null_not_flagged: exit 0" "0" "$_t9_exit"
assert_pass_if_clean "test_dev_null_not_flagged"

# ── test_write_ok_suppresses ──────────────────────────────────────────────────
# Same-line # write-ok: reason → exit 0
_snapshot_fail
_t10_dir=$(mktemp -d)
trap 'rm -rf "$_t10_dir"' EXIT
cat > "$_t10_dir/suppressed.sh" << 'EOF'
#!/usr/bin/env bash
echo x > ./foo.txt # write-ok: needed for state
EOF
_t10_exit=0
_t10_out=""
_t10_out=$(python3 "$SCRIPT" --scan-dir="$_t10_dir" 2>&1) || _t10_exit=$?
assert_eq "test_write_ok_suppresses: exit 0" "0" "$_t10_exit"
assert_pass_if_clean "test_write_ok_suppresses"

# ── test_write_ok_adjacent_not_suppressed ─────────────────────────────────────
# write-ok on line above does NOT suppress the write on the next line → exit 1
_snapshot_fail
_t11_dir=$(mktemp -d)
trap 'rm -rf "$_t11_dir"' EXIT
cat > "$_t11_dir/not_suppressed.sh" << 'EOF'
#!/usr/bin/env bash
# write-ok: this comment is on a different line
echo x > ./foo.txt
EOF
_t11_exit=0
_t11_out=""
_t11_out=$(python3 "$SCRIPT" --scan-dir="$_t11_dir" 2>&1) || _t11_exit=$?
assert_eq "test_write_ok_adjacent_not_suppressed: exit 1" "1" "$_t11_exit"
assert_pass_if_clean "test_write_ok_adjacent_not_suppressed"

# ── test_variable_resolution_repo_root ───────────────────────────────────────
# OUTDIR="./results"; echo x > "$OUTDIR/f" → exit 1 (Tier 1 literal resolution)
_snapshot_fail
_t12_dir=$(mktemp -d)
trap 'rm -rf "$_t12_dir"' EXIT
cat > "$_t12_dir/varwrite.sh" << 'EOF'
#!/usr/bin/env bash
OUTDIR="./results"
echo x > "$OUTDIR/f"
EOF
_t12_exit=0
_t12_out=""
_t12_out=$(python3 "$SCRIPT" --scan-dir="$_t12_dir" 2>&1) || _t12_exit=$?
assert_eq "test_variable_resolution_repo_root: exit 1" "1" "$_t12_exit"
assert_pass_if_clean "test_variable_resolution_repo_root"

# ── test_cross_file_variable_tracing ──────────────────────────────────────────
# File A: STATE_DIR="./state", File B: echo x > "$STATE_DIR/f" → exit 1 (Tier 2)
_snapshot_fail
_t13_dir=$(mktemp -d)
trap 'rm -rf "$_t13_dir"' EXIT
cat > "$_t13_dir/definitions.sh" << 'EOF'
#!/usr/bin/env bash
STATE_DIR="./state"
EOF
cat > "$_t13_dir/writer.sh" << 'EOF'
#!/usr/bin/env bash
echo x > "$STATE_DIR/f"
EOF
_t13_exit=0
_t13_out=""
_t13_out=$(python3 "$SCRIPT" --scan-dir="$_t13_dir" 2>&1) || _t13_exit=$?
assert_eq "test_cross_file_variable_tracing: exit 1" "1" "$_t13_exit"
assert_pass_if_clean "test_cross_file_variable_tracing"

print_summary
