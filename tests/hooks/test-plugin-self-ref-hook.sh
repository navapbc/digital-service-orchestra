#!/usr/bin/env bash
# tests/hooks/test-plugin-self-ref-hook.sh
# RED tests for check-plugin-self-ref.sh — the pre-commit hook that blocks
# any file under plugins/dso/ from containing "plugins/dso" strings.
#
# Key design: there is NO suppression mechanism. No annotation, no allowlist,
# no grep -v pass-through. Any occurrence of "plugins/dso" in any file under
# plugins/dso/ is a blocking violation — absolute zero.
#
# Tests use a temp git repo to simulate staged files, then invoke the hook
# with GIT_DIR pointed at that repo.
#
# RED TEST: This test targets check-plugin-self-ref.sh which does NOT exist
# yet — it will be created by GREEN task 4ea4-5faf. All tests are expected
# to FAIL until the hook is implemented. This is separate from the existing
# check-plugin-boundary.sh hook (which supports annotations — being replaced).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)"

HOOK="$REPO_ROOT/.claude/hooks/pre-commit/check-plugin-self-ref.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a fresh isolated git repo ─────────────────────────────────
make_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    echo "initial" > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Test 1: Unannotated plugins/dso string in file under plugins/dso/ blocks ──
# Given: a staged file under plugins/dso/ containing "plugins/dso"
# When: the hook runs
# Then: it exits non-zero (blocks the commit)
test_unannotated_blocks() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: hook not found at %s — cannot test blocking behavior\n" "$HOOK" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        mkdir -p "plugins/dso/scripts"
        # File contains a reference to plugins/dso — must be blocked
        echo 'HOOK_PATH="plugins/dso/hooks/my-hook.sh"' > "plugins/dso/scripts/example.sh"
        git add "plugins/dso/scripts/example.sh"
        bash "$HOOK" 2>&1
    ) || exit_code=$?

    assert_ne "hook blocks staged file under plugins/dso/ containing plugins/dso string" "0" "$exit_code"
}

# ── Test 2: File outside plugins/dso/ containing plugins/dso is ignored ──────
# Given: a staged file in tests/ containing "plugins/dso"
# When: the hook runs
# Then: it exits 0 (no block — file is outside plugins/dso/)
test_outside_plugins_dso_ignored() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: hook not found at %s — cannot test outside-scope behavior\n" "$HOOK" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        mkdir -p "tests"
        # File contains plugins/dso but is NOT under plugins/dso/
        echo 'source plugins/dso/hooks/lib/merge-state.sh' > "tests/test-example.sh"
        git add "tests/test-example.sh"
        bash "$HOOK" 2>&1
    ) || exit_code=$?

    assert_eq "hook ignores files outside plugins/dso/ even if they reference plugins/dso" "0" "$exit_code"
}

# ── Test 3: Clean file under plugins/dso/ passes ────────────────────────────
# Given: a staged file under plugins/dso/ with NO "plugins/dso" string
# When: the hook runs
# Then: it exits 0
test_clean_file_passes() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: hook not found at %s — cannot test clean file behavior\n" "$HOOK" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        mkdir -p "plugins/dso/scripts"
        # File does NOT contain "plugins/dso"
        echo '#!/usr/bin/env bash' > "plugins/dso/scripts/clean-tool.sh"
        echo 'echo "hello world"' >> "plugins/dso/scripts/clean-tool.sh"
        git add "plugins/dso/scripts/clean-tool.sh"
        bash "$HOOK" 2>&1
    ) || exit_code=$?

    assert_eq "hook exits 0 for clean file under plugins/dso/" "0" "$exit_code"
}

