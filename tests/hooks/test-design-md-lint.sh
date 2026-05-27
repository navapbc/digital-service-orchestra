#!/usr/bin/env bash
# tests/hooks/test-design-md-lint.sh
# Behavioral tests for scripts/design-md-lint.sh
#
# Tests cover:
#   - never mode exits 0 immediately
#   - auto mode enables lint when UI files staged
#   - auto mode skips lint when no UI files staged
#   - npx absent exits 0 (fail-open)
#   - missing DESIGN.md exits 0 (fail-open)
#   - no staged files exits 0
#   - diff-touched line scoping: untouched violations do not cause failure
#   - JSON summary.errors parsing (not exit-code reliance)
#   - [test_design_md_lint_diff_scoping] RED marker for scripts/design-md-lint.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}"
TARGET_SCRIPT="$_PLUGIN_ROOT/scripts/design-md-lint.sh"

# ── RED gate: fail immediately if design-md-lint.sh does not exist ──
if [[ ! -f "$TARGET_SCRIPT" ]]; then
    printf "FAIL: design-md-lint.sh does not exist at: %s\n" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

if [[ ! -x "$TARGET_SCRIPT" ]]; then
    printf "FAIL: design-md-lint.sh is not executable at: %s\n" "$TARGET_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# ── Shared fixture setup ──────────────────────────────────────────────────────
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    printf '%s' "$d"
}

# Helper: write a minimal dso-config.conf with design.lint_enabled set
make_lint_config() {
    local config_file="$1"
    local lint_enabled="$2"
    printf 'design.lint_enabled=%s\n' "$lint_enabled" > "$config_file"
}

# Helper: write a minimal design notes file (DESIGN.md substitute)
make_design_notes() {
    local path="$1"
    printf '# Design Notes\nThis is a placeholder design notes file.\n' > "$path"
}

# Helper: create a fake npx wrapper that records calls and emits JSON
make_fake_npx() {
    local bin_dir="$1"
    local errors="${2:-0}"
    local warnings="${3:-0}"
    cat > "$bin_dir/npx" << EOF
#!/usr/bin/env bash
# Fake npx for testing design-md-lint.sh
printf '{"summary":{"errors":$errors,"warnings":$warnings},"findings":[]}\n'
exit 0
EOF
    chmod +x "$bin_dir/npx"
}

# ── Case 1: never mode exits 0 immediately ───────────────────────────────────
# Given: design.lint_enabled=never in dso-config.conf
# When:  design-md-lint.sh is called
# Then:  exits 0 without running npx
test_never_mode_exits_zero() {
    local tmp_dir config_file exit_code
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"

    make_lint_config "$config_file" "never"

    exit_code=0
    DSO_CONFIG_PATH="$config_file" bash "$TARGET_SCRIPT" >/dev/null 2>&1 || exit_code=$?
    assert_eq "never_mode_exits_zero" "0" "$exit_code"
}

# ── Case 2: npx absent exits 0 (fail-open) ───────────────────────────────────
# Given: design.lint_enabled=auto and npx not in PATH
# When:  design-md-lint.sh is called
# Then:  exits 0 (fail-open)
test_npx_absent_exits_zero() {
    local tmp_dir config_file exit_code output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"

    make_lint_config "$config_file" "auto"

    exit_code=0
    output=$(DSO_CONFIG_PATH="$config_file" PATH="/usr/bin:/bin" bash "$TARGET_SCRIPT" 2>&1) || exit_code=$?
    assert_eq "npx_absent_exits_zero" "0" "$exit_code"
    assert_contains "npx_absent_skip_message" "npx not available" "$output"
}

# ── Case 3: missing DESIGN.md exits 0 (fail-open) ────────────────────────────
# Given: design.lint_enabled=auto, npx available, DESIGN.md missing
# When:  design-md-lint.sh is called
# Then:  exits 0 (fail-open)
test_missing_design_md_exits_zero() {
    local tmp_dir config_file exit_code output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"

    make_lint_config "$config_file" "auto"

    exit_code=0
    output=$(DSO_CONFIG_PATH="$config_file" DESIGN_MD_NOTES_PATH="${tmp_dir}/nonexistent.md" bash "$TARGET_SCRIPT" 2>&1) || exit_code=$?
    assert_eq "missing_design_md_exits_zero" "0" "$exit_code"
    assert_contains "missing_design_md_skip_message" "not found" "$output"
}

