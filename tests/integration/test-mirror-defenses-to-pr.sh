#!/usr/bin/env bash
# tests/integration/test-mirror-defenses-to-pr.sh
#
# RED integration tests for plugins/dso/scripts/review-mirror-defenses.sh —
# the GitHubPRDefenseStore write path that replays locally-recorded defense
# records to the PR as comments via `gh pr comment`.
#
# The script under test DOES NOT EXIST YET. Every test is expected to FAIL
# (RED state) until the implementation is delivered.
#
# Behavioral contracts under test:
#   1. test_mirror_reads_defense_records_from_stdin
#      Pipe text containing DEFENSE_RECORD: {...} → gh pr comment called with
#      a body that contains "DEFENSE_RECORD:"
#
#   2. test_mirror_skips_non_defense_lines
#      Pipe text with no DEFENSE_RECORD lines → gh NOT called (nothing to mirror)
#
#   3. test_mirror_skips_unbound_records
#      Pipe DEFENSE_RECORD with ticket_id "UNBOUND" → gh not called (record
#      is skipped because there is no real ticket binding)
#
#   4. test_mirror_noop_on_fork_pr
#      Set GITHUB_FORK_PR=1, pipe valid defense records → gh NOT called
#      (fork-PR safety no-op path)
#
# Stubbing strategy: each test prepends a per-test tmp dir to PATH containing
# a fake `gh` binary that logs every invocation (argv) to $STUB_GH_LOG and
# exits 0. Assertions count / inspect logged calls.
#
# Usage:
#   bash tests/integration/test-mirror-defenses-to-pr.sh
# Exit: 0 all pass (GREEN once implementation lands); non-zero = RED (expected now).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-mirror-defenses-to-pr.sh ==="

# ---------------------------------------------------------------------------
# Globals & cleanup
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "${d:-}" && -d "$d" ]] && rm -rf "$d"
    done
}
trap _cleanup EXIT

MIRROR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/review-mirror-defenses.sh"

# ---------------------------------------------------------------------------
# _make_stub_dir — create per-test stub PATH prefix with a fake `gh` shim.
# The shim appends each call's argv (tab-separated, prefixed "CALL") to
# $STUB_GH_LOG, then exits 0.
# Returns the stub dir path on stdout.
# ---------------------------------------------------------------------------
_make_stub_dir() {
    local d
    d=$(mktemp -d "/tmp/dso-mirror-defenses-stubs.XXXXXX")
    _TEST_TMPDIRS+=("$d")

    cat > "$d/gh" <<'GHEOF'
#!/usr/bin/env bash
# Test stub for `gh`. Records argv to $STUB_GH_LOG, then exits 0.
set -u
LOG="${STUB_GH_LOG:-/dev/null}"
{
    printf 'CALL'
    for a in "$@"; do printf '\t%s' "$a"; done
    printf '\n'
} >> "$LOG" 2>/dev/null || true
exit 0
GHEOF
    chmod +x "$d/gh"

    echo "$d"
}

# ---------------------------------------------------------------------------
# _setup_test — fresh stubs, clear log, prepend to PATH.
# Sets: STUB_DIR, STUB_GH_LOG, _SAVED_PATH (so teardown can restore PATH).
# ---------------------------------------------------------------------------
_setup_test() {
    STUB_DIR=$(_make_stub_dir)
    STUB_GH_LOG="$STUB_DIR/gh.log"
    : > "$STUB_GH_LOG"
    export STUB_GH_LOG
    _SAVED_PATH="$PATH"
    PATH="$STUB_DIR:$PATH"
    export PATH
}

_teardown_test() {
    PATH="$_SAVED_PATH"
    export PATH
    unset STUB_GH_LOG GITHUB_FORK_PR 2>/dev/null || true
}

