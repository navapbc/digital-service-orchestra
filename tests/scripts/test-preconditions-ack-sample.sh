#!/usr/bin/env bash
# tests/scripts/test-preconditions-ack-sample.sh
# RED tests for the --sample-ack mode of preconditions-ack.sh.
#
# Target feature:
#   dso preconditions-ack <story_id> --sample-ack --class=<degradation_type> \
#     --if-skipped "<rationale>"
#
# This mode applies when a degradation class has >=4 entries. It selects exactly
# 3 decision_ids deterministically using SHA256, requires valid rationale for all
# 3 selected, and writes one ACK event with sampled_set populated.
#
# SHA256 Determinism Algorithm:
#   Given N decision_ids in class (sorted lexicographically):
#   1. Sort decision_ids lexicographically
#   2. Compute digest = SHA256(joined-by-newlines)
#   3. seed = first 8 hex chars of digest, interpreted as integer
#   4. i1 = seed % N; remove ids[i1]
#      i2 = (seed >> 8) % (N-1); remove result[i2]
#      i3 = (seed >> 16) % (N-2)
#   5. sampled_set = [ids[i1], ids[i2], ids[i3]]
#
# Tests:
#   1. test_sample_ack_selects_exactly_3             — 4 ids in class → ACK sampled_set has exactly 3
#   2. test_sample_ack_selection_is_deterministic    — run twice on same input → same sampled_set
#   3. test_sample_ack_rejects_class_with_fewer_than_4 — 3 ids in class → exits 1
#   4. test_sample_ack_ack_file_has_sampled_set_populated — sampled_set in ACK is a non-null array
#   5. test_sample_ack_remainder_absorbed_only_when_all_3_pass — invalid rationale → exits 1; no ACK written
#
# All 5 tests FAIL in RED state because plugins/dso/scripts/preconditions-ack.sh does not exist.
#
# Usage: bash tests/scripts/test-preconditions-ack-sample.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/preconditions-ack.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-preconditions-ack-sample.sh ==="

_CLEANUP_DIRS=()
trap 'rm -rf "${_CLEANUP_DIRS[@]:-}"' EXIT

# ── Fixture helpers ───────────────────────────────────────────────────────────

