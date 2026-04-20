#!/usr/bin/env bash
# tests/scripts/test-preconditions-depth-classifier.sh
# RED tests for plugins/dso/scripts/preconditions-depth-classifier.sh (does NOT exist yet).
# Tests 6-8 also cover _write_preconditions() in ticket-lib.sh schema_version derivation.
#
# Covers:
#   1. TRIVIAL → manifest_depth=minimal schema_version=1
#   2. MODERATE → manifest_depth=standard schema_version=2
#   3. COMPLEX → manifest_depth=deep schema_version=2
#   4. SIMPLE → manifest_depth=minimal schema_version=1 (epic-tier alias)
#   5. UNKNOWN → minimal schema_version=1 (fail-open)
#   6. _write_preconditions with tier=standard → schema_version=2 manifest_depth=standard
#   7. _write_preconditions with tier=deep → schema_version=2 manifest_depth=deep
#   8. _write_preconditions with tier=minimal → schema_version=1 manifest_depth=minimal
#
# Usage: bash tests/scripts/test-preconditions-depth-classifier.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CLASSIFIER="$REPO_ROOT/plugins/dso/scripts/preconditions-depth-classifier.sh"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-preconditions-depth-classifier.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ──────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Test 1: TRIVIAL → minimal, schema_version=1 ──────────────────────────────
echo "Test 1: _classify_manifest_depth TRIVIAL → manifest_depth=minimal schema_version=1"
test_classify_trivial_maps_minimal() {
    if [ ! -f "$CLASSIFIER" ]; then
        assert_eq "classifier exists" "exists" "missing"
        return
    fi

    local output
    # shellcheck source=/dev/null
    output=$(bash -c "source '$CLASSIFIER' && _classify_manifest_depth TRIVIAL" 2>&1)

    local depth sv
    depth=$(echo "$output" | grep '^manifest_depth=' | cut -d= -f2)
    sv=$(echo "$output" | grep '^schema_version=' | cut -d= -f2)

    assert_eq "TRIVIAL → manifest_depth=minimal" "minimal" "$depth"
    assert_eq "TRIVIAL → schema_version=1" "1" "$sv"
}
test_classify_trivial_maps_minimal

# ── Test 2: MODERATE → standard, schema_version=2 ────────────────────────────
echo "Test 2: _classify_manifest_depth MODERATE → manifest_depth=standard schema_version=2"
test_classify_moderate_maps_standard() {
    if [ ! -f "$CLASSIFIER" ]; then
        assert_eq "classifier exists" "exists" "missing"
        return
    fi

    local output
    output=$(bash -c "source '$CLASSIFIER' && _classify_manifest_depth MODERATE" 2>&1)

    local depth sv
    depth=$(echo "$output" | grep '^manifest_depth=' | cut -d= -f2)
    sv=$(echo "$output" | grep '^schema_version=' | cut -d= -f2)

    assert_eq "MODERATE → manifest_depth=standard" "standard" "$depth"
    assert_eq "MODERATE → schema_version=2" "2" "$sv"
}
test_classify_moderate_maps_standard

# ── Test 3: COMPLEX → deep, schema_version=2 ─────────────────────────────────
echo "Test 3: _classify_manifest_depth COMPLEX → manifest_depth=deep schema_version=2"
test_classify_complex_maps_deep() {
    if [ ! -f "$CLASSIFIER" ]; then
        assert_eq "classifier exists" "exists" "missing"
        return
    fi

    local output
    output=$(bash -c "source '$CLASSIFIER' && _classify_manifest_depth COMPLEX" 2>&1)

    local depth sv
    depth=$(echo "$output" | grep '^manifest_depth=' | cut -d= -f2)
    sv=$(echo "$output" | grep '^schema_version=' | cut -d= -f2)

    assert_eq "COMPLEX → manifest_depth=deep" "deep" "$depth"
    assert_eq "COMPLEX → schema_version=2" "2" "$sv"
}
test_classify_complex_maps_deep

# ── Test 4: SIMPLE → minimal, schema_version=1 (epic-tier alias) ─────────────
echo "Test 4: _classify_manifest_depth SIMPLE → manifest_depth=minimal schema_version=1"
test_classify_simple_maps_minimal() {
    if [ ! -f "$CLASSIFIER" ]; then
        assert_eq "classifier exists" "exists" "missing"
        return
    fi

    local output
    output=$(bash -c "source '$CLASSIFIER' && _classify_manifest_depth SIMPLE" 2>&1)

    local depth sv
    depth=$(echo "$output" | grep '^manifest_depth=' | cut -d= -f2)
    sv=$(echo "$output" | grep '^schema_version=' | cut -d= -f2)

    assert_eq "SIMPLE → manifest_depth=minimal" "minimal" "$depth"
    assert_eq "SIMPLE → schema_version=1" "1" "$sv"
}
test_classify_simple_maps_minimal

