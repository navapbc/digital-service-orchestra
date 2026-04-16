#!/usr/bin/env bash
# tests/hooks/test-shellcheck-hook.sh
# Behavioral tests for .claude/hooks/pre-commit/shellcheck.sh
#
# Tests:
#   test_shellcheck_exits_0_no_staged_files: exits 0 when no .sh files are staged
#   test_shellcheck_exits_0_clean_script: exits 0 when staged .sh file passes shellcheck
#   test_shellcheck_exits_1_violation: exits 1 when staged .sh file has shellcheck warnings
#   test_shellcheck_skips_gracefully_when_not_installed: exits 0 when shellcheck unavailable
#
# Usage: bash tests/hooks/test-shellcheck-hook.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/.claude/hooks/pre-commit/shellcheck.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

_make_git_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    git -C "$tmpdir" init -q -b main 2>/dev/null || git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    echo "init" > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Test 1: exits 0 when no .sh files are staged ─────────────────────────────
echo "--- test_shellcheck_exits_0_no_staged_files ---"
test_shellcheck_exits_0_no_staged_files() {
    local repo
    repo=$(_make_git_repo)
    # Stage a non-.sh file
    echo "hello" > "$repo/notes.txt"
    git -C "$repo" add notes.txt

    local exit_code=0
    (cd "$repo" && bash "$HOOK" 2>/dev/null) || exit_code=$?
    rm -rf "$repo"

    assert_eq "test_shellcheck_exits_0_no_staged_files: exit 0" "0" "$exit_code"
}
test_shellcheck_exits_0_no_staged_files

# ── Test 2: exits 0 for a clean script ───────────────────────────────────────
echo "--- test_shellcheck_exits_0_clean_script ---"
test_shellcheck_exits_0_clean_script() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        assert_eq "test_shellcheck_exits_0_clean_script: shellcheck available" "available" "not-installed (skipping)"
        return
    fi

    local repo
    repo=$(_make_git_repo)

    # Write a shellcheck-clean script
    cat > "$repo/clean.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "hello"
EOF
    chmod +x "$repo/clean.sh"
    git -C "$repo" add clean.sh

    local exit_code=0
    (cd "$repo" && bash "$HOOK" 2>/dev/null) || exit_code=$?
    rm -rf "$repo"

    assert_eq "test_shellcheck_exits_0_clean_script: exit 0" "0" "$exit_code"
}
test_shellcheck_exits_0_clean_script

# ── Test 3: exits 1 for a script with shellcheck violations ──────────────────
echo "--- test_shellcheck_exits_1_violation ---"
test_shellcheck_exits_1_violation() {
    if ! command -v shellcheck >/dev/null 2>&1; then
        assert_eq "test_shellcheck_exits_1_violation: shellcheck available" "available" "not-installed (skipping)"
        return
    fi

    local repo
    repo=$(_make_git_repo)

    # Write a script with a known shellcheck warning (SC2086: unquoted variable)
    cat > "$repo/bad.sh" <<'EOF'
#!/usr/bin/env bash
VAR="hello world"
echo $VAR
EOF
    chmod +x "$repo/bad.sh"
    git -C "$repo" add bad.sh

    local exit_code=0
    (cd "$repo" && bash "$HOOK" 2>/dev/null) || exit_code=$?
    rm -rf "$repo"

    assert_eq "test_shellcheck_exits_1_violation: exit 1" "1" "$exit_code"
}
test_shellcheck_exits_1_violation

# ── Test 4: skips gracefully when shellcheck not installed ───────────────────
echo "--- test_shellcheck_skips_gracefully_when_not_installed ---"
test_shellcheck_skips_gracefully_when_not_installed() {
    local repo
    repo=$(_make_git_repo)

    cat > "$repo/script.sh" <<'EOF'
#!/usr/bin/env bash
echo $UNQUOTED
EOF
    chmod +x "$repo/script.sh"
    git -C "$repo" add script.sh

    local exit_code=0 _no_shellcheck_path _bash_bin
    _bash_bin=$(command -v bash)
    _no_shellcheck_path=$(mktemp -d)
    # Symlink bash into the empty dir — bash PATH lookup applies the temporary
    # assignment before finding the command, so bash must be findable in the test PATH.
    [[ -n "$_bash_bin" ]] && ln -sf "$_bash_bin" "$_no_shellcheck_path/bash"
    # Override PATH so shellcheck is never found regardless of OS
    (cd "$repo" && PATH="$_no_shellcheck_path" bash "$HOOK" 2>/dev/null) || exit_code=$?
    rm -rf "$repo" "$_no_shellcheck_path"

    assert_eq "test_shellcheck_skips_gracefully_when_not_installed: exit 0" "0" "$exit_code"
}
test_shellcheck_skips_gracefully_when_not_installed

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
