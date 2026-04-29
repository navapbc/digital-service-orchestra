#!/usr/bin/env bash
# tests/scripts/test-ci-dso-fetch.sh
# Behavioral smoke tests for plugins/dso/scripts/ci-dso-fetch.sh
#
# Tests use env-var overrides documented in the script header.
# All tests mock external dependencies (git clone, git ls-remote,
# resolve-dso-version.sh) so no network access is required.
#
# Tests covered:
#   1. test_fetch_script_exists               — script present and executable
#   2. test_fetch_fails_without_resolver      — exits non-zero when resolver missing
#   3. test_fetch_sentinel_miss_calls_clone   — no sentinel triggers clone path
#   4. test_fetch_sentinel_hit_skips_clone    — valid sentinel + SHA match skips clone
#   5. test_fetch_sentinel_sha_mismatch_reclones — SHA mismatch triggers re-clone
#   6. test_fetch_exports_clone_dir           — CLONE_DIR derived from VERSION
#   7. test_fetch_validates_marketplace_json  — fails when marketplace.json absent
#
# Usage: bash tests/scripts/test-ci-dso-fetch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FETCH_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/ci-dso-fetch.sh"

# shellcheck source=../lib/assert.sh
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ci-dso-fetch.sh ==="

# ── Shared setup ──────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Helper: build a mock resolve-dso-version.sh that emits a fixed VERSION.
_make_mock_resolver() {
    local dir="$1"
    local version="${2:-v1.99.0}"
    local tier="${3:-2}"
    local mock="$dir/resolve-dso-version.sh"
    cat > "$mock" <<EOF
#!/usr/bin/env bash
printf 'RESOLVED_VERSION=%s\n' "$version"
printf 'RESOLVED_TIER=%s\n'    "$tier"
printf 'RESOLVED_SOURCE=%s\n'  "mock-resolver"
exit 0
EOF
    chmod +x "$mock"
    printf '%s' "$mock"
}

# Helper: build a fake git command that stubs clone and ls-remote.
# The fake git binary is placed at $dir/git.
# $clone_exit   — exit code for 'git clone' (default 0)
# $ls_remote_sha — SHA to return for 'git ls-remote' (default "abc123def456")
_make_mock_git() {
    local dir="$1"
    local clone_exit="${2:-0}"
    local ls_remote_sha="${3:-abc123def456}"
    local fake_git="$dir/git"

    # We need CLONE_DIR available inside the fake git for 'clone' to populate it.
    # The fake git reads FAKE_CLONE_DIR env var (set by each test) to know where
    # to create the marketplace.json stub.
    cat > "$fake_git" <<'FAKEGIT'
#!/usr/bin/env bash
subcommand="${1:-}"
case "$subcommand" in
    clone)
        # Last positional arg is the destination directory.
        dest="${@: -1}"
        mkdir -p "$dest/plugins/dso"
        touch "$dest/plugins/dso/marketplace.json"
        exit CLONE_EXIT_PLACEHOLDER
        ;;
    ls-remote)
        echo "LS_REMOTE_SHA_PLACEHOLDER	refs/tags/v1.99.0"
        exit 0
        ;;
    -C)
        # git -C <dir> <subcmd> [args...]
        # Intercept only 'rev-parse HEAD'; forward 'rev-parse --show-toplevel' to real git.
        _c_dir="${2:-}"
        shift 2  # consume -C and <dir>
        _c_sub="${1:-}"
        if [[ "$_c_sub" == "rev-parse" ]]; then
            _c_arg="${2:-}"
            if [[ "$_c_arg" == "HEAD" ]]; then
                echo "LS_REMOTE_SHA_PLACEHOLDER"
                exit 0
            fi
            # --show-toplevel or other rev-parse flags: delegate to real git
            exec /usr/bin/git -C "$_c_dir" "$@"
        fi
        exec /usr/bin/git -C "$_c_dir" "$@"
        ;;
    *)
        # Forward any unrecognised subcommand to real git
        exec /usr/bin/git "$@"
        ;;
esac
FAKEGIT

    # Substitute placeholders now that we know the values.
    sed -i.bak "s/CLONE_EXIT_PLACEHOLDER/$clone_exit/g" "$fake_git"
    sed -i.bak "s/LS_REMOTE_SHA_PLACEHOLDER/$ls_remote_sha/g" "$fake_git"
    rm -f "${fake_git}.bak"
    chmod +x "$fake_git"
    printf '%s' "$dir"
}

# Helper: write a dso-sentinel.json to a directory.
_write_sentinel() {
    local dir="$1" version="$2" sha="$3"
    mkdir -p "$dir"
    python3 -c "
import json, sys
d = {'version': sys.argv[1], 'commit_sha': sys.argv[2]}
with open(sys.argv[3], 'w') as f:
    json.dump(d, f)
    f.write('\n')
" "$version" "$sha" "$dir/dso-sentinel.json"
}

