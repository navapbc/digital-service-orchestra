#!/usr/bin/env bash
# tests/scripts/test-dryrun-bridge-rollback-in-worktree.sh
# Behavioral tests for dryrun-bridge-rollback-in-worktree.sh
#
# Tests:
#   1. test_dryrun_requires_cutover_sha        — missing DSO_DRYRUN_CUTOVER_SHA exits 2
#   2. test_dryrun_creates_and_removes_worktree — valid sha → worktree created then removed
#   3. test_dryrun_passes_sha_to_rollback       — DSO_ROLLBACK_CUTOVER_SHA is propagated
#   4. test_dryrun_exits_0_on_success           — valid run → exit 0
#
# Usage: bash tests/scripts/test-dryrun-bridge-rollback-in-worktree.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/plugins/dso/scripts/dryrun-bridge-rollback-in-worktree.sh"

# Shared cleanup
_TMP_DIRS=()
trap 'rm -rf "${_TMP_DIRS[@]}"' EXIT

echo "=== test-dryrun-bridge-rollback-in-worktree.sh ==="

# -- test_dryrun_requires_cutover_sha -----------------------------------------
# Running without DSO_DRYRUN_CUTOVER_SHA set must exit 2.
_snapshot_fail
_rc=0
env -u DSO_DRYRUN_CUTOVER_SHA bash "$SCRIPT" 2>/dev/null || _rc=$?
assert_eq "test_dryrun_requires_cutover_sha exit" "2" "$_rc"
assert_pass_if_clean "test_dryrun_requires_cutover_sha"

# Helper: write a mock git binary that handles `-C <dir>` prefix and routes subcommands.
# The marker file path is injected via MOCK_WORKTREE_MARKER env var at runtime.
_write_mock_git() {
    local dest="$1"
    cat > "$dest/git" <<'GIT_EOF'
#!/usr/bin/env bash
# Strip leading `-C <dir>` pair so subcommand routing is position-independent.
_args=("$@")
_idx=0
while [[ "${_args[$_idx]:-}" == "-C" ]]; do
    _idx=$(( _idx + 2 ))
done
_sub="${_args[$_idx]:-}"
_rest=("${_args[@]:$(( _idx + 1 ))}")

case "$_sub" in
    rev-parse)
        if [[ "${_rest[*]:-}" == *"show-toplevel"* ]]; then
            echo "${DSO_DRYRUN_REPO_ROOT:-/tmp/fake-repo}"
        elif [[ "${_rest[*]:-}" == *"HEAD"* ]]; then
            echo "abc1234deadbeef"
        fi
        exit 0
        ;;
    worktree)
        _wcmd="${_rest[0]:-}"
        if [[ "$_wcmd" == "add" ]]; then
            # Last positional arg is the target path; create it and drop the marker.
            _target="${_rest[-1]}"
            mkdir -p "$_target"
            if [[ -n "${MOCK_WORKTREE_MARKER:-}" ]]; then
                touch "$MOCK_WORKTREE_MARKER"
            fi
            exit 0
        fi
        if [[ "$_wcmd" == "remove" ]]; then
            for _a in "${_rest[@]}"; do
                case "$_a" in --force|--) ;; *) rm -rf "$_a" ;; esac
            done
            exit 0
        fi
        ;;
esac
exit 0
GIT_EOF
    chmod +x "$dest/git"
}

# -- test_dryrun_creates_and_removes_worktree ---------------------------------
# With valid inputs the script must create a throwaway worktree (mock git records
# a marker) and the mock rollback succeeds, so exit 0.
_snapshot_fail
_TMP1="$(mktemp -d)"
_FAKE_REPO1="$(mktemp -d)"
_MARKER1="$_FAKE_REPO1/.worktree-added"
_TMP_DIRS+=("$_TMP1" "$_FAKE_REPO1")

_write_mock_git "$_TMP1"

# Mock rollback-bridge-cutover.sh (injected via DSO_DRYRUN_ROLLBACK_SCRIPT)
_MOCK_ROLLBACK1="$(mktemp /tmp/mock-rollback.XXXXXX)"
cat > "$_MOCK_ROLLBACK1" <<'ROLLBACK_EOF'
#!/usr/bin/env bash
[[ -n "${DSO_ROLLBACK_REPO_ROOT:-}" ]] || { echo "ERROR: DSO_ROLLBACK_REPO_ROOT not set" >&2; exit 1; }
[[ -n "${DSO_ROLLBACK_CUTOVER_SHA:-}" ]] || { echo "ERROR: DSO_ROLLBACK_CUTOVER_SHA not set" >&2; exit 1; }
exit 0
ROLLBACK_EOF
chmod +x "$_MOCK_ROLLBACK1"
_TMP_DIRS+=("$_MOCK_ROLLBACK1")

