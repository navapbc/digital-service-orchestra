#!/usr/bin/env bash
# tests/scripts/test-sprint-list-epics-without-tag.sh
# RED test: behavioral test for sprint-list-epics.sh --without-tag=<tag> filter (not yet implemented).
#
# Given two epics — one tagged brainstorm:complete, one untagged —
# --without-tag=brainstorm:complete must return only the untagged epic.
#
# This test FAILS RED because the --without-tag flag is not yet parsed by the script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-list-epics.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-sprint-list-epics-without-tag.sh ==="

# ── Helpers ───────────────────────────────────────────────────────────────────

# make_v3_ticket: create a minimal v3 event-sourced epic ticket.
# Args: tracker_dir id title [tags_csv]
#   tags_csv — comma-separated tag string for the CREATE event data.tags field (optional)
make_v3_epic() {
    local tracker_dir="$1" id="$2" title="$3" tags_csv="${4:-}"

    mkdir -p "$tracker_dir/$id"

    local tags_json="[]"
    if [ -n "$tags_csv" ]; then
        # Convert comma-separated string to JSON array
        tags_json=$(python3 -c "
import json, sys
raw = sys.argv[1]
tags = [t.strip() for t in raw.split(',') if t.strip()]
print(json.dumps(tags))
" "$tags_csv")
    fi

    cat > "$tracker_dir/$id/1000000001-aaaa-CREATE.json" << EOF
{"timestamp": 1000000001, "uuid": "aaaa-${id}", "event_type": "CREATE", "data": {"ticket_type": "epic", "title": "${title}", "priority": 2, "tags": ${tags_json}}}
EOF
}

# ── Setup: isolated temp tracker ─────────────────────────────────────────────
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT

# epic-tagged has brainstorm:complete tag — must be EXCLUDED by --without-tag
# epic-untagged has no tags — must be INCLUDED by --without-tag
make_v3_epic "$TDIR" "epic-tagged"   "Tagged Epic"   "brainstorm:complete"
make_v3_epic "$TDIR" "epic-untagged" "Untagged Epic" ""

# ── Test 1: --without-tag=brainstorm:complete excludes tagged epic from output ──
echo "Test 1: test_without_tag_excludes_tagged_epic — tagged epic absent when --without-tag matches"
test_without_tag_excludes_tagged_epic() {
    local out exit_code=0
    out=$(TICKETS_TRACKER_DIR="$TDIR" SPRINT_MAX_RETRIES=0 \
        bash "$SCRIPT" --without-tag=brainstorm:complete 2>/dev/null) || exit_code=$?

    # Exit code must be 0 (at least one unblocked epic found after filtering)
    [ "$exit_code" -eq 0 ] || return 1

    # Untagged epic must appear in output
    [[ "$out" == *epic-untagged* ]] || return 1

    # Tagged epic must NOT appear — this assertion FAILS RED because the flag is unrecognized
    ! [[ "$out" == *epic-tagged* ]] || return 1
}
if test_without_tag_excludes_tagged_epic; then
    echo "  PASS: --without-tag=brainstorm:complete excludes tagged epic"
    (( PASS++ ))
else
    echo "  FAIL: --without-tag=brainstorm:complete did not exclude tagged epic (flag not yet implemented)" >&2
    (( FAIL++ ))
fi

# ── Test 2: --without-tag does not affect epics that don't have the tag ──────
echo "Test 2: test_without_tag_retains_untagged_epic — untagged epic always present when --without-tag used"
test_without_tag_retains_untagged_epic() {
    local out exit_code=0
    out=$(TICKETS_TRACKER_DIR="$TDIR" SPRINT_MAX_RETRIES=0 \
        bash "$SCRIPT" --without-tag=brainstorm:complete 2>/dev/null) || exit_code=$?

    # Untagged epic must appear — this alone can pass even before implementation
    # (because without filtering the flag is ignored and both appear)
    # Combined with Test 1, the pair is only both-passing when filtering is correct.
    [[ "$out" == *epic-untagged* ]] || return 1
}
if test_without_tag_retains_untagged_epic; then
    echo "  PASS: untagged epic retained in output"
    (( PASS++ ))
else
    echo "  FAIL: untagged epic missing from output" >&2
    (( FAIL++ ))
fi

# ── Test 3: Without --without-tag flag, both epics appear (backward compat) ──
echo "Test 3: test_without_tag_flag_absent_both_appear — without the flag, all epics shown"
test_without_tag_flag_absent_both_appear() {
    local out exit_code=0
    out=$(TICKETS_TRACKER_DIR="$TDIR" SPRINT_MAX_RETRIES=0 \
        bash "$SCRIPT" 2>/dev/null) || exit_code=$?

    [ "$exit_code" -eq 0 ] || return 1
    # Both epics must appear when no tag filter is active
    [[ "$out" == *epic-tagged* ]]   || return 1
    [[ "$out" == *epic-untagged* ]] || return 1
}
if test_without_tag_flag_absent_both_appear; then
    echo "  PASS: both epics shown when --without-tag is not used"
    (( PASS++ ))
else
    echo "  FAIL: expected both epics without flag — backward compat broken" >&2
    (( FAIL++ ))
fi

# ── Test 4: exit code 1 when --without-tag filters out all epics ─────────────
echo "Test 4: test_without_tag_all_filtered_exits_1 — exit 1 when all epics match the excluded tag"
test_without_tag_all_filtered_exits_1() {
    local TDIR4
    TDIR4=$(mktemp -d)
    trap 'rm -rf "$TDIR4"' RETURN

    # Only one epic and it has the tag — after filtering, nothing remains
    make_v3_epic "$TDIR4" "epic-only-tagged" "Only Tagged Epic" "brainstorm:complete"

    local exit_code=0
    TICKETS_TRACKER_DIR="$TDIR4" SPRINT_MAX_RETRIES=0 \
        bash "$SCRIPT" --without-tag=brainstorm:complete >/dev/null 2>&1 || exit_code=$?

    # Must exit 1 (no open epics after filtering) — FAILS RED because flag is not parsed
    [ "$exit_code" -eq 1 ] || return 1
}
if test_without_tag_all_filtered_exits_1; then
    echo "  PASS: exit 1 when --without-tag filters all epics"
    (( PASS++ ))
else
    echo "  FAIL: expected exit 1 when all epics filtered by --without-tag (flag not yet implemented)" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
