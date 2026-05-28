#!/usr/bin/env bash
# tests/scripts/test-cycle-ledger-migration.sh
#
# cycle_ledger.py v1.2.0 grammar + v1.1.0->v1.2.0 sentinel migration contract
#
# Tests four behavioral contracts that FAIL before cycle_ledger v1.2.0 is implemented:
#
#   1. reconstruct_from_pr_comments: v1.1.0 marker yields pr_number=0 (sentinel)
#   2. Mixed-format thread: v1.1.0 + v1.2.0 markers for same sha -> v1.2.0 entry wins
#   3. _empty_ledger() returns schema_version="1.2.0" (not "1.1.0")
#   4. append_cycle round-trip: write with pr_number=42, read back, pr_number recovered

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$REPO_ROOT/tests/lib"

# shellcheck source=tests/lib/assert.sh
source "$LIB_DIR/assert.sh"

# ---------------------------------------------------------------------------
# Isolation: all filesystem side effects go to a temp dir
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
make_tmpdir() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-cycle-ledger-migration.XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && rm -rf "$d"
    done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Python helper: invoke a snippet against cycle_ledger and capture output
# ---------------------------------------------------------------------------
_PY_PATH="$REPO_ROOT/plugins/dso/scripts"

run_py() {
    python3 -c "
import sys
sys.path.insert(0, '$_PY_PATH')
$1
" 2>&1
}