_rc1=0
MOCK_WORKTREE_MARKER="$_MARKER1" \
DSO_DRYRUN_REPO_ROOT="$_FAKE_REPO1" \
DSO_DRYRUN_CUTOVER_SHA="testsha1" \
DSO_DRYRUN_ROLLBACK_SCRIPT="$_MOCK_ROLLBACK1" \
PATH="$_TMP1:$PATH" \
bash "$SCRIPT" 2>/dev/null || _rc1=$?
assert_eq "test_dryrun_creates_and_removes_worktree exit" "0" "$_rc1"
if [[ -f "$_MARKER1" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: test_dryrun_creates_and_removes_worktree worktree-added marker missing" >&2
fi
assert_pass_if_clean "test_dryrun_creates_and_removes_worktree"

# -- test_dryrun_passes_sha_to_rollback ---------------------------------------
# DSO_ROLLBACK_CUTOVER_SHA passed to rollback script must equal DSO_DRYRUN_CUTOVER_SHA.
_snapshot_fail
_TMP3="$(mktemp -d)"
_FAKE_REPO3="$(mktemp -d)"
_SHA_CAPTURE3="$(mktemp /tmp/sha-capture.XXXXXX)"
_TMP_DIRS+=("$_TMP3" "$_FAKE_REPO3")

_write_mock_git "$_TMP3"

_MOCK_ROLLBACK3="$(mktemp /tmp/mock-rollback.XXXXXX)"
cat > "$_MOCK_ROLLBACK3" <<SHA_ROLLBACK_EOF
#!/usr/bin/env bash
echo "\${DSO_ROLLBACK_CUTOVER_SHA:-}" > "$_SHA_CAPTURE3"
exit 0
SHA_ROLLBACK_EOF
chmod +x "$_MOCK_ROLLBACK3"
_TMP_DIRS+=("$_MOCK_ROLLBACK3")

_rc3=0
DSO_DRYRUN_REPO_ROOT="$_FAKE_REPO3" \
DSO_DRYRUN_CUTOVER_SHA="deadbeef1234" \
DSO_DRYRUN_ROLLBACK_SCRIPT="$_MOCK_ROLLBACK3" \
PATH="$_TMP3:$PATH" \
bash "$SCRIPT" 2>/dev/null || _rc3=$?

_captured_sha="$(cat "$_SHA_CAPTURE3" 2>/dev/null | tr -d '[:space:]' || true)"
rm -f "$_SHA_CAPTURE3"
assert_eq "test_dryrun_passes_sha_to_rollback sha" "deadbeef1234" "$_captured_sha"
assert_pass_if_clean "test_dryrun_passes_sha_to_rollback"

# -- test_dryrun_exits_0_on_success -------------------------------------------
# A fully valid run exits 0 and prints "DRYRUN OK".
_snapshot_fail
_TMP4="$(mktemp -d)"
_FAKE_REPO4="$(mktemp -d)"
_TMP_DIRS+=("$_TMP4" "$_FAKE_REPO4")

_write_mock_git "$_TMP4"

_MOCK_ROLLBACK4="$(mktemp /tmp/mock-rollback.XXXXXX)"
cat > "$_MOCK_ROLLBACK4" <<'ROLLBACK_EOF'
#!/usr/bin/env bash
exit 0
ROLLBACK_EOF
chmod +x "$_MOCK_ROLLBACK4"
_TMP_DIRS+=("$_MOCK_ROLLBACK4")

_rc4=0
_out4=""
_out4="$(DSO_DRYRUN_REPO_ROOT="$_FAKE_REPO4" \
DSO_DRYRUN_CUTOVER_SHA="goodsha999" \
DSO_DRYRUN_ROLLBACK_SCRIPT="$_MOCK_ROLLBACK4" \
PATH="$_TMP4:$PATH" \
bash "$SCRIPT" 2>&1)" || _rc4=$?
assert_eq "test_dryrun_exits_0_on_success exit" "0" "$_rc4"
assert_contains "test_dryrun_exits_0_on_success output" "DRYRUN OK" "$_out4"
assert_pass_if_clean "test_dryrun_exits_0_on_success"

print_summary
