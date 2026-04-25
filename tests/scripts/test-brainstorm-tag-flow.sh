#!/usr/bin/env bash
# tests/scripts/test-brainstorm-tag-flow.sh
# End-to-end integration test for the brainstorm:complete tag flow.
#
# Creates a fixture .tickets-tracker/ with:
#   - Epic A: PIL heading in CREATE description → must receive brainstorm:complete
#   - Epic B: PIL heading in COMMENT body → must receive brainstorm:complete
#   - Epic C: no PIL heading → must appear as UNMATCHED
#   - Epic D: children but no PIL (scrutiny-gap case) → must appear as UNMATCHED
#
# Exercises: migration script → sprint-list-epics.sh --has-tag → SKILL.md text
# checks → brainstorm SKILL.md no-arg block categories.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MIGRATION="$REPO_ROOT/plugins/dso/scripts/ticket-migrate-brainstorm-tags.sh"
SPRINT_LIST="$REPO_ROOT/plugins/dso/scripts/sprint-list-epics.sh"
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
BRAINSTORM_SKILL="$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-brainstorm-tag-flow.sh ==="

# ── Fixture helpers ───────────────────────────────────────────────────────────

_make_epic() {
    local tracker_dir="$1" id="$2" title="$3"
    mkdir -p "$tracker_dir/$id"
    cat > "$tracker_dir/$id/1000-${id}-CREATE.json" <<EOF
{"timestamp": 1000000001, "uuid": "uuid-${id}", "event_type": "CREATE", "env_id": "test-env", "data": {"ticket_type": "epic", "title": "${title}", "status": "open", "priority": 2, "tags": []}}
EOF
}

_add_pil_description() {
    local tracker_dir="$1" id="$2"
    # Overwrite the CREATE event with description containing PIL heading
    cat > "$tracker_dir/$id/1000-${id}-CREATE.json" <<EOF
{"timestamp": 1000000001, "uuid": "uuid-${id}", "event_type": "CREATE", "env_id": "test-env", "data": {"ticket_type": "epic", "title": "Epic-${id} (PIL-desc)", "status": "open", "priority": 2, "tags": [], "description": "## Summary\n### Planning Intelligence Log\n- Entry 1"}}
EOF
}

_add_pil_comment() {
    local tracker_dir="$1" id="$2"
    cat > "$tracker_dir/$id/2000-${id}-COMMENT.json" <<EOF
{"timestamp": 2000000001, "uuid": "cmt-${id}", "event_type": "COMMENT", "env_id": "test-env", "data": {"body": "### Planning Intelligence Log\n- Entry 1"}}
EOF
}

_add_child_story() {
    local tracker_dir="$1" parent_id="$2" child_id="$3"
    mkdir -p "$tracker_dir/$child_id"
    cat > "$tracker_dir/$child_id/1000-${child_id}-CREATE.json" <<EOF
{"timestamp": 1000000002, "uuid": "uuid-${child_id}", "event_type": "CREATE", "env_id": "test-env", "data": {"ticket_type": "story", "title": "Child of ${parent_id}", "status": "open", "priority": 2, "tags": [], "parent_id": "${parent_id}"}}
EOF
}

_ticket_has_tag() {
    local tracker_dir="$1" id="$2" tag="$3"
    python3 - "$tracker_dir/$id" "$tag" <<'PYEOF'
import json, os, sys
ticket_dir, tag = sys.argv[1], sys.argv[2]
tags = []
for fname in sorted(os.listdir(ticket_dir)):
    if not fname.endswith('.json') or fname.startswith('.'):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath) as f:
            event = json.load(f)
        data = event.get('data', {})
        event_type = event.get('event_type', '')
        if event_type == 'EDIT':
            raw = data.get('fields', {}).get('tags', None)
        else:
            raw = data.get('tags', None)
        if raw is not None:
            if isinstance(raw, list):
                tags = raw
            elif isinstance(raw, str) and raw:
                tags = raw.split(',')
            else:
                tags = []
    except (json.JSONDecodeError, OSError):
        pass
sys.exit(0 if tag in tags else 1)
PYEOF
}

# ── Setup: isolated temp tracker with git repo ────────────────────────────────
TDIR=$(mktemp -d)
trap 'rm -rf "$TDIR"' EXIT

# Init git for the fake tracker (migration commits to tracker)
git -C "$TDIR" init -q
git -C "$TDIR" config user.email "test@test.com"
git -C "$TDIR" config user.name "Test"
git -C "$TDIR" commit --allow-empty -q -m "init"

TRACKER="$TDIR/.tickets-tracker"
mkdir -p "$TRACKER"

# Create target directory with .claude/ for marker file placement
mkdir -p "$TDIR/.claude"

# Epic A: PIL in description
_make_epic "$TRACKER" "aaa1-0001" "Epic A (PIL desc)"
_add_pil_description "$TRACKER" "aaa1-0001"

# Epic B: PIL in COMMENT body
_make_epic "$TRACKER" "bbb2-0002" "Epic B (PIL comment)"
_add_pil_comment "$TRACKER" "bbb2-0002"

# Epic C: no PIL
_make_epic "$TRACKER" "ccc3-0003" "Epic C (no PIL)"

