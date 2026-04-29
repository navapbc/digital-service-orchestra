#!/usr/bin/env bash
# tests/scripts/test-ticket-link-duplicates-supersedes.sh
# RED tests for `duplicates` and `supersedes` link relation values in ticket-link.sh.
#
# ticket-link.sh currently only accepts blocks, depends_on, and relates_to.
# This file defines the behavioral contract for two new directional (non-bidirectional)
# relation values:
#   - duplicates:  source is the duplicate, target is the canonical ticket
#   - supersedes:  source is the new/replacing ticket, target is the superseded ticket
#
# Tests 1-5 call ticket-link.sh directly (the script under test). These tests
# FAIL RED because ticket-link.sh rejects 'duplicates'/'supersedes' as invalid.
# Test 6 validates that the existing guard still rejects truly invalid relations.
#
# Usage: bash tests/scripts/test-ticket-link-duplicates-supersedes.sh
# Returns: non-zero (RED) until ticket-link.sh adds duplicates/supersedes to its enum.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LINK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-link.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-link-duplicates-supersedes.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out" | tail -1
}

# ── Helper: count LINK event files in a ticket directory ─────────────────────
_count_link_events() {
    local tracker_dir="$1"
    local ticket_id="$2"
    find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-LINK.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

# ── Helper: count UNLINK event files in a ticket directory ───────────────────
_count_unlink_events() {
    local tracker_dir="$1"
    local ticket_id="$2"
    find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-UNLINK.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

# ── Test 6: invalid relation is still rejected by the guard (must pass) ────────
echo "Test 6: ticket-link.sh link <A> <B> invalidrelation exits non-zero (guard still works)"
test_link_invalid_relation_still_rejected() {
    # Call _snapshot_fail to get a clean FAIL baseline for this test — previous
    # RED failures from tests 1-5 must not leak into this test's pass/fail accounting.
    _snapshot_fail

    if [ ! -f "$TICKET_LINK_SCRIPT" ]; then
        assert_eq "ticket-link.sh exists" "exists" "missing"
        assert_pass_if_clean "test_link_invalid_relation_still_rejected"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    local id_a id_b
    id_a=$(_create_ticket "$repo" task "Invalid relation source")
    id_b=$(_create_ticket "$repo" task "Invalid relation target")

    if [ -z "$id_a" ] || [ -z "$id_b" ]; then
        assert_eq "tickets created for invalid-relation test" "non-empty" "empty"
        assert_pass_if_clean "test_link_invalid_relation_still_rejected"
        return
    fi

    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_LINK_SCRIPT" link "$id_a" "$id_b" invalidrelation 2>&1) || exit_code=$?

    # Assert: exits non-zero (unknown relation must always be rejected)
    assert_eq "invalid relation: exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message printed (not silent)
    if [ -n "$stderr_out" ]; then
        assert_eq "invalid relation: error message printed" "has-message" "has-message"
    else
        assert_eq "invalid relation: error message printed" "has-message" "silent"
    fi

    # Assert: no LINK event written in id_a dir
    local link_count
    link_count=$(_count_link_events "$tracker_dir" "$id_a")
    assert_eq "invalid relation: no LINK event written in source dir" "0" "$link_count"

    assert_pass_if_clean "test_link_invalid_relation_still_rejected"
}
test_link_invalid_relation_still_rejected

# ── Test 1 (RED): ticket-link.sh link A B duplicates exits 0 and writes LINK ─
echo "Test 1 (RED): ticket-link.sh link <A> <B> duplicates exits 0 and writes LINK event"
test_link_duplicates_succeeds() {
    _snapshot_fail

    if [ ! -f "$TICKET_LINK_SCRIPT" ]; then
        assert_eq "ticket-link.sh exists" "exists" "missing"
        assert_pass_if_clean "test_link_duplicates_succeeds"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    local id_a id_b
    id_a=$(_create_ticket "$repo" task "Duplicate ticket (source)")
    id_b=$(_create_ticket "$repo" task "Canonical ticket (target)")

    if [ -z "$id_a" ] || [ -z "$id_b" ]; then
        assert_eq "tickets created for duplicates test" "non-empty" "empty"
        assert_pass_if_clean "test_link_duplicates_succeeds"
        return
    fi

    local before_count
    before_count=$(_count_link_events "$tracker_dir" "$id_a")

    # RED: ticket-link.sh rejects 'duplicates' as invalid → currently exits non-zero
    local exit_code=0
    (cd "$repo" && bash "$TICKET_LINK_SCRIPT" link "$id_a" "$id_b" duplicates 2>/dev/null) || exit_code=$?

    # Assert: exits 0 (will fail RED — 'duplicates' not yet in the enum)
    assert_eq "link duplicates: exits 0" "0" "$exit_code"

    # Assert: exactly one new LINK event file written in id_a dir
    local after_count
    after_count=$(_count_link_events "$tracker_dir" "$id_a")
    local new_events
    new_events=$(( after_count - before_count ))
    assert_eq "link duplicates: one LINK event written in source dir" "1" "$new_events"

    # Assert: LINK event data.relation = duplicates and data.target_id = id_b
    local link_file
    link_file=$(find "$tracker_dir/$id_a" -maxdepth 1 -name '*-LINK.json' ! -name '.*' 2>/dev/null | sort | tail -1)

    if [ -z "$link_file" ]; then
        assert_eq "link duplicates: LINK event file found in source dir" "found" "not-found"
        assert_pass_if_clean "test_link_duplicates_succeeds"
        return
    fi

    local field_check
    field_check=$(python3 - "$link_file" "$id_b" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        ev = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

target_id = sys.argv[2]
errors = []

if ev.get('event_type') != 'LINK':
    errors.append(f"event_type not LINK: {ev.get('event_type')!r}")

data = ev.get('data', {})
if not isinstance(data, dict):
    errors.append(f"data not dict: {type(data)}")
else:
    if data.get('relation') != 'duplicates':
        errors.append(f"data.relation not 'duplicates': {data.get('relation')!r}")
    if data.get('target_id') != target_id:
        errors.append(f"data.target_id wrong: expected {target_id!r}, got {data.get('target_id')!r}")

print("ERRORS:" + "; ".join(errors) if errors else "OK")
PYEOF
) || true

    if [ "$field_check" = "OK" ]; then
        assert_eq "link duplicates: LINK event has correct relation and target_id" "OK" "OK"
    else
        assert_eq "link duplicates: LINK event has correct relation and target_id" "OK" "$field_check"
    fi

    assert_pass_if_clean "test_link_duplicates_succeeds"
}
test_link_duplicates_succeeds

# ── Test 2 (RED): ticket-link.sh link A B supersedes exits 0 and writes LINK ─
echo "Test 2 (RED): ticket-link.sh link <A> <B> supersedes exits 0 and writes LINK event"
test_link_supersedes_succeeds() {
    _snapshot_fail

    if [ ! -f "$TICKET_LINK_SCRIPT" ]; then
        assert_eq "ticket-link.sh exists" "exists" "missing"
        assert_pass_if_clean "test_link_supersedes_succeeds"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    local id_a id_b
    id_a=$(_create_ticket "$repo" task "Superseding ticket (source)")
    id_b=$(_create_ticket "$repo" task "Superseded ticket (target)")

    if [ -z "$id_a" ] || [ -z "$id_b" ]; then
        assert_eq "tickets created for supersedes test" "non-empty" "empty"
        assert_pass_if_clean "test_link_supersedes_succeeds"
        return
    fi

    local before_count
    before_count=$(_count_link_events "$tracker_dir" "$id_a")

    # RED: ticket-link.sh rejects 'supersedes' as invalid → currently exits non-zero
    local exit_code=0
    (cd "$repo" && bash "$TICKET_LINK_SCRIPT" link "$id_a" "$id_b" supersedes 2>/dev/null) || exit_code=$?

    # Assert: exits 0 (will fail RED — 'supersedes' not yet in the enum)
    assert_eq "link supersedes: exits 0" "0" "$exit_code"

    # Assert: exactly one new LINK event file written in id_a dir
    local after_count
    after_count=$(_count_link_events "$tracker_dir" "$id_a")
    local new_events
    new_events=$(( after_count - before_count ))
    assert_eq "link supersedes: one LINK event written in source dir" "1" "$new_events"

    # Assert: LINK event data.relation = supersedes and data.target_id = id_b
    local link_file
    link_file=$(find "$tracker_dir/$id_a" -maxdepth 1 -name '*-LINK.json' ! -name '.*' 2>/dev/null | sort | tail -1)

    if [ -z "$link_file" ]; then
        assert_eq "link supersedes: LINK event file found in source dir" "found" "not-found"
        assert_pass_if_clean "test_link_supersedes_succeeds"
        return
    fi

    local field_check
    field_check=$(python3 - "$link_file" "$id_b" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        ev = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

target_id = sys.argv[2]
errors = []

if ev.get('event_type') != 'LINK':
    errors.append(f"event_type not LINK: {ev.get('event_type')!r}")

data = ev.get('data', {})
if not isinstance(data, dict):
    errors.append(f"data not dict: {type(data)}")
else:
    if data.get('relation') != 'supersedes':
        errors.append(f"data.relation not 'supersedes': {data.get('relation')!r}")
    if data.get('target_id') != target_id:
        errors.append(f"data.target_id wrong: expected {target_id!r}, got {data.get('target_id')!r}")

print("ERRORS:" + "; ".join(errors) if errors else "OK")
PYEOF
) || true

    if [ "$field_check" = "OK" ]; then
        assert_eq "link supersedes: LINK event has correct relation and target_id" "OK" "OK"
    else
        assert_eq "link supersedes: LINK event has correct relation and target_id" "OK" "$field_check"
    fi

    assert_pass_if_clean "test_link_supersedes_succeeds"
}
test_link_supersedes_succeeds

# ── Test 3 (RED): duplicates is NOT bidirectional (no LINK in target dir) ──────
echo "Test 3 (RED): ticket-link.sh link <A> <B> duplicates does NOT write a LINK event in B's directory"
test_link_duplicates_is_not_bidirectional() {
    _snapshot_fail

    if [ ! -f "$TICKET_LINK_SCRIPT" ]; then
        assert_eq "ticket-link.sh exists" "exists" "missing"
        assert_pass_if_clean "test_link_duplicates_is_not_bidirectional"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    local id_a id_b
    id_a=$(_create_ticket "$repo" task "Duplicate source (directionality test)")
    id_b=$(_create_ticket "$repo" task "Canonical target (directionality test)")

    if [ -z "$id_a" ] || [ -z "$id_b" ]; then
        assert_eq "tickets created for duplicates-not-bidirectional test" "non-empty" "empty"
        assert_pass_if_clean "test_link_duplicates_is_not_bidirectional"
        return
    fi

    local before_b_count
    before_b_count=$(_count_link_events "$tracker_dir" "$id_b")

    # RED: ticket-link.sh rejects 'duplicates' → currently exits non-zero
    local exit_code=0
    (cd "$repo" && bash "$TICKET_LINK_SCRIPT" link "$id_a" "$id_b" duplicates 2>/dev/null) || exit_code=$?

    # Assert: exits 0 (fails RED until duplicates is in the enum)
    assert_eq "duplicates not-bidirectional: exits 0" "0" "$exit_code"

    # Assert: NO new LINK event in id_b's directory (not bidirectional)
    local after_b_count
    after_b_count=$(_count_link_events "$tracker_dir" "$id_b")
    local new_b_events
    new_b_events=$(( after_b_count - before_b_count ))
    assert_eq "duplicates not-bidirectional: no LINK event written in target dir" "0" "$new_b_events"

    assert_pass_if_clean "test_link_duplicates_is_not_bidirectional"
}
test_link_duplicates_is_not_bidirectional

# ── Test 4 (RED): supersedes is NOT bidirectional (no LINK in target dir) ──────
echo "Test 4 (RED): ticket-link.sh link <A> <B> supersedes does NOT write a LINK event in B's directory"
test_link_supersedes_is_not_bidirectional() {
    _snapshot_fail

    if [ ! -f "$TICKET_LINK_SCRIPT" ]; then
        assert_eq "ticket-link.sh exists" "exists" "missing"
        assert_pass_if_clean "test_link_supersedes_is_not_bidirectional"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    local id_a id_b
    id_a=$(_create_ticket "$repo" task "Superseding source (directionality test)")
    id_b=$(_create_ticket "$repo" task "Superseded target (directionality test)")

    if [ -z "$id_a" ] || [ -z "$id_b" ]; then
        assert_eq "tickets created for supersedes-not-bidirectional test" "non-empty" "empty"
        assert_pass_if_clean "test_link_supersedes_is_not_bidirectional"
        return
    fi

    local before_b_count
    before_b_count=$(_count_link_events "$tracker_dir" "$id_b")

    # RED: ticket-link.sh rejects 'supersedes' → currently exits non-zero
    local exit_code=0
    (cd "$repo" && bash "$TICKET_LINK_SCRIPT" link "$id_a" "$id_b" supersedes 2>/dev/null) || exit_code=$?

    # Assert: exits 0 (fails RED until supersedes is in the enum)
    assert_eq "supersedes not-bidirectional: exits 0" "0" "$exit_code"

    # Assert: NO new LINK event in id_b's directory (not bidirectional)
    local after_b_count
    after_b_count=$(_count_link_events "$tracker_dir" "$id_b")
    local new_b_events
    new_b_events=$(( after_b_count - before_b_count ))
    assert_eq "supersedes not-bidirectional: no LINK event written in target dir" "0" "$new_b_events"

    assert_pass_if_clean "test_link_supersedes_is_not_bidirectional"
}
test_link_supersedes_is_not_bidirectional

# ── Test 5 (RED): duplicates link cancelled by unlink (roundtrip) ─────────────
echo "Test 5 (RED): ticket-link.sh link A B duplicates; unlink A B — link is cancelled (no active dep in show A)"
test_link_duplicates_roundtrip_through_unlink() {
    _snapshot_fail

    if [ ! -f "$TICKET_LINK_SCRIPT" ]; then
        assert_eq "ticket-link.sh exists" "exists" "missing"
        assert_pass_if_clean "test_link_duplicates_roundtrip_through_unlink"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    local id_a id_b
    id_a=$(_create_ticket "$repo" task "Duplicate roundtrip source")
    id_b=$(_create_ticket "$repo" task "Duplicate roundtrip target")

    if [ -z "$id_a" ] || [ -z "$id_b" ]; then
        assert_eq "tickets created for duplicates roundtrip test" "non-empty" "empty"
        assert_pass_if_clean "test_link_duplicates_roundtrip_through_unlink"
        return
    fi

    # RED: link step will fail until 'duplicates' is in the enum
    local link_exit=0
    (cd "$repo" && bash "$TICKET_LINK_SCRIPT" link "$id_a" "$id_b" duplicates 2>/dev/null) || link_exit=$?

    # Assert: link exits 0 (fails RED until duplicates is accepted)
    assert_eq "duplicates roundtrip: link exits 0" "0" "$link_exit"

    # Unlink A -> B (via ticket CLI — unlink still routes through ticket-link.sh)
    local unlink_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" unlink "$id_a" "$id_b" 2>/dev/null) || unlink_exit=$?

    # Assert: unlink exits 0 (the link should exist to unlink)
    assert_eq "duplicates roundtrip: unlink exits 0" "0" "$unlink_exit"

    # Assert: after unlink, ticket show A does NOT list B in deps
    # The reducer replays LINK/UNLINK events — after UNLINK the dep should be inactive.
    local show_output
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$id_a" 2>/dev/null) || true

    local dep_check
    dep_check=$(python3 - "$show_output" "$id_b" <<'PYEOF'
import json, sys

try:
    state = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

target_id = sys.argv[2]

# deps is a list of dicts with ticket_id and relation keys
deps = state.get('deps', [])
if not isinstance(deps, list):
    print(f"DEPS_NOT_LIST: {type(deps).__name__}")
    sys.exit(1)

# Check that target_id does not appear as an active dep
active_dep_ids = [d.get('target_id') for d in deps if isinstance(d, dict)]
if target_id in active_dep_ids:
    print(f"STILL_IN_DEPS: {target_id!r} found in deps after unlink")
    sys.exit(2)
else:
    print("OK")
PYEOF
) || true

    if [ "$dep_check" = "OK" ]; then
        assert_eq "duplicates roundtrip: target no longer in source deps after unlink" "OK" "OK"
    else
        assert_eq "duplicates roundtrip: target no longer in source deps after unlink" "OK" "$dep_check"
    fi

    assert_pass_if_clean "test_link_duplicates_roundtrip_through_unlink"
}
test_link_duplicates_roundtrip_through_unlink

print_summary