# ── Test 4: Error message includes file, line number, and fix guidance ───────
# Given: a staged file under plugins/dso/ containing "plugins/dso"
# When: the hook blocks
# Then: output contains the filename, a line number, and guidance text
test_error_message_actionable() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: hook not found at %s — cannot test error message\n" "$HOOK" >&2
        return
    fi

    local test_repo
    test_repo=$(make_test_repo)

    local exit_code=0
    local output
    output=$(
        cd "$test_repo"
        mkdir -p "plugins/dso/hooks"
        echo 'source plugins/dso/hooks/lib/util.sh' > "plugins/dso/hooks/my-hook.sh"
        git add "plugins/dso/hooks/my-hook.sh"
        bash "$HOOK" 2>&1
    ) || exit_code=$?

    # Should have blocked
    assert_ne "hook blocks for actionable error test" "0" "$exit_code"
    # Output must contain the filename
    assert_contains "error output contains filename" "plugins/dso/hooks/my-hook.sh" "$output"
    # Output must contain a line number (digit followed by colon, or "line N")
    if echo "$output" | grep -qE '(:[0-9]+:|line [0-9]+)'; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: error output does not contain a line number\n  output: %s\n" "$output" >&2
    fi
    # Output must contain fix guidance (some instruction text)
    if echo "$output" | grep -qiE '(fix|remove|replace|use.*instead|must not)'; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: error output does not contain fix guidance\n  output: %s\n" "$output" >&2
    fi
}

# ── Test 5: No suppression mechanism in hook source ─────────────────────────
# Given: the hook source file exists
# When: we inspect it for pass-through/suppression patterns
# Then: it contains NO grep -v, NO annotation bypass, NO "plugin-self-ref-ok"
test_no_suppression_mechanism() {
    if [[ ! -f "$HOOK" ]]; then
        (( ++FAIL ))
        printf "FAIL: hook not found at %s — cannot verify no-suppression invariant\n" "$HOOK" >&2
        return
    fi

    local hook_source
    hook_source=$(<"$HOOK")

    # Must NOT contain grep -v (used for filtering out annotated lines)
    if echo "$hook_source" | grep -q 'grep -v'; then
        (( ++FAIL ))
        printf "FAIL: hook contains 'grep -v' — potential suppression mechanism\n" >&2
    else
        (( ++PASS ))
    fi

    # Must NOT contain any annotation bypass pattern
    if echo "$hook_source" | grep -qi 'plugin-self-ref-ok'; then
        (( ++FAIL ))
        printf "FAIL: hook contains 'plugin-self-ref-ok' annotation — suppression exists\n" >&2
    else
        (( ++PASS ))
    fi

    # Must NOT contain any allowlist or whitelist mechanism
    if echo "$hook_source" | grep -qi 'allowlist\|whitelist\|passthrough\|pass-through\|suppress\|skip.*annotation'; then
        (( ++FAIL ))
        printf "FAIL: hook contains allowlist/whitelist/suppression mechanism\n" >&2
    else
        (( ++PASS ))
    fi
}

# ── Test 6: Hook file exists and is executable ──────────────────────────────
test_hook_exists_and_executable() {
    if [[ -f "$HOOK" ]]; then
        (( ++PASS ))
        echo "PASS: hook file exists at $HOOK"
    else
        (( ++FAIL ))
        printf "FAIL: hook file not found at %s\n" "$HOOK" >&2
    fi

    if [[ -x "$HOOK" ]]; then
        (( ++PASS ))
        echo "PASS: hook file is executable"
    else
        (( ++FAIL ))
        printf "FAIL: hook file is not executable: %s\n" "$HOOK" >&2
    fi
}

# ── Run all tests ────────────────────────────────────────────────────────────
echo "=== test-plugin-self-ref-hook ==="
echo ""

echo "--- Test 1: unannotated plugins/dso string blocks ---"
test_unannotated_blocks
echo ""

echo "--- Test 2: file outside plugins/dso/ is ignored ---"
test_outside_plugins_dso_ignored
echo ""

echo "--- Test 3: clean file under plugins/dso/ passes ---"
test_clean_file_passes
echo ""

echo "--- Test 4: error message is actionable ---"
test_error_message_actionable
echo ""

echo "--- Test 5: no suppression mechanism in hook source ---"
test_no_suppression_mechanism
echo ""

echo "--- Test 6: hook file exists and is executable ---"
test_hook_exists_and_executable
echo ""

print_summary