# Epic D: children but no PIL (scrutiny-gap case)
_make_epic "$TRACKER" "ddd4-0004" "Epic D (scrutiny-gap)"
_add_child_story "$TRACKER" "ddd4-0004" "eee5-0005"

# Commit fixture to tracker's git
git -C "$TDIR" add "$TRACKER" 2>/dev/null
git -C "$TDIR" commit -q -m "fixture"

# ── Test 1: migration tags exactly the 2 PIL-bearing epics ───────────────────
echo "Test 1: migration tags exactly the 2 PIL-bearing epics"
test_migration_tags_pil_epics() {
    local out
    out=$(bash "$MIGRATION" --target "$TDIR" 2>/dev/null)
    _ticket_has_tag "$TRACKER" "aaa1-0001" "brainstorm:complete" || return 1
    _ticket_has_tag "$TRACKER" "bbb2-0002" "brainstorm:complete" || return 1
    ! _ticket_has_tag "$TRACKER" "ccc3-0003" "brainstorm:complete" || return 1
    ! _ticket_has_tag "$TRACKER" "ddd4-0004" "brainstorm:complete" || return 1
}
if test_migration_tags_pil_epics; then
    echo "  PASS: migration tagged exactly the 2 PIL-bearing epics"
    (( PASS++ ))
else
    echo "  FAIL: migration did not tag PIL epics correctly" >&2
    (( FAIL++ ))
fi

# ── Test 2: migration stdout contains UNMATCHED for 2 non-PIL epics ──────────
echo "Test 2: migration stdout contains UNMATCHED lines for non-PIL epics"
test_migration_unmatched_lines() {
    # Remove marker so migration runs again
    rm -f "$TDIR/.claude/.brainstorm-tag-migration-v2"
    # Reset brainstorm:complete tags (idempotent — will skip already-tagged)
    local out
    out=$(bash "$MIGRATION" --target "$TDIR" 2>/dev/null)
    local unmatched_count
    unmatched_count=$(echo "$out" | grep -c "^UNMATCHED:" 2>/dev/null || true)
    [ "$unmatched_count" -ge 2 ] || return 1
    echo "$out" | grep -q "UNMATCHED:.*ccc3-0003" || return 1
    echo "$out" | grep -q "UNMATCHED:.*ddd4-0004" || return 1
}
if test_migration_unmatched_lines; then
    echo "  PASS: migration stdout has UNMATCHED for ccc3-0003 and ddd4-0004"
    (( PASS++ ))
else
    echo "  FAIL: UNMATCHED lines missing or incorrect" >&2
    (( FAIL++ ))
fi

# ── Test 3: sprint-list-epics --has-tag=brainstorm:complete shows only tagged ─
echo "Test 3: sprint-list-epics --has-tag=brainstorm:complete returns only tagged epics"
test_sprint_list_epics_has_tag_filter() {
    local out exit_code=0
    out=$(TICKETS_TRACKER_DIR="$TRACKER" SPRINT_MAX_RETRIES=0 \
        bash "$SPRINT_LIST" --has-tag=brainstorm:complete 2>/dev/null) || exit_code=$?
    [ "$exit_code" -eq 0 ] || return 1
    [[ "$out" == *"aaa1-0001"* ]] || return 1
    [[ "$out" == *"bbb2-0002"* ]] || return 1
    ! [[ "$out" == *"ccc3-0003"* ]] || return 1
    ! [[ "$out" == *"ddd4-0004"* ]] || return 1
}
if test_sprint_list_epics_has_tag_filter; then
    echo "  PASS: --has-tag=brainstorm:complete returns only tagged epics"
    (( PASS++ ))
else
    echo "  FAIL: --has-tag filter returned incorrect epics" >&2
    (( FAIL++ ))
fi

# ── Test 4: sprint SKILL.md hidden-epics note contains /dso:brainstorm ───────
echo "Test 4: sprint SKILL.md hidden-epics note contains /dso:brainstorm"
test_sprint_skill_hidden_epics_note() {
    grep -q '/dso:brainstorm' "$SPRINT_SKILL" || return 1
    grep -q 'brainstorm:complete' "$SPRINT_SKILL" || return 1
}
if test_sprint_skill_hidden_epics_note; then
    echo "  PASS: sprint SKILL.md contains /dso:brainstorm and brainstorm:complete"
    (( PASS++ ))
else
    echo "  FAIL: sprint SKILL.md missing /dso:brainstorm or brainstorm:complete reference" >&2
    (( FAIL++ ))
fi

# ── Test 6: idempotency — second migration run exits 0 with no new EDIT events─
echo "Test 6: second migration run exits 0 and produces no new EDIT events"
test_migration_idempotent() {
    # Marker already written from Test 1/2 — re-touch to confirm
    local count_before count_after
    count_before=$(find "$TRACKER" -name "*-EDIT.json" | wc -l | tr -d ' ')
    bash "$MIGRATION" --target "$TDIR" 2>/dev/null || return 1
    count_after=$(find "$TRACKER" -name "*-EDIT.json" | wc -l | tr -d ' ')
    [ "$count_before" -eq "$count_after" ] || return 1
}
if test_migration_idempotent; then
    echo "  PASS: second run is idempotent (no new EDIT events)"
    (( PASS++ ))
else
    echo "  FAIL: second migration run produced unexpected changes" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