# ── Test 5: unknown value → fail-open to minimal, schema_version=1 ───────────
echo "Test 5: _classify_manifest_depth UNKNOWN_VALUE → fail-open minimal schema_version=1"
test_classify_unknown_fallback_minimal() {
    if [ ! -f "$CLASSIFIER" ]; then
        assert_eq "classifier exists" "exists" "missing"
        return
    fi

    local output
    output=$(bash -c "source '$CLASSIFIER' && _classify_manifest_depth UNKNOWN_VALUE" 2>&1)

    local depth sv
    depth=$(echo "$output" | grep '^manifest_depth=' | cut -d= -f2)
    sv=$(echo "$output" | grep '^schema_version=' | cut -d= -f2)

    assert_eq "UNKNOWN_VALUE → manifest_depth=minimal (fail-open)" "minimal" "$depth"
    assert_eq "UNKNOWN_VALUE → schema_version=1 (fail-open)" "1" "$sv"
}
test_classify_unknown_fallback_minimal

# ── Tests 6-8: round-trip via _write_preconditions/_read_latest_preconditions ─
# These require ticket-lib.sh and a real tickets-tracker.

# ── Test 6: tier=standard in written event → schema_version=2 + manifest_depth=standard ─
echo "Test 6: _write_preconditions tier=standard → read-back schema_version=2 manifest_depth=standard"
test_standard_tier_fields_in_written_event() {
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    local ticket_id="test-std-001"
    local exit_code=0
    # shellcheck source=/dev/null
    (cd "$repo" && source "$TICKET_LIB" && \
        _write_preconditions "$ticket_id" "test_gate" "sess-001" "wt-001" "standard") \
        2>/dev/null || exit_code=$?

    assert_eq "_write_preconditions standard exits 0" "0" "$exit_code"

    # Read it back
    local json
    json=$(cd "$repo" && source "$TICKET_LIB" && \
        _read_latest_preconditions "$ticket_id" "test_gate" "sess-001" 2>/dev/null)

    if [ -z "$json" ]; then
        assert_eq "event JSON readable" "nonempty" "empty"
        return
    fi

    local sv md
    sv=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('schema_version','missing'))" "$json" 2>/dev/null)
    md=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('manifest_depth','missing'))" "$json" 2>/dev/null)

    assert_eq "standard tier → schema_version=2" "2" "$sv"
    assert_eq "standard tier → manifest_depth=standard" "standard" "$md"
}
test_standard_tier_fields_in_written_event

# ── Test 7: tier=deep in written event → schema_version=2 + manifest_depth=deep ─
echo "Test 7: _write_preconditions tier=deep → read-back schema_version=2 manifest_depth=deep"
test_deep_tier_fields_in_written_event() {
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    local ticket_id="test-deep-001"
    local exit_code=0
    (cd "$repo" && source "$TICKET_LIB" && \
        _write_preconditions "$ticket_id" "test_gate" "sess-002" "wt-002" "deep") \
        2>/dev/null || exit_code=$?

    assert_eq "_write_preconditions deep exits 0" "0" "$exit_code"

    local json
    json=$(cd "$repo" && source "$TICKET_LIB" && \
        _read_latest_preconditions "$ticket_id" "test_gate" "sess-002" 2>/dev/null)

    if [ -z "$json" ]; then
        assert_eq "event JSON readable" "nonempty" "empty"
        return
    fi

    local sv md
    sv=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('schema_version','missing'))" "$json" 2>/dev/null)
    md=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('manifest_depth','missing'))" "$json" 2>/dev/null)

    assert_eq "deep tier → schema_version=2" "2" "$sv"
    assert_eq "deep tier → manifest_depth=deep" "deep" "$md"
}
test_deep_tier_fields_in_written_event

# ── Test 8: tier=minimal → schema_version=1 + manifest_depth=minimal (already passes) ─
echo "Test 8: _write_preconditions tier=minimal → read-back schema_version=1 manifest_depth=minimal"
test_round_trip_minimal() {
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    local ticket_id="test-min-001"
    local exit_code=0
    (cd "$repo" && source "$TICKET_LIB" && \
        _write_preconditions "$ticket_id" "test_gate" "sess-003" "wt-003" "minimal") \
        2>/dev/null || exit_code=$?

    assert_eq "_write_preconditions minimal exits 0" "0" "$exit_code"

    local json
    json=$(cd "$repo" && source "$TICKET_LIB" && \
        _read_latest_preconditions "$ticket_id" "test_gate" "sess-003" 2>/dev/null)

    if [ -z "$json" ]; then
        assert_eq "event JSON readable" "nonempty" "empty"
        return
    fi

    local sv md
    sv=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('schema_version','missing'))" "$json" 2>/dev/null)
    md=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('manifest_depth','missing'))" "$json" 2>/dev/null)

    assert_eq "minimal tier → schema_version=1" "1" "$sv"
    assert_eq "minimal tier → manifest_depth=minimal" "minimal" "$md"
}
test_round_trip_minimal

print_summary
