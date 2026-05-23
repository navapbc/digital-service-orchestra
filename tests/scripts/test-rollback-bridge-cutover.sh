#!/usr/bin/env bash
# tests/scripts/test-rollback-bridge-cutover.sh
# Behavioral tests for plugins/dso/scripts/rollback-bridge-cutover.sh
#
# Tests:
#   1. test_requires_CUTOVER_SHA             — missing DSO_ROLLBACK_CUTOVER_SHA exits 2
#   2. test_revert_step_fails_on_bad_sha     — git revert failure exits 1
#   3. test_skips_cursor_restore_when_no_snapshot — empty bootstrap dir; exits 0 with WARN
#   4. test_ci_verification_fails_exits_1    — gh run watch failure exits 1
#
# Usage: bash tests/scripts/test-rollback-bridge-cutover.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/rollback-bridge-cutover.sh"

# Shared cleanup
_TMP_DIRS=()
trap '[[ ${#_TMP_DIRS[@]} -gt 0 ]] && rm -rf "${_TMP_DIRS[@]}"' EXIT

echo "=== test-rollback-bridge-cutover.sh ==="

# -- test_requires_CUTOVER_SHA ------------------------------------------------
# Running without DSO_ROLLBACK_CUTOVER_SHA set must exit 2.
_snapshot_fail
_rc=0
env -u DSO_ROLLBACK_CUTOVER_SHA bash "$SCRIPT" 2>/dev/null || _rc=$?
assert_eq "test_requires_CUTOVER_SHA exit" "2" "$_rc"
assert_pass_if_clean "test_requires_CUTOVER_SHA"

# -- test_revert_step_fails_on_bad_sha ----------------------------------------
# When `git revert` returns non-zero, the script must exit 1.
_snapshot_fail
_TMP1="$(mktemp -d)"
_FAKEROOT1="$(mktemp -d)"
_TMP_DIRS+=("$_TMP1" "$_FAKEROOT1")

cat > "$_TMP1/git" <<'GIT_EOF'
#!/usr/bin/env bash
if [[ "$*" == *"revert"* ]]; then
    echo "error: bad object bad-sha" >&2
    exit 128
fi
if [[ "$*" == *"rev-parse"* ]]; then
    exit 0
fi
echo "mock-git $*"
exit 0
GIT_EOF
chmod +x "$_TMP1/git"

_rc1=0
DSO_ROLLBACK_REPO_ROOT="$_FAKEROOT1" \
DSO_ROLLBACK_CUTOVER_SHA="bad-sha" \
PATH="$_TMP1:$PATH" \
bash "$SCRIPT" 2>/dev/null || _rc1=$?
assert_eq "test_revert_step_fails_on_bad_sha exit" "1" "$_rc1"
assert_pass_if_clean "test_revert_step_fails_on_bad_sha"

# -- test_skips_cursor_restore_when_no_snapshot --------------------------------
# When bootstrap dir is empty and gh run list returns empty, script exits 0
# and emits WARN about missing snapshot.
_snapshot_fail
_TMP2="$(mktemp -d)"
_FAKEROOT2="$(mktemp -d)"
_TMP_DIRS+=("$_TMP2" "$_FAKEROOT2")

# Create empty bootstrap dir
mkdir -p "$_FAKEROOT2/bridge_state/bootstrap"

cat > "$_TMP2/git" <<'GIT_EOF'
#!/usr/bin/env bash
if [[ "$*" == *"revert"* ]]; then exit 0; fi
if [[ "$*" == *"rev-parse"* ]]; then exit 0; fi
echo "mock-git $*"
exit 0
GIT_EOF
chmod +x "$_TMP2/git"

cat > "$_TMP2/gh" <<'GH_EOF'
#!/usr/bin/env bash
# gh run list returns empty JSON array
if [[ "$*" == *"run list"* ]] || [[ "$*" == *"run"*"list"* ]]; then
    echo "[]"
    exit 0
fi
exit 0
GH_EOF
chmod +x "$_TMP2/gh"

_rc2=0
_out2=""
_out2="$(DSO_ROLLBACK_REPO_ROOT="$_FAKEROOT2" \
DSO_ROLLBACK_CUTOVER_SHA="abc1234" \
PATH="$_TMP2:$PATH" \
bash "$SCRIPT" 2>&1)" || _rc2=$?
assert_eq "test_skips_cursor_restore_when_no_snapshot exit" "0" "$_rc2"
assert_contains "test_skips_cursor_restore_when_no_snapshot warns" "WARN" "$_out2"
assert_pass_if_clean "test_skips_cursor_restore_when_no_snapshot"

# -- test_ci_verification_fails_exits_1 ----------------------------------------
# When gh run watch returns non-zero, the script must exit 1.
_snapshot_fail
_TMP3="$(mktemp -d)"
_FAKEROOT3="$(mktemp -d)"
_TMP_DIRS+=("$_TMP3" "$_FAKEROOT3")

# Create empty bootstrap dir (no snapshot — so Step 2 is a no-op WARN)
mkdir -p "$_FAKEROOT3/bridge_state/bootstrap"

cat > "$_TMP3/git" <<'GIT_EOF'
#!/usr/bin/env bash
if [[ "$*" == *"revert"* ]]; then exit 0; fi
if [[ "$*" == *"rev-parse"* ]]; then exit 0; fi
echo "mock-git $*"
exit 0
GIT_EOF
chmod +x "$_TMP3/git"

cat > "$_TMP3/gh" <<'GH_EOF'
#!/usr/bin/env bash
# gh run list returns a URL so the watch branch is entered
if [[ "$*" == *"run list"* ]] || [[ "$*" == *"run"*"list"* ]]; then
    echo "https://github.com/example/repo/actions/runs/12345"
    exit 0
fi
# gh run watch fails (simulates CI failure)
if [[ "$*" == *"run watch"* ]] || [[ "$*" == *"run"*"watch"* ]]; then
    echo "Run failed" >&2
    exit 1
fi
exit 0
GH_EOF
chmod +x "$_TMP3/gh"

_rc3=0
DSO_ROLLBACK_REPO_ROOT="$_FAKEROOT3" \
DSO_ROLLBACK_CUTOVER_SHA="abc1234" \
PATH="$_TMP3:$PATH" \
bash "$SCRIPT" 2>/dev/null || _rc3=$?
assert_eq "test_ci_verification_fails_exits_1 exit" "1" "$_rc3"
assert_pass_if_clean "test_ci_verification_fails_exits_1"

print_summary