# ---------------------------------------------------------------------------
# Test 1: reconstruct_from_pr_comments with v1.1.0 marker -> pr_number=0 (sentinel)
#
# Behavior: when a PR comment contains only the v1.1.0 marker format
# (no pr_number field), reconstruct_from_pr_comments must set pr_number=0
# as the sentinel to indicate "originated before v1.2.0 keying".
#
# current code does not emit pr_number field at all on reconstructed entries.
# ---------------------------------------------------------------------------
test_cycle_ledger_migration_v11_to_v12() {
    local tmpdir
    tmpdir=$(make_tmpdir)

    # Build a fake gh binary that emits a single v1.1.0 marker comment
    local fake_gh_dir="$tmpdir/fake-gh"
    mkdir -p "$fake_gh_dir"
    cat > "$fake_gh_dir/gh" <<'GHEOF'
#!/usr/bin/env bash
# Emit a single JSON comment array containing a v1.1.0-format DSO-Review-Cycle marker
cat <<'JSONEOF'
[
  {
    "body": "DSO-Review-Cycle: 1 commit_sha=abc123 findings_hash=h1 tuples=[[\"x.py\",\"1\",\"c\"]]"
  }
]
JSONEOF
GHEOF
    chmod +x "$fake_gh_dir/gh"

    local actual
    actual=$(PATH="$fake_gh_dir:$PATH" run_py "
from dso_ci_review.cycle_ledger import reconstruct_from_pr_comments
ledger = reconstruct_from_pr_comments(pr_number=42, repo='owner/repo')
cycles = ledger['cycles']
assert len(cycles) == 1, f'expected 1 cycle, got {len(cycles)}'
entry = cycles[0]
print(entry.get('pr_number', '__MISSING__'))
")
    assert_eq \
        "v1.1.0 marker -> pr_number=0 sentinel" \
        "0" \
        "$actual"

    # Also verify commit_sha and cycle_num are preserved
    local sha_val
    sha_val=$(PATH="$fake_gh_dir:$PATH" run_py "
from dso_ci_review.cycle_ledger import reconstruct_from_pr_comments
ledger = reconstruct_from_pr_comments(pr_number=42, repo='owner/repo')
entry = ledger['cycles'][0]
print(entry.get('commit_sha','__MISSING__'))
")
    assert_eq \
        "v1.1.0 marker -> commit_sha preserved" \
        "abc123" \
        "$sha_val"

    local cycle_num_val
    cycle_num_val=$(PATH="$fake_gh_dir:$PATH" run_py "
from dso_ci_review.cycle_ledger import reconstruct_from_pr_comments
ledger = reconstruct_from_pr_comments(pr_number=42, repo='owner/repo')
entry = ledger['cycles'][0]
print(entry.get('cycle_num','__MISSING__'))
")
    assert_eq \
        "v1.1.0 marker -> cycle_num=1 preserved" \
        "1" \
        "$cycle_num_val"
}

# ---------------------------------------------------------------------------
# Test 2: Mixed-format thread (v1.1.0 + v1.2.0 for same sha) -> v1.2.0 entry wins
#
# Behavior: when a PR comment thread has both a legacy v1.1.0 marker AND a new
# v1.2.0 marker (with explicit pr_number) for the same commit_sha and cycle_num,
# the reconstructed ledger must return a single deduplicated entry using the
# v1.2.0 data (pr_number=42, not sentinel pr_number=0).
#
# current code has no _MARKER_RE_V12 and no deduplication/precedence logic.
# ---------------------------------------------------------------------------
test_cycle_ledger_mixed_format_v12_wins() {
    local tmpdir
    tmpdir=$(make_tmpdir)

    local fake_gh_dir="$tmpdir/fake-gh"
    mkdir -p "$fake_gh_dir"
    # Both markers are for cycle_num=1, commit_sha=abc123.
    # v1.2.0 marker has explicit pr_number=42; v1.1.0 would yield sentinel pr_number=0.
    cat > "$fake_gh_dir/gh" <<'GHEOF'
#!/usr/bin/env bash
cat <<'JSONEOF'
[
  {
    "body": "DSO-Review-Cycle: 1 commit_sha=abc123 findings_hash=h1 tuples=[[\"x.py\",\"1\",\"c\"]]\nDSO-Review-Cycle: 1 pr_number=42 commit_sha=abc123 findings_hash=h1 tuples=[[\"x.py\",\"1\",\"c\"]]"
  }
]
JSONEOF
GHEOF
    chmod +x "$fake_gh_dir/gh"

    # mixed-format: assert deduplicated to 1 entry
    local count_val
    count_val=$(PATH="$fake_gh_dir:$PATH" run_py "
from dso_ci_review.cycle_ledger import reconstruct_from_pr_comments
ledger = reconstruct_from_pr_comments(pr_number=42, repo='owner/repo')
print(len(ledger['cycles']))
")
    assert_eq \
        "mixed-format both-markers -> deduplicated to 1 entry" \
        "1" \
        "$count_val"

    # mixed-format: v1.2.0 entry wins (pr_number=42, not sentinel 0)
    local pr_num_val
    pr_num_val=$(PATH="$fake_gh_dir:$PATH" run_py "
from dso_ci_review.cycle_ledger import reconstruct_from_pr_comments
ledger = reconstruct_from_pr_comments(pr_number=42, repo='owner/repo')
entry = ledger['cycles'][0]
print(entry.get('pr_number', '__MISSING__'))
")
    assert_eq \
        "mixed-format both-markers -> v1.2.0 entry pr_number=42 wins" \
        "42" \
        "$pr_num_val"
}

# ---------------------------------------------------------------------------
# Test 3: _empty_ledger() returns schema_version="1.2.0"
#
# Behavior: after T2 lands, the canonical empty ledger schema version must be
# "1.2.0". read_ledger on a missing path must also return schema_version="1.2.0".
#
# current _empty_ledger() returns "1.1.0".
# ---------------------------------------------------------------------------
test_cycle_ledger_empty_ledger_schema_version_is_v12() {
    local actual
    actual=$(run_py "
from dso_ci_review.cycle_ledger import _empty_ledger
ledger = _empty_ledger()
print(ledger['schema_version'])
")
    assert_eq \
        "_empty_ledger() returns schema_version=1.2.0" \
        "1.2.0" \
        "$actual"

    # Also check read_ledger on a missing path
    local read_schema
    read_schema=$(run_py "
from dso_ci_review.cycle_ledger import read_ledger
import tempfile, os
# Use a path guaranteed not to exist
ledger = read_ledger('/nonexistent/path/cycle-ledger.json')
print(ledger['schema_version'])
")
    assert_eq \
        "read_ledger(missing path) returns schema_version=1.2.0" \
        "1.2.0" \
        "$read_schema"
}

# ---------------------------------------------------------------------------
# Test 4: append_cycle round-trip with pr_number=42
#
# Behavior: append_cycle must accept a pr_number parameter. After writing,
# read_ledger must recover pr_number=42 from the stored entry.
#
# current append_cycle has no pr_number parameter.
# ---------------------------------------------------------------------------
test_cycle_ledger_append_cycle_pr_number_round_trip() {
    local tmpdir
    tmpdir=$(make_tmpdir)
    local ledger_path="$tmpdir/cycle-ledger.json"

    # Run append_cycle with pr_number=42 and read it back
    local pr_num_val
    pr_num_val=$(run_py "
from dso_ci_review.cycle_ledger import append_cycle, read_ledger
append_cycle(
    '$ledger_path',
    cycle_num=1,
    findings_tuples=[['x.py','1','correctness']],
    commit_sha='abc123',
    findings_hash='h1',
    pr_number=42,
)
ledger = read_ledger('$ledger_path')
entry = ledger['cycles'][0]
print(entry.get('pr_number', '__MISSING__'))
")
    assert_eq \
        "append_cycle pr_number=42 round-trips through write+read" \
        "42" \
        "$pr_num_val"

    # Also verify other fields are unaffected
    local sha_val
    sha_val=$(run_py "
from dso_ci_review.cycle_ledger import read_ledger
ledger = read_ledger('$ledger_path')
entry = ledger['cycles'][0]
print(entry.get('commit_sha','__MISSING__'))
")
    assert_eq \
        "append_cycle: commit_sha preserved alongside pr_number" \
        "abc123" \
        "$sha_val"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
# Each test wrapped with the _fail_snapshot + assert_pass_if_clean pattern so
# the suite-engine's parse_failing_tests_from_output can extract function names
# from "FAIL: <name>" lines and match against the .test-index marker.
_fail_snapshot=$FAIL
test_cycle_ledger_migration_v11_to_v12
assert_pass_if_clean "test_cycle_ledger_migration_v11_to_v12"

_fail_snapshot=$FAIL
test_cycle_ledger_mixed_format_v12_wins
assert_pass_if_clean "test_cycle_ledger_mixed_format_v12_wins"

_fail_snapshot=$FAIL
test_cycle_ledger_empty_ledger_schema_version_is_v12
assert_pass_if_clean "test_cycle_ledger_empty_ledger_schema_version_is_v12"

_fail_snapshot=$FAIL
test_cycle_ledger_append_cycle_pr_number_round_trip
assert_pass_if_clean "test_cycle_ledger_append_cycle_pr_number_round_trip"

print_summary