# ── test_fetch_script_exists ──────────────────────────────────────────────────
echo ""
echo "--- test_fetch_script_exists ---"
_snapshot_fail
if [[ -f "$FETCH_SCRIPT" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_fetch_script_exists: file present" "exists" "$actual_exists"

if [[ -x "$FETCH_SCRIPT" ]]; then
    actual_exec="executable"
else
    actual_exec="not-executable"
fi
assert_eq "test_fetch_script_exists: file executable" "executable" "$actual_exec"
assert_pass_if_clean "test_fetch_script_exists"

# ── test_fetch_fails_without_resolver ─────────────────────────────────────────
echo ""
echo "--- test_fetch_fails_without_resolver ---"
_snapshot_fail
rc=0
stderr_out=$(
    RESOLVE_DSO_VERSION_SCRIPT="$TMPDIR_TEST/no-such-resolver.sh" \
    bash "$FETCH_SCRIPT" 2>&1 >/dev/null
) || rc=$?
assert_ne "test_fetch_fails_without_resolver: non-zero exit" "0" "$rc"
assert_contains "test_fetch_fails_without_resolver: error message" \
    "not found" "$stderr_out"
assert_pass_if_clean "test_fetch_fails_without_resolver"

# ── test_fetch_sentinel_miss_calls_clone ──────────────────────────────────────
# No sentinel → clone must be invoked; after success CLONE_DIR/dso-sentinel.json exists.
echo ""
echo "--- test_fetch_sentinel_miss_calls_clone ---"
_snapshot_fail

_t3="$TMPDIR_TEST/t3"
mkdir -p "$_t3"
_mock_resolver3=$(_make_mock_resolver "$_t3" "v1.99.0" "2")
_git_dir3=$(_make_mock_git "$_t3" "0" "deadbeef001")

# No RUNNER_TEMP entry yet — use a fresh base dir so CLONE_DIR is empty.
_runner_temp3="$TMPDIR_TEST/runner3"
mkdir -p "$_runner_temp3"

rc=0
stdout_out=$(
    PATH="$_git_dir3:$PATH" \
    RESOLVE_DSO_VERSION_SCRIPT="$_mock_resolver3" \
    RUNNER_TEMP="$_runner_temp3" \
    CI_DSO_FETCH_SKIP_LS_REMOTE="1" \
    bash "$FETCH_SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_fetch_sentinel_miss_calls_clone: exit 0" "0" "$rc"

_expected_clone_dir="$_runner_temp3/dso/v1.99.0"
_sentinel="$_expected_clone_dir/dso-sentinel.json"
if [[ -f "$_sentinel" ]]; then
    actual_sentinel="exists"
else
    actual_sentinel="missing"
fi
assert_eq "test_fetch_sentinel_miss_calls_clone: sentinel written" "exists" "$actual_sentinel"

assert_pass_if_clean "test_fetch_sentinel_miss_calls_clone"

# ── test_fetch_sentinel_hit_skips_clone ───────────────────────────────────────
# Valid sentinel + SHA match (skip ls-remote) → clone must NOT run again.
# We verify by making the mock git exit 1 for clone — if clone were called,
# the script would fail.
echo ""
echo "--- test_fetch_sentinel_hit_skips_clone ---"
_snapshot_fail

_t4="$TMPDIR_TEST/t4"
mkdir -p "$_t4"
_mock_resolver4=$(_make_mock_resolver "$_t4" "v1.99.0" "2")
# clone exits 1 — if it's called the test will fail
_git_dir4=$(_make_mock_git "$_t4" "1" "deadbeef001")

_runner_temp4="$TMPDIR_TEST/runner4"
_clone_dir4="$_runner_temp4/dso/v1.99.0"
mkdir -p "$_clone_dir4/plugins/dso"
touch "$_clone_dir4/plugins/dso/marketplace.json"
_write_sentinel "$_clone_dir4" "v1.99.0" "deadbeef001"

rc=0
(
    PATH="$_git_dir4:$PATH" \
    RESOLVE_DSO_VERSION_SCRIPT="$_mock_resolver4" \
    RUNNER_TEMP="$_runner_temp4" \
    CI_DSO_FETCH_SKIP_LS_REMOTE="1" \
    bash "$FETCH_SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_fetch_sentinel_hit_skips_clone: exit 0 (clone not invoked)" "0" "$rc"
assert_pass_if_clean "test_fetch_sentinel_hit_skips_clone"

# ── test_fetch_sentinel_sha_mismatch_reclones ─────────────────────────────────
# Sentinel exists but ls-remote returns a different SHA → re-clone triggered.
echo ""
echo "--- test_fetch_sentinel_sha_mismatch_reclones ---"
_snapshot_fail

_t5="$TMPDIR_TEST/t5"
mkdir -p "$_t5"
_mock_resolver5=$(_make_mock_resolver "$_t5" "v1.99.0" "2")
# ls-remote returns "newsha999"; sentinel contains "oldsha111" → mismatch
_git_dir5=$(_make_mock_git "$_t5" "0" "newsha999")

_runner_temp5="$TMPDIR_TEST/runner5"
_clone_dir5="$_runner_temp5/dso/v1.99.0"
mkdir -p "$_clone_dir5"
_write_sentinel "$_clone_dir5" "v1.99.0" "oldsha111"

rc=0
(
    PATH="$_git_dir5:$PATH" \
    RESOLVE_DSO_VERSION_SCRIPT="$_mock_resolver5" \
    RUNNER_TEMP="$_runner_temp5" \
    bash "$FETCH_SCRIPT" 2>/dev/null
) || rc=$?

assert_eq "test_fetch_sentinel_sha_mismatch_reclones: exit 0" "0" "$rc"

_new_sentinel5="$_clone_dir5/dso-sentinel.json"
_new_sha5=""
_new_sha5=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(d.get('commit_sha', ''))
" "$_new_sentinel5" 2>/dev/null) || true

assert_eq "test_fetch_sentinel_sha_mismatch_reclones: sentinel updated to new SHA" \
    "newsha999" "$_new_sha5"
assert_pass_if_clean "test_fetch_sentinel_sha_mismatch_reclones"

# ── test_fetch_exports_clone_dir ──────────────────────────────────────────────
# CLONE_DIR must be derived from VERSION (path contains the version string).
echo ""
echo "--- test_fetch_exports_clone_dir ---"
_snapshot_fail

_t6="$TMPDIR_TEST/t6"
mkdir -p "$_t6"
_mock_resolver6=$(_make_mock_resolver "$_t6" "v2.0.0-rc1" "2")
_git_dir6=$(_make_mock_git "$_t6" "0" "sha6sha6sha6")

_runner_temp6="$TMPDIR_TEST/runner6"
mkdir -p "$_runner_temp6"

rc=0
log_out=$(
    PATH="$_git_dir6:$PATH" \
    RESOLVE_DSO_VERSION_SCRIPT="$_mock_resolver6" \
    RUNNER_TEMP="$_runner_temp6" \
    CI_DSO_FETCH_SKIP_LS_REMOTE="1" \
    bash "$FETCH_SCRIPT" 2>&1
) || rc=$?

assert_eq "test_fetch_exports_clone_dir: exit 0" "0" "$rc"
assert_contains "test_fetch_exports_clone_dir: CLONE_DIR contains version" \
    "v2.0.0-rc1" "$log_out"
assert_pass_if_clean "test_fetch_exports_clone_dir"

# ── test_fetch_validates_marketplace_json ─────────────────────────────────────
# Post-clone: if marketplace.json is missing, the script must exit non-zero.
echo ""
echo "--- test_fetch_validates_marketplace_json ---"
_snapshot_fail

_t7="$TMPDIR_TEST/t7"
mkdir -p "$_t7"
_mock_resolver7=$(_make_mock_resolver "$_t7" "v1.99.0" "2")

# Build a fake git that clones but does NOT create marketplace.json.
_fake_git7="$_t7/git"
cat > "$_fake_git7" <<'FAKEGIT7'
#!/usr/bin/env bash
subcommand="${1:-}"
case "$subcommand" in
    clone)
        dest="${@: -1}"
        mkdir -p "$dest"
        # Intentionally omit marketplace.json
        exit 0
        ;;
    -C)
        _c_dir="${2:-}"
        shift 2
        _c_sub="${1:-}"
        if [[ "$_c_sub" == "rev-parse" && "${2:-}" == "HEAD" ]]; then
            echo "sha7sha7"
            exit 0
        fi
        exec /usr/bin/git -C "$_c_dir" "$@"
        ;;
    *)
        exec /usr/bin/git "$@"
        ;;
esac
FAKEGIT7
chmod +x "$_fake_git7"

_runner_temp7="$TMPDIR_TEST/runner7"
mkdir -p "$_runner_temp7"

rc=0
stderr_out7=$(
    PATH="$_t7:$PATH" \
    RESOLVE_DSO_VERSION_SCRIPT="$_mock_resolver7" \
    RUNNER_TEMP="$_runner_temp7" \
    CI_DSO_FETCH_SKIP_LS_REMOTE="1" \
    bash "$FETCH_SCRIPT" 2>&1 >/dev/null
) || rc=$?

assert_ne "test_fetch_validates_marketplace_json: non-zero exit" "0" "$rc"
assert_contains "test_fetch_validates_marketplace_json: validation error" \
    "marketplace.json" "$stderr_out7"
assert_pass_if_clean "test_fetch_validates_marketplace_json"

echo ""
echo "=== test-ci-dso-fetch.sh complete ==="
