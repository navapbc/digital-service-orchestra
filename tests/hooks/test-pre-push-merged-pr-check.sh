#!/usr/bin/env bash
# tests/hooks/test-pre-push-merged-pr-check.sh
# Behavioral tests for plugins/dso/hooks/pre-push-merged-pr-check.sh.
#
# Stubs `gh` on PATH to control reported PR state and asserts exit code +
# stderr content for each branch state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$REPO_ROOT/plugins/dso/hooks/pre-push-merged-pr-check.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-pre-push-merged-pr-check.sh ==="

# A throwaway git repo with one commit on a named branch so the hook has a
# branch name to query. The test does not care about ref names — only about
# the gh stub's response — but having a real branch lets git rev-parse work.
_setup_repo() {
    local d
    d=$(mktemp -d)
    git -C "$d" init -q
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    printf "x\n" > "$d/x.txt"
    git -C "$d" add x.txt
    git -C "$d" commit -q -m "init"
    git -C "$d" branch -M test-branch
    echo "$d"
}

_make_gh_stub() {
    local dir="$1" state="$2"
    cat > "$dir/gh" <<GHEOF
#!/usr/bin/env bash
# Detect '--json state -q .state' invocations and emit \$state.
emit_state=false
for a in "\$@"; do
    [[ "\$a" == ".state" ]] && emit_state=true
done
if \$emit_state; then
    printf '%s\n' "$state"
    exit 0
fi
exit 1
GHEOF
    chmod +x "$dir/gh"
}

# ── test_merged_state_blocks_push ───────────────────────────────────────────
test_merged_state_blocks_push() {
    local repo; repo=$(_setup_repo)
    local stub_dir; stub_dir=$(mktemp -d)
    _make_gh_stub "$stub_dir" "MERGED"

    local exit_code=0
    local stderr
    stderr=$(cd "$repo" && PATH="$stub_dir:$PATH" bash "$HOOK" 2>&1 1>/dev/null) || exit_code=$?

    assert_eq "merged state must block push" "1" "$exit_code"
    assert_contains "stderr names branch and MERGED" "MERGED" "$stderr"
    assert_contains "stderr mentions override env var" "DSO_ALLOW_PUSH_TO_MERGED_PR" "$stderr"

    rm -rf "$repo" "$stub_dir"
}

# ── test_open_state_allows_push ─────────────────────────────────────────────
test_open_state_allows_push() {
    local repo; repo=$(_setup_repo)
    local stub_dir; stub_dir=$(mktemp -d)
    _make_gh_stub "$stub_dir" "OPEN"

    local exit_code=0
    (cd "$repo" && PATH="$stub_dir:$PATH" bash "$HOOK" >/dev/null 2>&1) || exit_code=$?
    assert_eq "open state must allow push" "0" "$exit_code"

    rm -rf "$repo" "$stub_dir"
}

# ── test_closed_state_warns_but_allows ──────────────────────────────────────
test_closed_state_warns_but_allows() {
    local repo; repo=$(_setup_repo)
    local stub_dir; stub_dir=$(mktemp -d)
    _make_gh_stub "$stub_dir" "CLOSED"

    local exit_code=0
    local stderr
    stderr=$(cd "$repo" && PATH="$stub_dir:$PATH" bash "$HOOK" 2>&1 1>/dev/null) || exit_code=$?
    assert_eq "closed (not merged) state must allow push" "0" "$exit_code"
    assert_contains "closed state emits warning" "CLOSED" "$stderr"

    rm -rf "$repo" "$stub_dir"
}

# ── test_no_pr_allows_push ──────────────────────────────────────────────────
test_no_pr_allows_push() {
    local repo; repo=$(_setup_repo)
    local stub_dir; stub_dir=$(mktemp -d)
    # gh returns nothing (exits 1) when no PR is associated with the branch
    cat > "$stub_dir/gh" <<'GHEOF'
#!/usr/bin/env bash
exit 1
GHEOF
    chmod +x "$stub_dir/gh"

    local exit_code=0
    (cd "$repo" && PATH="$stub_dir:$PATH" bash "$HOOK" >/dev/null 2>&1) || exit_code=$?
    assert_eq "no associated PR must not block push" "0" "$exit_code"

    rm -rf "$repo" "$stub_dir"
}

# ── test_override_env_bypasses_check ────────────────────────────────────────
test_override_env_bypasses_check() {
    local repo; repo=$(_setup_repo)
    local stub_dir; stub_dir=$(mktemp -d)
    _make_gh_stub "$stub_dir" "MERGED"

    local exit_code=0
    (cd "$repo" && DSO_ALLOW_PUSH_TO_MERGED_PR=1 PATH="$stub_dir:$PATH" bash "$HOOK" >/dev/null 2>&1) || exit_code=$?
    assert_eq "override env must bypass even on MERGED" "0" "$exit_code"

    rm -rf "$repo" "$stub_dir"
}

# ── test_no_gh_silently_skips ───────────────────────────────────────────────
test_no_gh_silently_skips() {
    local repo; repo=$(_setup_repo)
    # PATH without gh — only /usr/bin:/bin
    local exit_code=0
    (cd "$repo" && PATH="/usr/bin:/bin" bash "$HOOK" >/dev/null 2>&1) || exit_code=$?
    assert_eq "gh absent must not block push" "0" "$exit_code"

    rm -rf "$repo"
}

test_merged_state_blocks_push
test_open_state_allows_push
test_closed_state_warns_but_allows
test_no_pr_allows_push
test_override_env_bypasses_check
test_no_gh_silently_skips

print_summary