# ── Case 4: no staged files exits 0 ──────────────────────────────────────────
# Given: design.lint_enabled=always, DESIGN.md present, no staged files
# When:  design-md-lint.sh is called from a clean git state
# Then:  exits 0
test_no_staged_files_exits_zero() {
    local tmp_dir config_file design_file exit_code output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"
    design_file="${tmp_dir}/design.md"

    make_lint_config "$config_file" "always"
    make_design_notes "$design_file"

    # Run in a fresh git repo with no staged files
    local git_dir
    git_dir=$(make_tmpdir)
    git -C "$git_dir" init -q 2>/dev/null

    exit_code=0
    output=$(
        cd "$git_dir" && \
        DSO_CONFIG_PATH="$config_file" \
        DESIGN_MD_NOTES_PATH="$design_file" \
        PROJECT_ROOT="$git_dir" \
        bash "$TARGET_SCRIPT" 2>&1
    ) || exit_code=$?
    assert_eq "no_staged_files_exits_zero" "0" "$exit_code"
    assert_contains "no_staged_files_skip_message" "No staged files" "$output"
}

# ── Case 5: auto mode skips when no UI files staged ──────────────────────────
# Given: design.lint_enabled=auto, a non-UI file staged
# When:  design-md-lint.sh is called
# Then:  exits 0 (auto resolved to disabled)
test_auto_mode_skips_without_ui_files() {
    local tmp_dir config_file design_file fake_bin exit_code output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"
    design_file="${tmp_dir}/design.md"
    fake_bin="${tmp_dir}/bin"
    mkdir -p "$fake_bin"

    make_lint_config "$config_file" "auto"
    make_design_notes "$design_file"
    make_fake_npx "$fake_bin" 0 0

    # Set up a git repo with a non-UI file staged
    local git_dir
    git_dir=$(make_tmpdir)
    git -C "$git_dir" init -q 2>/dev/null
    git -C "$git_dir" config user.email "test@test.com"
    git -C "$git_dir" config user.name "Test"
    printf 'config value\n' > "$git_dir/config.yaml"
    git -C "$git_dir" add config.yaml 2>/dev/null

    exit_code=0
    output=$(
        cd "$git_dir" && \
        DSO_CONFIG_PATH="$config_file" \
        DESIGN_MD_NOTES_PATH="$design_file" \
        PROJECT_ROOT="$git_dir" \
        PATH="$fake_bin:$PATH" \
        bash "$TARGET_SCRIPT" 2>&1
    ) || exit_code=$?
    assert_eq "auto_no_ui_files_exits_zero" "0" "$exit_code"
    assert_contains "auto_no_ui_files_skip_message" "no UI files detected" "$output"
}

# ── Case 6: auto mode enables lint when UI files staged ──────────────────────
# Given: design.lint_enabled=auto, a UI file staged (*.tsx)
# When:  design-md-lint.sh is called with fake npx (0 errors)
# Then:  exits 0 and lint ran
test_auto_mode_enables_with_ui_files() {
    local tmp_dir config_file design_file fake_bin exit_code output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"
    design_file="${tmp_dir}/design.md"
    fake_bin="${tmp_dir}/bin"
    mkdir -p "$fake_bin"

    make_lint_config "$config_file" "auto"
    make_design_notes "$design_file"
    make_fake_npx "$fake_bin" 0 0

    # Set up a git repo with a UI file (tsx) staged
    local git_dir
    git_dir=$(make_tmpdir)
    git -C "$git_dir" init -q 2>/dev/null
    git -C "$git_dir" config user.email "test@test.com"
    git -C "$git_dir" config user.name "Test"
    printf 'export const Button = () => <button>Click</button>;\n' > "$git_dir/Button.tsx"
    git -C "$git_dir" add Button.tsx 2>/dev/null

    exit_code=0
    output=$(
        cd "$git_dir" && \
        DSO_CONFIG_PATH="$config_file" \
        DESIGN_MD_NOTES_PATH="$design_file" \
        PROJECT_ROOT="$git_dir" \
        PATH="$fake_bin:$PATH" \
        bash "$TARGET_SCRIPT" 2>&1
    ) || exit_code=$?
    assert_eq "auto_ui_files_exits_zero_when_no_errors" "0" "$exit_code"
}

