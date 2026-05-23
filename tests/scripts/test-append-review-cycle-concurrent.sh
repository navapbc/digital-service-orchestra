#!/usr/bin/env bash
# tests/scripts/test-append-review-cycle-concurrent.sh
# Concurrent-write fixture for plugins/dso/scripts/append_review_cycle.py
#
# Behaviors under test:
#   test_concurrent_no_lost_writes — two parallel writers (n=1, n=2) both
#       complete successfully and both entries survive in cycles[] with no
#       lost writes; repeated 3 times to flush timing-dependent flake.
#
# The fixture proves that fcntl.flock(LOCK_EX) in append_review_cycle.py
# prevents lost writes when two writers append concurrently.
#
# Usage: bash tests/scripts/test-append-review-cycle-concurrent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/append_review_cycle.py"

source "$REPO_ROOT/tests/lib/assert.sh"

# Global cleanup registry
declare -a CLEANUP_DIRS=()
trap 'rm -rf "${CLEANUP_DIRS[@]:-}"' EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

_make_tmpdir() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-arc-concurrent-XXXXXX")
    CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

_make_artifact() {
    local dir="$1"
    local content="$2"
    local path
    path=$(mktemp "${dir}/artifact-XXXXXX.json")
    printf '%s' "$content" > "$path"
    echo "$path"
}

_run_cli() {
    python3 "$SCRIPT" "$@"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# _run_concurrent_iteration dir artifact
# Launches two parallel writers (n=1 and n=2), waits for both, then asserts:
#   1. Both exit codes are 0
#   2. cycles[] length == 2
#   3. Entry with n=1 is present
#   4. Entry with n=2 is present
# Returns 0 if all assertions pass (failures are recorded in FAIL counter).
_run_concurrent_iteration() {
    local iteration="$1"
    local dir="$2"
    local artifact="$3"

    local prefix="iter${iteration}"

    # Launch writer 1 (n=1) in background
    _run_cli \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "hash1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
        --findings-count 3 \
        --verdict pass \
        --timestamp-iso "2026-01-01T00:00:00+00:00" &
    local pid1=$!

    # Launch writer 2 (n=2) in background
    _run_cli \
        --artifact "$artifact" \
        --n 2 \
        --draft-hash "hash2bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
        --findings-count 0 \
        --verdict pass \
        --timestamp-iso "2026-01-02T00:00:00+00:00" &
    local pid2=$!

    # Wait for both and capture exit codes
    local exit1=0 exit2=0
    wait "$pid1" || exit1=$?
    wait "$pid2" || exit2=$?

    assert_eq "${prefix}: writer n=1 exits 0" "0" "$exit1"
    assert_eq "${prefix}: writer n=2 exits 0" "0" "$exit2"

    # Inspect resulting artifact
    local cycle_count
    cycle_count=$(python3 -c "import json; d=json.load(open('$artifact')); print(len(d['cycles']))")
    assert_eq "${prefix}: cycles[] length == 2 (no lost writes)" "2" "$cycle_count"

    local has_n1
    has_n1=$(python3 -c "
import json
d = json.load(open('$artifact'))
print('yes' if any(c['n'] == 1 for c in d['cycles']) else 'no')
")
    assert_eq "${prefix}: n=1 entry present" "yes" "$has_n1"

    local has_n2
    has_n2=$(python3 -c "
import json
d = json.load(open('$artifact'))
print('yes' if any(c['n'] == 2 for c in d['cycles']) else 'no')
")
    assert_eq "${prefix}: n=2 entry present" "yes" "$has_n2"
}

test_concurrent_no_lost_writes() {
    # Repeat the concurrent run 3 times to expose timing-dependent flake.
    # Each iteration gets a FRESH tmpdir so macOS mktemp can create a new
    # artifact file (macOS mktemp with "XXXXXX.json" suffix produces only one
    # unique name per directory — a second call in the same dir returns
    # "File exists"). A fresh tmpdir per iteration avoids this constraint.
    local i
    for i in 1 2 3; do
        local dir artifact
        dir=$(_make_tmpdir)
        artifact=$(_make_artifact "$dir" '{"cycles": []}')

        _run_concurrent_iteration "$i" "$dir" "$artifact"
    done
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo "=== test-append-review-cycle-concurrent.sh ==="

test_concurrent_no_lost_writes

print_summary
