#!/usr/bin/env bash
# tests/scripts/test-reachability-helper.sh
# Behavioral tests for plugins/dso/scripts/lib/reachability.sh — bug 8a77 v2.
#
# Locks the contract of assert_sha_reachable() that the verifier (and other
# call sites) depend on:
#   - reachable SHA returns 0, no stderr
#   - unreachable SHA returns 4 with descriptive stderr containing the
#     three documented hint lines
#   - the <label> argument appears in error output (callers identify which
#     SHA failed: BASE_SHA vs SESSION_HEAD vs other)
#
# Usage: bash tests/scripts/test-reachability-helper.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED marker: [test_reachability_helper]
# Target:     plugins/dso/scripts/lib/reachability.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/plugins/dso/scripts/lib/reachability.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-reachability-helper.sh ==="

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ── Helper: create a minimal git repo with one commit; echo its path ─────────
_setup_git_repo() {
    local repo
    repo="$(mktemp -d "$TMPDIR_TEST/repo.XXXXXX")"
    git init -q "$repo"
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name Test
    echo "content" > "$repo/file.txt"
    git -C "$repo" add file.txt
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# ── Test 1: reachable SHA returns 0 ───────────────────────────────────────────
test_assert_sha_reachable_pass() {
    _snapshot_fail
    if [[ ! -f "$HELPER" ]]; then
        assert_eq "test_assert_sha_reachable_pass: helper must exist" \
            "helper_exists" "helper_missing"
        assert_pass_if_clean "test_assert_sha_reachable_pass"
        return
    fi

    local repo
    repo="$(_setup_git_repo)"
    local sha
    sha="$(git -C "$repo" rev-parse HEAD)"

    # Source helper in a subshell to isolate
    local rc=99
    (
        set +e
        # shellcheck source=/dev/null
        source "$HELPER"
        assert_sha_reachable "$sha" "TEST_LABEL" "$repo"
        exit $?
    )
    rc=$?

    assert_eq "test_assert_sha_reachable_pass: reachable SHA returns 0" \
        "0" "$rc"

    rm -rf "$repo"
    assert_pass_if_clean "test_assert_sha_reachable_pass"
}

# ── Test 2: unreachable SHA returns 4 with hints in stderr ────────────────────
test_assert_sha_reachable_fail() {
    _snapshot_fail
    if [[ ! -f "$HELPER" ]]; then
        assert_eq "test_assert_sha_reachable_fail: helper must exist" \
            "helper_exists" "helper_missing"
        assert_pass_if_clean "test_assert_sha_reachable_fail"
        return
    fi

    local repo
    repo="$(_setup_git_repo)"
    local stderr_file
    stderr_file="$(mktemp "$TMPDIR_TEST/stderr.XXXXXX")"

    local rc=99
    (
        set +e
        # shellcheck source=/dev/null
        source "$HELPER"
        assert_sha_reachable "0000000000000000000000000000000000000099" "TEST_LABEL" "$repo" 2>"$stderr_file"
        exit $?
    )
    rc=$?

    assert_eq "test_assert_sha_reachable_fail: unreachable SHA returns 4" \
        "4" "$rc"

    local stderr_content
    stderr_content="$(cat "$stderr_file")"
    # 3 hint lines per v2 Change G
    assert_contains "test_assert_sha_reachable_fail: stderr contains hint 1 (actions/checkout)" \
        "actions/checkout" "$stderr_content"
    assert_contains "test_assert_sha_reachable_fail: stderr contains hint 2 (fetch-depth)" \
        "fetch-depth" "$stderr_content"
    assert_contains "test_assert_sha_reachable_fail: stderr contains hint 3 (git fetch)" \
        "git fetch" "$stderr_content"

    rm -rf "$repo" "$stderr_file"
    assert_pass_if_clean "test_assert_sha_reachable_fail"
}

# ── Test 3: custom label appears in error output ──────────────────────────────
test_assert_sha_reachable_uses_label() {
    _snapshot_fail
    if [[ ! -f "$HELPER" ]]; then
        assert_eq "test_assert_sha_reachable_uses_label: helper must exist" \
            "helper_exists" "helper_missing"
        assert_pass_if_clean "test_assert_sha_reachable_uses_label"
        return
    fi

    local repo
    repo="$(_setup_git_repo)"
    local stderr_file
    stderr_file="$(mktemp "$TMPDIR_TEST/stderr-label.XXXXXX")"

    (
        set +e
        # shellcheck source=/dev/null
        source "$HELPER"
        assert_sha_reachable "0000000000000000000000000000000000000099" "MY_CUSTOM_LABEL_XYZ" "$repo" 2>"$stderr_file"
        exit $?
    )

    local stderr_content
    stderr_content="$(cat "$stderr_file")"
    assert_contains "test_assert_sha_reachable_uses_label: custom label appears in stderr" \
        "MY_CUSTOM_LABEL_XYZ" "$stderr_content"

    rm -rf "$repo" "$stderr_file"
    assert_pass_if_clean "test_assert_sha_reachable_uses_label"
}

# ── Test 4: verifier exits 4 when helper is absent ────────────────────────────
# Negative test: if the lib/reachability.sh helper is missing, the verifier
# must fail loudly with exit 4 (not silently fall through). This guards
# against regression where the source line is removed or path drifts.
test_verifier_exits_4_when_helper_missing() {
    _snapshot_fail
    local verifier="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"
    if [[ ! -f "$verifier" ]]; then
        assert_eq "test_verifier_exits_4_when_helper_missing: verifier must exist" \
            "verifier_exists" "verifier_missing"
        assert_pass_if_clean "test_verifier_exits_4_when_helper_missing"
        return
    fi

    # Copy the verifier into a temp dir WITHOUT the lib/ helper next to it
    local tmp_scripts
    tmp_scripts="$(mktemp -d "$TMPDIR_TEST/no-helper.XXXXXX")"
    cp "$verifier" "$tmp_scripts/verify-session-provenance.sh"
    # Deliberately do NOT copy lib/reachability.sh

    local repo
    repo="$(_setup_git_repo)"
    local sha
    sha="$(git -C "$repo" rev-parse HEAD)"

    local artifact_dir
    artifact_dir="$(mktemp -d "$TMPDIR_TEST/artifact.XXXXXX")"
    local stderr_file
    stderr_file="$(mktemp "$TMPDIR_TEST/no-helper-stderr.XXXXXX")"

    local rc=99
    DSO_REPO_PATH="$repo" \
    DSO_BASE_SHA="$sha" \
    DSO_SESSION_HEAD="$sha" \
    DSO_ARTIFACT_DIR="$artifact_dir" \
        bash "$tmp_scripts/verify-session-provenance.sh" > /dev/null 2>"$stderr_file"
    rc=$?

    assert_eq "test_verifier_exits_4_when_helper_missing: missing helper → exit 4" \
        "4" "$rc"

    local stderr_content
    stderr_content="$(cat "$stderr_file")"
    assert_contains "test_verifier_exits_4_when_helper_missing: stderr mentions missing helper" \
        "not found" "$stderr_content"

    rm -rf "$repo" "$artifact_dir" "$tmp_scripts" "$stderr_file"
    assert_pass_if_clean "test_verifier_exits_4_when_helper_missing"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_assert_sha_reachable_pass
test_assert_sha_reachable_fail
test_assert_sha_reachable_uses_label
test_verifier_exits_4_when_helper_missing

print_summary