# Convenience: count calls to `gh pr comment` in the stub log.
# grep -c exits 1 when count is 0 (no matches) but still prints "0"; use
# a compound form that always exits 0 so the count is the only output.
_gh_comment_call_count() {
    local n
    n=$(grep -c $'^CALL\tpr\tcomment' "$STUB_GH_LOG" 2>/dev/null) || n=0
    echo "$n"
}

# Convenience: check if any gh call body contained the given pattern.
_gh_body_contains() {
    local pattern="$1"
    grep -q "$pattern" "$STUB_GH_LOG" 2>/dev/null
}

# ===========================================================================
# Test 1: script reads DEFENSE_RECORD lines from stdin and posts them via gh.
# ===========================================================================
test_mirror_reads_defense_records_from_stdin() {
    _setup_test

    local input
    input=$(printf '%s\n%s\n' \
        'Some preamble line' \
        'DEFENSE_RECORD: {"prior_finding_id":"f-abc","ticket_id":"T-1","defense":"inline comment proves correctness"}')

    local output
    output=$(printf '%s' "$input" | bash "$MIRROR_SCRIPT" 2>&1) || true

    local call_count
    call_count=$(_gh_comment_call_count)

    assert_eq \
        "test_mirror_reads_defense_records_from_stdin: gh pr comment called once for one record" \
        "1" \
        "$call_count"

    # The body passed to gh must contain the DEFENSE_RECORD marker.
    local body_ok="no"
    if _gh_body_contains "DEFENSE_RECORD:"; then
        body_ok="yes"
    fi
    assert_eq \
        "test_mirror_reads_defense_records_from_stdin: gh call body contains DEFENSE_RECORD:" \
        "yes" \
        "$body_ok"

    _teardown_test
}

# ===========================================================================
# Test 2: script does NOT call gh when no DEFENSE_RECORD lines are present.
# ===========================================================================
test_mirror_skips_non_defense_lines() {
    _setup_test

    local input
    input=$(printf '%s\n%s\n%s\n' \
        'Just a random log line' \
        'Another line with no special marker' \
        'Yet another irrelevant line')

    printf '%s' "$input" | bash "$MIRROR_SCRIPT" 2>&1 || true

    local call_count
    call_count=$(_gh_comment_call_count)

    assert_eq \
        "test_mirror_skips_non_defense_lines: gh not called when no DEFENSE_RECORD lines present" \
        "0" \
        "$call_count"

    _teardown_test
}

# ===========================================================================
# Test 3: DEFENSE_RECORD with ticket_id "UNBOUND" is skipped (gh not called).
# ===========================================================================
test_mirror_skips_unbound_records() {
    _setup_test

    local input
    input=$(printf '%s\n' \
        'DEFENSE_RECORD: {"ticket_id":"UNBOUND","prior_finding_id":"f-abc","defense":"no binding"}')

    printf '%s' "$input" | bash "$MIRROR_SCRIPT" 2>&1 || true

    local call_count
    call_count=$(_gh_comment_call_count)

    assert_eq \
        "test_mirror_skips_unbound_records: gh not called for UNBOUND ticket_id" \
        "0" \
        "$call_count"

    _teardown_test
}

# ===========================================================================
# Test 4: GITHUB_FORK_PR=1 → script is a no-op, gh never called.
# ===========================================================================
test_mirror_noop_on_fork_pr() {
    _setup_test
    export GITHUB_FORK_PR=1

    local input
    input=$(printf '%s\n' \
        'DEFENSE_RECORD: {"prior_finding_id":"f-xyz","ticket_id":"T-99","defense":"valid defense"}')

    printf '%s' "$input" | bash "$MIRROR_SCRIPT" 2>&1 || true

    local call_count
    call_count=$(_gh_comment_call_count)

    assert_eq \
        "test_mirror_noop_on_fork_pr: gh not called when GITHUB_FORK_PR=1" \
        "0" \
        "$call_count"

    _teardown_test
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_mirror_reads_defense_records_from_stdin
test_mirror_skips_non_defense_lines
test_mirror_skips_unbound_records
test_mirror_noop_on_fork_pr

print_summary
