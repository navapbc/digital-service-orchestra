#!/usr/bin/env bash
# tests/scripts/test-rollback-dryrun-e2e.sh
# End-to-end tests for dryrun-bridge-rollback-in-worktree.sh against a real
# fixture git repo with a mocked gh binary and injected rollback script.
#
# Tests:
#   1. test_dryrun_e2e_exits_0_on_success          — full success path exits 0
#   2. test_dryrun_e2e_worktree_removed_after_success — no temp worktrees remain
#   3. test_dryrun_e2e_worktree_removed_after_failure — cleanup runs even on failure
#
# Usage: bash tests/scripts/test-rollback-dryrun-e2e.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/dryrun-bridge-rollback-in-worktree.sh"

# Shared cleanup: all temp dirs registered here are removed on exit.
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]}"' EXIT

echo "=== test-rollback-dryrun-e2e.sh ==="

# ---------------------------------------------------------------------------
# Helper: create a minimal real git fixture repo with one commit.
# Prints the path to the repo root; the commit SHA is written to the variable
# named by the second argument.
#
#   _FIXTURE_REPO="$(_make_fixture_repo)"
#   read -r _CUTOVER_SHA < "$_FIXTURE_REPO/.cutover_sha"
# ---------------------------------------------------------------------------
_make_fixture_repo() {
    local repo
    repo="$(mktemp -d)"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@test.local"
    git -C "$repo" config user.name "Test"
    # Create an initial commit (required so HEAD is valid for worktree add)
    echo "fixture" > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -q -m "initial fixture commit"
    # Record the SHA for use as CUTOVER_SHA
    git -C "$repo" rev-parse HEAD > "$repo/.cutover_sha"
    echo "$repo"
}

# ---------------------------------------------------------------------------
# Helper: write a mock gh binary that returns empty run list (no CI watch).
# Placed in $1/gh.
# ---------------------------------------------------------------------------
_write_mock_gh() {
    local dest="$1"
    cat > "$dest/gh" <<'GH_EOF'
#!/usr/bin/env bash
# gh mock: run list returns empty array so rollback-bridge-cutover skips watch.
if [[ "$*" == *"run list"* ]] || [[ "$*" == *"run"*"list"* ]]; then
    echo "[]"
    exit 0
fi
exit 0
GH_EOF
    chmod +x "$dest/gh"
}

# ---------------------------------------------------------------------------
# Helper: write a mock rollback script that:
#   - validates required env vars
#   - performs a real git revert --no-commit HEAD in DSO_ROLLBACK_REPO_ROOT
#   - creates bridge_state/bootstrap/cursor-snapshot.json marker
#   - exits 0
# Placed at $1.
# ---------------------------------------------------------------------------
_write_mock_rollback_success() {
    local dest="$1"
    cat > "$dest" <<'ROLLBACK_EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -n "${DSO_ROLLBACK_REPO_ROOT:-}" ]] || { echo "ERROR: DSO_ROLLBACK_REPO_ROOT not set" >&2; exit 1; }
[[ -n "${DSO_ROLLBACK_CUTOVER_SHA:-}" ]] || { echo "ERROR: DSO_ROLLBACK_CUTOVER_SHA not set" >&2; exit 1; }
# Perform a real revert so the worktree is actually exercised
cd "$DSO_ROLLBACK_REPO_ROOT"
git revert --no-commit HEAD 2>/dev/null || true
# Create the cursor snapshot marker
mkdir -p bridge_state/bootstrap
echo '{"status":"rollback"}' > bridge_state/bootstrap/cursor-snapshot.json
exit 0
ROLLBACK_EOF
    chmod +x "$dest"
}

# ---------------------------------------------------------------------------
# Helper: write a mock rollback script that always fails (exit 1).
# ---------------------------------------------------------------------------
_write_mock_rollback_failure() {
    local dest="$1"
    cat > "$dest" <<'ROLLBACK_EOF'
#!/usr/bin/env bash
echo "ERROR: mock rollback failure" >&2
exit 1
ROLLBACK_EOF
    chmod +x "$dest"
}

# ===========================================================================
# test_dryrun_e2e_exits_0_on_success
#
# Full success path: real fixture repo + valid CUTOVER_SHA → exit 0 and output
# contains "DRYRUN OK".
# ===========================================================================
_snapshot_fail

_FIXTURE1="$(_make_fixture_repo)"
_CUTOVER_SHA1="$(cat "$_FIXTURE1/.cutover_sha" | tr -d '[:space:]')"
_MOCK_BIN1="$(mktemp -d)"
_MOCK_ROLLBACK1="$(mktemp /tmp/mock-rollback.XXXXXX)"
_TMP_DIRS+=("$_FIXTURE1" "$_MOCK_BIN1" "$_MOCK_ROLLBACK1")