# _make_tracker_dir <story_id> [num_decision_ids]
# Creates a temp DSO_TICKETS_TRACKER_DIR with a PRECONDITIONS event fixture.
# decision_ids: ["sess:aaa","sess:bbb","sess:ccc","sess:ddd"] (first num_decision_ids)
# Returns the path in TRACKER_DIR (caller must set as env var).
_make_tracker_dir() {
    local story_id="${1:-story-sample-01}"
    local num_ids="${2:-4}"

    local tmp_tracker
    tmp_tracker=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp_tracker")

    local story_dir="$tmp_tracker/$story_id"
    mkdir -p "$story_dir"

    local ts
    ts=$(python3 -c "import time; print(int(time.time() * 1000))")
    local evt_uuid
    evt_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

    # Build decision_ids list with num_ids entries (always in order: aaa, bbb, ccc, ddd)
    local all_ids='"sess:aaa","sess:bbb","sess:ccc","sess:ddd"'
    local ids_json
    ids_json=$(python3 -c "
ids = ['sess:aaa','sess:bbb','sess:ccc','sess:ddd']
import json, sys
n = int(sys.argv[1])
print(json.dumps(ids[:n]))
" "$num_ids")

    python3 -c "
import json, sys
ids_json = sys.argv[1]
ts = int(sys.argv[2])
story_dir = sys.argv[3]
evt_uuid = sys.argv[4]
import json
decision_ids = json.loads(ids_json)
payload = {
    'event_type': 'PRECONDITIONS',
    'schema_version': 2,
    'manifest_depth': 'standard',
    'gate_name': 'review_gate',
    'session_id': 'sess-test',
    'worktree_id': 'test-branch',
    'tier': 'standard',
    'timestamp': ts,
    'gate_verdicts': [],
    'evidence_ref': {},
    'affects_fields': [],
    'data': {
        'degradation': True,
        'decision_ids': decision_ids,
        'degradation_class': 'review_gate',
        'condition_text': 'implementation plan must be complete before sprint executes'
    }
}
fname = f'{story_dir}/{ts}-{evt_uuid}-PRECONDITIONS.json'
with open(fname, 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$ids_json" "$ts" "$story_dir" "$evt_uuid"

    echo "$tmp_tracker"
}

# _compute_expected_sampled_set <decision_ids_space_separated>
# Returns a JSON array of the 3 expected selected IDs using the SHA256 algorithm.
_compute_expected_sampled_set() {
    python3 -c "
import sys, hashlib, json

ids = sys.argv[1:]
sorted_ids = sorted(ids)
joined = '\n'.join(sorted_ids) + '\n'
digest = hashlib.sha256(joined.encode()).hexdigest()
seed = int(digest[:8], 16)

n = len(sorted_ids)
pool = list(sorted_ids)

i1 = seed % n
s1 = pool.pop(i1)

i2 = (seed >> 8) % (n - 1)
s2 = pool.pop(i2)

i3 = (seed >> 16) % (n - 2)
s3 = pool[i3]

print(json.dumps([s1, s2, s3]))
" "$@"
}

VALID_RATIONALE="checked that implementation plan must be complete before sprint executes this story"

# ── test_sample_ack_selects_exactly_3 ────────────────────────────────────────
# 4 decision_ids in class → ACK event sampled_set must have exactly 3 elements.
test_sample_ack_selects_exactly_3() {
    _snapshot_fail
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "test_sample_ack_selects_exactly_3: preconditions-ack.sh exists" "exists" "missing"
        assert_pass_if_clean "test_sample_ack_selects_exactly_3"
        return
    fi

    local tracker
    tracker=$(_make_tracker_dir "story-s01" 4)
    local story_dir="$tracker/story-s01"

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tracker" bash "$SCRIPT" "story-s01" \
        --sample-ack --class=review_gate \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?

    assert_eq "test_sample_ack_selects_exactly_3: exits 0" "0" "$_exit"

    # Find the ACK file
    local ack_file
    ack_file=$(find "$story_dir" -name '*-ACK.json' | sort | tail -1)
    assert_ne "test_sample_ack_selects_exactly_3: ACK file written" "" "$ack_file"

    local count=0
    if [ -n "$ack_file" ] && [ -f "$ack_file" ]; then
        count=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
sampled = data.get('data', {}).get('sampled_set', [])
print(len(sampled) if isinstance(sampled, list) else -1)
" "$ack_file")
    fi
    assert_eq "test_sample_ack_selects_exactly_3: sampled_set length is 3" "3" "$count"
    assert_pass_if_clean "test_sample_ack_selects_exactly_3"
}

# ── test_sample_ack_selection_is_deterministic ────────────────────────────────
# Running --sample-ack twice on the same input must produce the same sampled_set.
test_sample_ack_selection_is_deterministic() {
    _snapshot_fail
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "test_sample_ack_selection_is_deterministic: preconditions-ack.sh exists" "exists" "missing"
        assert_pass_if_clean "test_sample_ack_selection_is_deterministic"
        return
    fi

    # Run 1
    local tracker1
    tracker1=$(_make_tracker_dir "story-s02" 4)
    local story_dir1="$tracker1/story-s02"
    local _exit1=0
    DSO_TICKETS_TRACKER_DIR="$tracker1" bash "$SCRIPT" "story-s02" \
        --sample-ack --class=review_gate \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit1=$?
    assert_eq "test_sample_ack_selection_is_deterministic: run1 exits 0" "0" "$_exit1"

    local ack1
    ack1=$(find "$story_dir1" -name '*-ACK.json' | sort | tail -1)
    local sampled1=""
    if [ -n "$ack1" ] && [ -f "$ack1" ]; then
        sampled1=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
import json as j
print(j.dumps(sorted(data.get('data', {}).get('sampled_set', []))))
" "$ack1")
    fi

    # Run 2 (fresh tracker, same input)
    local tracker2
    tracker2=$(_make_tracker_dir "story-s02b" 4)
    local story_dir2="$tracker2/story-s02b"
    local _exit2=0
    DSO_TICKETS_TRACKER_DIR="$tracker2" bash "$SCRIPT" "story-s02b" \
        --sample-ack --class=review_gate \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit2=$?
    assert_eq "test_sample_ack_selection_is_deterministic: run2 exits 0" "0" "$_exit2"

    local ack2
    ack2=$(find "$story_dir2" -name '*-ACK.json' | sort | tail -1)
    local sampled2=""
    if [ -n "$ack2" ] && [ -f "$ack2" ]; then
        sampled2=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
import json as j
print(j.dumps(sorted(data.get('data', {}).get('sampled_set', []))))
" "$ack2")
    fi

    assert_eq "test_sample_ack_selection_is_deterministic: same sampled_set both runs" \
        "$sampled1" "$sampled2"
    assert_pass_if_clean "test_sample_ack_selection_is_deterministic"
}

# ── test_sample_ack_rejects_class_with_fewer_than_4 ──────────────────────────
# When the degradation class has only 3 decision_ids, --sample-ack must exit 1
# with an error indicating the class is too small for sample-ack.
test_sample_ack_rejects_class_with_fewer_than_4() {
    _snapshot_fail
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "test_sample_ack_rejects_class_with_fewer_than_4: preconditions-ack.sh exists" "exists" "missing"
        assert_pass_if_clean "test_sample_ack_rejects_class_with_fewer_than_4"
        return
    fi

    local tracker
    tracker=$(_make_tracker_dir "story-s03" 3)

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tracker" bash "$SCRIPT" "story-s03" \
        --sample-ack --class=review_gate \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?

    assert_eq "test_sample_ack_rejects_class_with_fewer_than_4: exits 1 when class has 3 ids" "1" "$_exit"
    assert_pass_if_clean "test_sample_ack_rejects_class_with_fewer_than_4"
}

# ── test_sample_ack_ack_file_has_sampled_set_populated ───────────────────────
# The ACK event written by --sample-ack must contain a non-null sampled_set array.
test_sample_ack_ack_file_has_sampled_set_populated() {
    _snapshot_fail
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "test_sample_ack_ack_file_has_sampled_set_populated: preconditions-ack.sh exists" "exists" "missing"
        assert_pass_if_clean "test_sample_ack_ack_file_has_sampled_set_populated"
        return
    fi

    local tracker
    tracker=$(_make_tracker_dir "story-s04" 4)
    local story_dir="$tracker/story-s04"

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tracker" bash "$SCRIPT" "story-s04" \
        --sample-ack --class=review_gate \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?
    assert_eq "test_sample_ack_ack_file_has_sampled_set_populated: exits 0" "0" "$_exit"

    local ack_file
    ack_file=$(find "$story_dir" -name '*-ACK.json' | sort | tail -1)
    assert_ne "test_sample_ack_ack_file_has_sampled_set_populated: ACK file written" "" "$ack_file"

    local is_array="no"
    if [ -n "$ack_file" ] && [ -f "$ack_file" ]; then
        is_array=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
sampled = data.get('data', {}).get('sampled_set')
print('yes' if isinstance(sampled, list) else 'no')
" "$ack_file")
    fi
    assert_eq "test_sample_ack_ack_file_has_sampled_set_populated: sampled_set is array" "yes" "$is_array"
    assert_pass_if_clean "test_sample_ack_ack_file_has_sampled_set_populated"
}

# ── test_sample_ack_remainder_absorbed_only_when_all_3_pass ──────────────────
# When the rationale provided does not pass validation (e.g., "bad"), the command
# must exit 1 and must NOT write any ACK file.
test_sample_ack_remainder_absorbed_only_when_all_3_pass() {
    _snapshot_fail
    if [ ! -f "$SCRIPT" ]; then
        assert_eq "test_sample_ack_remainder_absorbed_only_when_all_3_pass: preconditions-ack.sh exists" "exists" "missing"
        assert_pass_if_clean "test_sample_ack_remainder_absorbed_only_when_all_3_pass"
        return
    fi

    local tracker
    tracker=$(_make_tracker_dir "story-s05" 4)
    local story_dir="$tracker/story-s05"

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tracker" bash "$SCRIPT" "story-s05" \
        --sample-ack --class=review_gate \
        --if-skipped "bad" 2>/dev/null || _exit=$?

    assert_eq "test_sample_ack_remainder_absorbed_only_when_all_3_pass: exits 1 on invalid rationale" "1" "$_exit"

    local ack_count
    ack_count=$(find "$story_dir" -name '*-ACK.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "test_sample_ack_remainder_absorbed_only_when_all_3_pass: no ACK file written" "0" "$ack_count"
    assert_pass_if_clean "test_sample_ack_remainder_absorbed_only_when_all_3_pass"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_sample_ack_selects_exactly_3
test_sample_ack_selection_is_deterministic
test_sample_ack_rejects_class_with_fewer_than_4
test_sample_ack_ack_file_has_sampled_set_populated
test_sample_ack_remainder_absorbed_only_when_all_3_pass

print_summary
