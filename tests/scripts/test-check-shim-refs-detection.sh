#!/usr/bin/env bash
# tests/scripts/test-check-shim-refs-detection.sh
# TDD tests for check-shim-refs.sh — detects direct plugin path references
# that should use the .claude/scripts/dso shim instead.
#
# Tests:
#  (a) test_exit_nonzero_on_direct_path        — plugins/dso/scripts/foo.sh -> exit 1
#  (b) test_exit_zero_on_clean                 — .claude/scripts/dso foo.sh -> exit 0
#  (c) test_variable_plugin_scripts            — $PLUGIN_SCRIPTS/foo.sh -> exit 1
#  (d) test_variable_claude_plugin_root        — ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh -> exit 1
#  (e) test_hooks_lib_source_exempt            — source plugins/dso/hooks/lib/deps.sh -> exit 0
#  (f) test_shim_exempt_annotation             — line with # shim-exempt: bootstrap -> exit 0
#  (g) test_shim_exempt_case_insensitive       — # SHIM-EXEMPT: reason -> exit 0
#  (h) test_script_dir_file_excluded           — file IN plugins/dso/scripts/ not scanned
#
# Usage: bash tests/scripts/test-check-shim-refs-detection.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/check-shim-refs.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-shim-refs-detection.sh ==="

# ── test_exit_nonzero_on_direct_path ─────────────────────────────────────────
# (a) A file referencing plugins/dso/scripts/foo.sh directly should exit != 0
test_exit_nonzero_on_direct_path() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/test-script.sh" << 'EOF'
#!/usr/bin/env bash
# This script calls a plugin script directly
bash plugins/dso/scripts/validate.sh --ci
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/test-script.sh" 2>&1 || _exit=$?
    assert_ne "test_exit_nonzero_on_direct_path: exit != 0 for direct path" "0" "$_exit"
    assert_pass_if_clean "test_exit_nonzero_on_direct_path"
}

# ── test_exit_zero_on_clean ───────────────────────────────────────────────────
# (b) A file using the .claude/scripts/dso shim should exit 0
test_exit_zero_on_clean() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/clean-script.sh" << 'EOF'
#!/usr/bin/env bash
# This script uses the approved shim
.claude/scripts/dso validate.sh --ci
.claude/scripts/dso ticket list
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/clean-script.sh" 2>&1 || _exit=$?
    assert_eq "test_exit_zero_on_clean: exit 0 for shim usage" "0" "$_exit"
    assert_pass_if_clean "test_exit_zero_on_clean"
}

# ── test_variable_plugin_scripts ──────────────────────────────────────────────
# (c) A file using $PLUGIN_SCRIPTS/foo.sh should exit != 0
test_variable_plugin_scripts() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/var-script.sh" << 'EOF'
#!/usr/bin/env bash
PLUGIN_SCRIPTS="plugins/dso/scripts"
bash $PLUGIN_SCRIPTS/validate.sh --ci
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/var-script.sh" 2>&1 || _exit=$?
    assert_ne "test_variable_plugin_scripts: exit != 0 for \$PLUGIN_SCRIPTS usage" "0" "$_exit"
    assert_pass_if_clean "test_variable_plugin_scripts"
}

# ── test_variable_claude_plugin_root ──────────────────────────────────────────
# (d) A file using ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh should exit != 0
test_variable_claude_plugin_root() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/plugin-root-script.sh" << 'EOF'
#!/usr/bin/env bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh --ci
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/plugin-root-script.sh" 2>&1 || _exit=$?
    assert_ne "test_variable_claude_plugin_root: exit != 0 for \${CLAUDE_PLUGIN_ROOT}/scripts" "0" "$_exit"
    assert_pass_if_clean "test_variable_claude_plugin_root"
}

# ── test_hooks_lib_source_exempt ──────────────────────────────────────────────
# (e) source plugins/dso/hooks/lib/deps.sh is exempt (hooks/lib path, not scripts/)
test_hooks_lib_source_exempt() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/hooks-lib-script.sh" << 'EOF'
#!/usr/bin/env bash
# This sources from hooks/lib which is exempt
source plugins/dso/hooks/lib/assert.sh
source plugins/dso/hooks/lib/merge-state.sh
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/hooks-lib-script.sh" 2>&1 || _exit=$?
    assert_eq "test_hooks_lib_source_exempt: exit 0 for hooks/lib source" "0" "$_exit"
    assert_pass_if_clean "test_hooks_lib_source_exempt"
}

# ── test_shim_exempt_annotation ───────────────────────────────────────────────
# (f) A line with # shim-exempt: reason should be exempt
test_shim_exempt_annotation() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/exempt-script.sh" << 'EOF'
#!/usr/bin/env bash
# Bootstrap script that must call plugin directly
bash plugins/dso/scripts/onboarding/dso-setup.sh "$@"  # shim-exempt: bootstrap installer
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/exempt-script.sh" 2>&1 || _exit=$?
    assert_eq "test_shim_exempt_annotation: exit 0 for # shim-exempt: annotation" "0" "$_exit"
    assert_pass_if_clean "test_shim_exempt_annotation"
}

# ── test_shim_exempt_case_insensitive ─────────────────────────────────────────
# (g) # SHIM-EXEMPT: reason (uppercase) should also be exempt
test_shim_exempt_case_insensitive() {
    _snapshot_fail
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    cat > "$_dir/exempt-upper-script.sh" << 'EOF'
#!/usr/bin/env bash
# Bootstrap script that must call plugin directly
bash plugins/dso/scripts/onboarding/dso-setup.sh "$@"  # SHIM-EXEMPT: bootstrap installer
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/exempt-upper-script.sh" 2>&1 || _exit=$?
    assert_eq "test_shim_exempt_case_insensitive: exit 0 for # SHIM-EXEMPT: uppercase" "0" "$_exit"
    assert_pass_if_clean "test_shim_exempt_case_insensitive"
}

# ── test_script_dir_file_excluded ─────────────────────────────────────────────
# (h) Files IN plugins/dso/scripts/ should not be scanned (they ARE the scripts)
test_script_dir_file_excluded() {
    _snapshot_fail
    # Create a temp dir that mimics being inside plugins/dso/scripts/
    local _dir
    _dir=$(mktemp -d)
    trap 'rm -rf "$_dir"' RETURN
    # Create nested structure to simulate plugins/dso/scripts/ path
    mkdir -p "$_dir/plugins/dso/scripts"
    cat > "$_dir/plugins/dso/scripts/my-script.sh" << 'EOF'
#!/usr/bin/env bash
# This is a plugin script that references sibling scripts
bash plugins/dso/scripts/validate.sh --ci
EOF
    local _exit=0
    bash "$SCRIPT" "$_dir/plugins/dso/scripts/my-script.sh" 2>&1 || _exit=$?
    assert_eq "test_script_dir_file_excluded: exit 0 for file in plugins/dso/scripts/" "0" "$_exit"
    assert_pass_if_clean "test_script_dir_file_excluded"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_exit_nonzero_on_direct_path
test_exit_zero_on_clean
test_variable_plugin_scripts
test_variable_claude_plugin_root
test_hooks_lib_source_exempt
test_shim_exempt_annotation
test_shim_exempt_case_insensitive
test_script_dir_file_excluded

print_summary