_write_mock_gh "$_MOCK_BIN1"
_write_mock_rollback_success "$_MOCK_ROLLBACK1"

_rc1=0
_out1=""
_out1="$(
    DSO_DRYRUN_REPO_ROOT="$_FIXTURE1" \
    DSO_DRYRUN_CUTOVER_SHA="$_CUTOVER_SHA1" \
    DSO_DRYRUN_ROLLBACK_SCRIPT="$_MOCK_ROLLBACK1" \
    PATH="$_MOCK_BIN1:$PATH" \
    bash "$SCRIPT" 2>&1
)" || _rc1=$?

assert_eq   "test_dryrun_e2e_exits_0_on_success exit"   "0"          "$_rc1"
assert_contains "test_dryrun_e2e_exits_0_on_success output" "DRYRUN OK" "$_out1"
assert_pass_if_clean "test_dryrun_e2e_exits_0_on_success"

# ===========================================================================
# test_dryrun_e2e_worktree_removed_after_success
#
# After a successful run, no throwaway worktree directory should remain.
# We capture the worktree path from the script's mktemp pattern by listing
# worktrees before and after.
# ===========================================================================
_snapshot_fail

_FIXTURE2="$(_make_fixture_repo)"
_CUTOVER_SHA2="$(cat "$_FIXTURE2/.cutover_sha" | tr -d '[:space:]')"
_MOCK_BIN2="$(mktemp -d)"
_MOCK_ROLLBACK2="$(mktemp /tmp/mock-rollback.XXXXXX)"
_TMP_DIRS+=("$_FIXTURE2" "$_MOCK_BIN2" "$_MOCK_ROLLBACK2")

_write_mock_gh "$_MOCK_BIN2"
_write_mock_rollback_success "$_MOCK_ROLLBACK2"

_rc2=0
DSO_DRYRUN_REPO_ROOT="$_FIXTURE2" \
DSO_DRYRUN_CUTOVER_SHA="$_CUTOVER_SHA2" \
DSO_DRYRUN_ROLLBACK_SCRIPT="$_MOCK_ROLLBACK2" \
PATH="$_MOCK_BIN2:$PATH" \
bash "$SCRIPT" 2>/dev/null || _rc2=$?

# After exit, no dryrun-rollback worktrees should remain under /tmp
_leftover_worktrees2="$(git -C "$_FIXTURE2" worktree list --porcelain 2>/dev/null \
    | grep "^worktree " \
    | grep "dryrun-rollback" \
    || true)"

assert_eq "test_dryrun_e2e_worktree_removed_after_success exit"     "0" "$_rc2"
assert_eq "test_dryrun_e2e_worktree_removed_after_success leftover" ""  "$_leftover_worktrees2"
assert_pass_if_clean "test_dryrun_e2e_worktree_removed_after_success"

# ===========================================================================
# test_dryrun_e2e_worktree_removed_after_failure
#
# When the rollback script fails, the throwaway worktree is still cleaned up
# (EXIT trap fires) and the harness exits 1.
# ===========================================================================
_snapshot_fail

_FIXTURE3="$(_make_fixture_repo)"
_CUTOVER_SHA3="$(cat "$_FIXTURE3/.cutover_sha" | tr -d '[:space:]')"
_MOCK_BIN3="$(mktemp -d)"
_MOCK_ROLLBACK3="$(mktemp /tmp/mock-rollback.XXXXXX)"
_TMP_DIRS+=("$_FIXTURE3" "$_MOCK_BIN3" "$_MOCK_ROLLBACK3")

_write_mock_gh "$_MOCK_BIN3"
_write_mock_rollback_failure "$_MOCK_ROLLBACK3"

_rc3=0
DSO_DRYRUN_REPO_ROOT="$_FIXTURE3" \
DSO_DRYRUN_CUTOVER_SHA="$_CUTOVER_SHA3" \
DSO_DRYRUN_ROLLBACK_SCRIPT="$_MOCK_ROLLBACK3" \
PATH="$_MOCK_BIN3:$PATH" \
bash "$SCRIPT" 2>/dev/null || _rc3=$?

# Worktree should be removed despite failure
_leftover_worktrees3="$(git -C "$_FIXTURE3" worktree list --porcelain 2>/dev/null \
    | grep "^worktree " \
    | grep "dryrun-rollback" \
    || true)"

assert_eq "test_dryrun_e2e_worktree_removed_after_failure exit"     "1" "$_rc3"
assert_eq "test_dryrun_e2e_worktree_removed_after_failure leftover" ""  "$_leftover_worktrees3"
assert_pass_if_clean "test_dryrun_e2e_worktree_removed_after_failure"

print_summary