# ── Case 7 [test_design_md_lint_diff_scoping]: diff-scoped lines only ─────────
# Given: design.lint_enabled=always, file staged with changes to lines 1-3
#        fake npx reports 0 errors (simulating untouched violations out of scope)
# When:  design-md-lint.sh is called
# Then:  exits 0 (no errors in diff-touched lines)
#
# This is the RED marker test [test_design_md_lint_diff_scoping] for:
#   scripts/design-md-lint.sh
test_design_md_lint_diff_scoping() {
    local tmp_dir config_file design_file fake_bin exit_code output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"
    design_file="${tmp_dir}/design.md"
    fake_bin="${tmp_dir}/bin"
    mkdir -p "$fake_bin"

    make_lint_config "$config_file" "always"
    make_design_notes "$design_file"
    # Fake npx returns 0 errors — simulating no violations in diff-touched lines
    make_fake_npx "$fake_bin" 0 0

    # Set up a git repo with a committed file, then stage a small change
    local git_dir
    git_dir=$(make_tmpdir)
    git -C "$git_dir" init -q 2>/dev/null
    git -C "$git_dir" config user.email "test@test.com"
    git -C "$git_dir" config user.name "Test"

    # Initial commit (lines 4-10 have "violations" that are pre-existing)
    printf 'line1\nline2\nline3\nviolation4\nviolation5\nviolation6\nline7\n' > "$git_dir/component.tsx"
    git -C "$git_dir" add component.tsx 2>/dev/null
    git -C "$git_dir" commit -qm "initial" 2>/dev/null

    # Stage a change to only lines 1-3 (not lines 4-6 where violations live)
    printf 'CHANGED1\nCHANGED2\nCHANGED3\nviolation4\nviolation5\nviolation6\nline7\n' > "$git_dir/component.tsx"
    git -C "$git_dir" add component.tsx 2>/dev/null

    exit_code=0
    output=$(
        cd "$git_dir" && \
        DSO_CONFIG_PATH="$config_file" \
        DESIGN_MD_NOTES_PATH="$design_file" \
        PROJECT_ROOT="$git_dir" \
        PATH="$fake_bin:$PATH" \
        bash "$TARGET_SCRIPT" 2>&1
    ) || exit_code=$?
    # Untouched violations (lines 4-6) must not cause non-zero exit
    assert_eq "diff_scoping_no_errors_in_touched_lines_exits_zero" "0" "$exit_code"
}

# ── Case 8: non-zero exit when errors in diff-touched lines ──────────────────
# Given: design.lint_enabled=always, file staged, fake npx reports 2 errors
# When:  design-md-lint.sh is called
# Then:  exits non-zero and prints error message
test_exits_nonzero_on_errors_in_diff_touched_lines() {
    local tmp_dir config_file design_file fake_bin exit_code output
    tmp_dir=$(make_tmpdir)
    config_file="${tmp_dir}/dso-config.conf"
    design_file="${tmp_dir}/design.md"
    fake_bin="${tmp_dir}/bin"
    mkdir -p "$fake_bin"

    make_lint_config "$config_file" "always"
    make_design_notes "$design_file"
    # Fake npx reports 2 errors
    make_fake_npx "$fake_bin" 2 0

    # Set up a git repo with a staged UI file
    local git_dir
    git_dir=$(make_tmpdir)
    git -C "$git_dir" init -q 2>/dev/null
    git -C "$git_dir" config user.email "test@test.com"
    git -C "$git_dir" config user.name "Test"
    printf 'const bad = () => <div style={{color:"red"}}>text</div>;\n' > "$git_dir/Button.tsx"
    git -C "$git_dir" add Button.tsx 2>/dev/null

    exit_code=0
    output=$(
        cd "$git_dir" && \
        DSO_CONFIG_PATH="$config_file" \
        DESIGN_MD_NOTES_PATH="$design_file" \
        PROJECT_ROOT="$git_dir" \
        PATH="$fake_bin:$PATH" \
        bash "$TARGET_SCRIPT" 2>&1
    ) || exit_code=$?
    assert_ne "errors_in_touched_lines_exits_nonzero" "0" "$exit_code"
    assert_contains "errors_message_shown" "FAIL" "$output"
}

# ── Case 9: config absent defaults to auto (fail-open chain) ─────────────────
# Given: DSO_CONFIG_PATH points to nonexistent file
# When:  design-md-lint.sh is called without staged files
# Then:  exits 0 (no staged files → skip)
test_missing_config_defaults_to_auto() {
    local tmp_dir exit_code output
    tmp_dir=$(make_tmpdir)

    local git_dir
    git_dir=$(make_tmpdir)
    git -C "$git_dir" init -q 2>/dev/null

    exit_code=0
    output=$(
        cd "$git_dir" && \
        DSO_CONFIG_PATH="${tmp_dir}/nonexistent.conf" \
        PROJECT_ROOT="$git_dir" \
        bash "$TARGET_SCRIPT" 2>&1
    ) || exit_code=$?
    assert_eq "missing_config_defaults_auto_exits_zero" "0" "$exit_code"
}

# ── Run all cases ─────────────────────────────────────────────────────────────
test_never_mode_exits_zero
test_npx_absent_exits_zero
test_missing_design_md_exits_zero
test_no_staged_files_exits_zero
test_auto_mode_skips_without_ui_files
test_auto_mode_enables_with_ui_files
test_design_md_lint_diff_scoping
test_exits_nonzero_on_errors_in_diff_touched_lines
test_missing_config_defaults_to_auto

print_summary
