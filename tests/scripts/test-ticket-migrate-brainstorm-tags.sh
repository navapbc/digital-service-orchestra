#!/usr/bin/env bash
# tests/scripts/test-ticket-migrate-brainstorm-tags.sh
# Behavioral fixture test for plugins/dso/scripts/ticket-migrate-brainstorm-tags.sh
#
# These tests are RED — the migration script does not yet exist.
# Tests MUST FAIL until ticket-migrate-brainstorm-tags.sh is implemented (task 3c41-04fc).
#
# Test structure:
#   - 2 epics with "### Planning Intelligence Log" heading (one in CREATE description,
#     one in a COMMENT event JSON file body)
#   - 1 epic with no PIL heading
#
# Assertions:
#   1. Migration exits 0
#   2. 2 PIL-bearing epics get brainstorm:complete tag added (inspect tracker state)
#   3. UNMATCHED: <epic-id> printed to stdout for the 1 non-PIL epic
#   4. Marker file .claude/.brainstorm-tag-migration-v1 written at repo root
#   5. Re-run exits 0 immediately (marker present) with no new tracker changes
#   6. Plugin-source-repo guard: exits 0 with a logged notice, no changes
#
# Usage: bash tests/scripts/test-ticket-migrate-brainstorm-tags.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
MIGRATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-migrate-brainstorm-tags.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-migrate-brainstorm-tags.sh ==="

# ── Suite-runner guard: skip when migration script does not exist ─────────────
# RED tests fail by design (script not found). When auto-discovered by
# run-script-tests.sh, they would break `bash tests/run-all.sh`. Skip with
# exit 0 when ticket-migrate-brainstorm-tags.sh is absent AND running under the suite runner.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && [ ! -f "$MIGRATE_SCRIPT" ]; then
    echo "SKIP: ticket-migrate-brainstorm-tags.sh not yet implemented (RED) — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: write an event file directly to a ticket dir ─────────────────────
# Usage: _write_event <ticket_dir> <timestamp> <uuid> <event_type> <data_json>
_write_event() {
    local ticket_dir="$1"
    local timestamp="$2"
    local uuid="$3"
    local event_type="$4"
    local data_json="$5"
    local env_id="${6:-00000000-0000-4000-8000-000000000001}"
    local author="${7:-Test User}"
    local filename="${timestamp}-${uuid}-${event_type}.json"

    python3 -c "
import json, sys
payload = {
    'timestamp': $timestamp,
    'uuid': '$uuid',
    'event_type': '$event_type',
    'env_id': '$env_id',
    'author': '$author',
    'data': json.loads(sys.argv[1])
}
json.dump(payload, sys.stdout)
" "$data_json" > "$ticket_dir/$filename"
}

# ── Helper: set up the 3-epic fixture in a tracker dir ───────────────────────
# Returns: sets EPIC_PIL_DESC_ID, EPIC_PIL_COMMENT_ID, EPIC_NO_PIL_ID in caller scope
_setup_epic_fixture() {
    local tracker_dir="$1"

    # Epic 1: PIL heading in the CREATE event description field
    EPIC_PIL_DESC_ID="epic-pil-desc-01"
    local dir1="$tracker_dir/$EPIC_PIL_DESC_ID"
    mkdir -p "$dir1"
    local desc1
    desc1='{"ticket_type": "epic", "title": "Epic with PIL in description", "parent_id": null, "description": "## Background\n\nThis epic has implementation notes.\n\n### Planning Intelligence Log\n\nSome brainstorm notes here."}'
    _write_event "$dir1" "1742605100" "00000000-0000-4000-8000-pil001desc001" "CREATE" "$desc1"

    # Epic 2: PIL heading appears in a COMMENT event body (not in description)
    EPIC_PIL_COMMENT_ID="epic-pil-comment-02"
    local dir2="$tracker_dir/$EPIC_PIL_COMMENT_ID"
    mkdir -p "$dir2"
    local create2
    create2='{"ticket_type": "epic", "title": "Epic with PIL in comment", "parent_id": null, "description": "Regular description, no PIL here."}'
    _write_event "$dir2" "1742605200" "00000000-0000-4000-8000-pil002cre001" "CREATE" "$create2"
    # COMMENT event whose body contains the PIL heading
    local comment2
    comment2='{"body": "### Planning Intelligence Log\n\nBrainstorm findings captured during sprint planning."}'
    _write_event "$dir2" "1742605300" "00000000-0000-4000-8000-pil002cmt001" "COMMENT" "$comment2"

    # Epic 3: No PIL heading anywhere
    EPIC_NO_PIL_ID="epic-no-pil-003"
    local dir3="$tracker_dir/$EPIC_NO_PIL_ID"
    mkdir -p "$dir3"
    local create3
    create3='{"ticket_type": "epic", "title": "Epic without PIL", "parent_id": null, "description": "This epic has no planning intelligence log."}'
    _write_event "$dir3" "1742605400" "00000000-0000-4000-8000-nopil03cr001" "CREATE" "$create3"
}

# ── Helper: check if a tracker ticket has a given tag ────────────────────────
# Reads EDIT events and/or SNAPSHOT for tags; returns 0 if tag found, 1 otherwise.
_ticket_has_tag() {
    local tracker_dir="$1"
    local ticket_id="$2"
    local tag="$3"
    local ticket_dir="$tracker_dir/$ticket_id"

    # Check all JSON event files for a tags field containing the target tag
    python3 - "$ticket_dir" "$tag" <<'PYEOF'
import json, os, sys

ticket_dir = sys.argv[1]
target_tag = sys.argv[2]

if not os.path.isdir(ticket_dir):
    sys.exit(1)

for fname in sorted(os.listdir(ticket_dir)):
    if not fname.endswith('.json') or fname.startswith('.'):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath) as f:
            event = json.load(f)
        data = event.get('data', {})
        tags = data.get('tags', None)
        if tags is not None:
            if isinstance(tags, list) and target_tag in tags:
                sys.exit(0)
            if isinstance(tags, str) and target_tag in tags.split(','):
                sys.exit(0)
    except (json.JSONDecodeError, OSError):
        pass

sys.exit(1)
PYEOF
}

# ── Helper: count EDIT events that set brainstorm:complete tag ───────────────
_count_brainstorm_tag_edits() {
    local tracker_dir="$1"
    local ticket_id="$2"
    local ticket_dir="$tracker_dir/$ticket_id"

    python3 - "$ticket_dir" <<'PYEOF'
import json, os, sys

ticket_dir = sys.argv[1]
count = 0

if not os.path.isdir(ticket_dir):
    print(0)
    sys.exit(0)

for fname in sorted(os.listdir(ticket_dir)):
    if not fname.endswith('-EDIT.json') or fname.startswith('.'):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath) as f:
            event = json.load(f)
        data = event.get('data', {})
        tags = data.get('tags', None)
        if tags is not None:
            tag_list = tags if isinstance(tags, list) else tags.split(',')
            if 'brainstorm:complete' in tag_list:
                count += 1
    except (json.JSONDecodeError, OSError):
        pass

print(count)
PYEOF
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Migration script must exist (RED gate)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: migration script exists"
test_migration_script_exists() {
    if [ -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "ticket-migrate-brainstorm-tags.sh exists" "exists" "exists"
    else
        assert_eq "ticket-migrate-brainstorm-tags.sh exists" "exists" "missing"
    fi
}
test_migration_script_exists

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: Migration exits 0 when run against the 3-epic fixture
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: migration exits 0 with 3-epic fixture"
test_migration_exits_zero() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migration script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    _setup_epic_fixture "$repo/.tickets-tracker"

    local exit_code=0
    (cd "$repo" && bash "$MIGRATE_SCRIPT") >/dev/null 2>&1 || exit_code=$?
    assert_eq "migration exits 0" "0" "$exit_code"

    assert_pass_if_clean "test_migration_exits_zero"
}
test_migration_exits_zero

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: 2 PIL-bearing epics get brainstorm:complete tag added
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: 2 PIL-bearing epics get brainstorm:complete tag"
test_pil_epics_get_brainstorm_tag() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migration script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_epic_fixture "$repo/.tickets-tracker"

    (cd "$repo" && bash "$MIGRATE_SCRIPT") >/dev/null 2>&1 || true

    # Epic 1 (PIL in description) must have brainstorm:complete tag
    if _ticket_has_tag "$repo/.tickets-tracker" "$EPIC_PIL_DESC_ID" "brainstorm:complete"; then
        assert_eq "epic-pil-desc: has brainstorm:complete tag" "tagged" "tagged"
    else
        assert_eq "epic-pil-desc: has brainstorm:complete tag" "tagged" "not-tagged"
    fi

    # Epic 2 (PIL in comment) must have brainstorm:complete tag
    if _ticket_has_tag "$repo/.tickets-tracker" "$EPIC_PIL_COMMENT_ID" "brainstorm:complete"; then
        assert_eq "epic-pil-comment: has brainstorm:complete tag" "tagged" "tagged"
    else
        assert_eq "epic-pil-comment: has brainstorm:complete tag" "tagged" "not-tagged"
    fi

    # Epic 3 (no PIL) must NOT have brainstorm:complete tag
    if _ticket_has_tag "$repo/.tickets-tracker" "$EPIC_NO_PIL_ID" "brainstorm:complete"; then
        assert_eq "epic-no-pil: must NOT have brainstorm:complete tag" "not-tagged" "tagged"
    else
        assert_eq "epic-no-pil: must NOT have brainstorm:complete tag" "not-tagged" "not-tagged"
    fi

    assert_pass_if_clean "test_pil_epics_get_brainstorm_tag"
}
test_pil_epics_get_brainstorm_tag

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: UNMATCHED: <epic-id> printed to stdout for the non-PIL epic
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: UNMATCHED line printed for non-PIL epic"
test_unmatched_printed_for_non_pil_epic() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migration script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_epic_fixture "$repo/.tickets-tracker"

    local output
    output=$(cd "$repo" && bash "$MIGRATE_SCRIPT" 2>/dev/null) || true

    # Must contain "UNMATCHED: epic-no-pil-003"
    assert_contains "stdout contains UNMATCHED line for non-PIL epic" \
        "UNMATCHED: $EPIC_NO_PIL_ID" "$output"

    # PIL epics must NOT appear in UNMATCHED output
    local unmatched_lines
    unmatched_lines=$(printf '%s\n' "$output" | grep '^UNMATCHED:' || true)
    local unmatched_count
    unmatched_count=$(printf '%s\n' "$unmatched_lines" | grep -c . || echo "0")
    assert_eq "exactly 1 UNMATCHED line printed" "1" "$unmatched_count"

    assert_pass_if_clean "test_unmatched_printed_for_non_pil_epic"
}
test_unmatched_printed_for_non_pil_epic

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: Marker file .claude/.brainstorm-tag-migration-v1 written at repo root
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: marker file written at repo root after migration"
test_marker_file_written() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migration script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_epic_fixture "$repo/.tickets-tracker"
    mkdir -p "$repo/.claude"

    (cd "$repo" && bash "$MIGRATE_SCRIPT") >/dev/null 2>&1 || true

    if [ -f "$repo/.claude/.brainstorm-tag-migration-v1" ]; then
        assert_eq "marker file written" "exists" "exists"
    else
        assert_eq "marker file written" "exists" "missing"
    fi

    assert_pass_if_clean "test_marker_file_written"
}
test_marker_file_written

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: Re-run exits 0 immediately with no new tracker changes (marker present)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: re-run with marker present exits 0 with no new tracker changes"
test_rerun_with_marker_is_noop() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migration script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_epic_fixture "$repo/.tickets-tracker"
    mkdir -p "$repo/.claude"

    # First run — performs migration
    (cd "$repo" && bash "$MIGRATE_SCRIPT") >/dev/null 2>&1 || true

    # Record EDIT event counts after first run
    local edits_before_pil_desc edits_before_pil_comment edits_before_no_pil
    edits_before_pil_desc=$(_count_brainstorm_tag_edits "$repo/.tickets-tracker" "$EPIC_PIL_DESC_ID")
    edits_before_pil_comment=$(_count_brainstorm_tag_edits "$repo/.tickets-tracker" "$EPIC_PIL_COMMENT_ID")
    edits_before_no_pil=$(_count_brainstorm_tag_edits "$repo/.tickets-tracker" "$EPIC_NO_PIL_ID")

    # Second run — marker is present, must exit 0 and write no new events
    local exit2=0
    (cd "$repo" && bash "$MIGRATE_SCRIPT") >/dev/null 2>&1 || exit2=$?
    assert_eq "re-run exits 0 with marker present" "0" "$exit2"

    # EDIT event counts must be unchanged after second run
    local edits_after_pil_desc edits_after_pil_comment edits_after_no_pil
    edits_after_pil_desc=$(_count_brainstorm_tag_edits "$repo/.tickets-tracker" "$EPIC_PIL_DESC_ID")
    edits_after_pil_comment=$(_count_brainstorm_tag_edits "$repo/.tickets-tracker" "$EPIC_PIL_COMMENT_ID")
    edits_after_no_pil=$(_count_brainstorm_tag_edits "$repo/.tickets-tracker" "$EPIC_NO_PIL_ID")

    assert_eq "re-run: no new EDIT events on pil-desc epic" \
        "$edits_before_pil_desc" "$edits_after_pil_desc"
    assert_eq "re-run: no new EDIT events on pil-comment epic" \
        "$edits_before_pil_comment" "$edits_after_pil_comment"
    assert_eq "re-run: no new EDIT events on no-pil epic" \
        "$edits_before_no_pil" "$edits_after_no_pil"

    assert_pass_if_clean "test_rerun_with_marker_is_noop"
}
test_rerun_with_marker_is_noop

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: Plugin-source-repo guard — exits 0 with notice, no changes
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: plugin-source-repo guard exits 0 with notice and makes no changes"
test_plugin_source_repo_guard() {
    _snapshot_fail

    if [ ! -f "$MIGRATE_SCRIPT" ]; then
        assert_eq "migration script exists (prereq)" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _setup_epic_fixture "$repo/.tickets-tracker"
    mkdir -p "$repo/.claude"

    # Simulate being inside the plugin source repo by placing plugin.json at repo root
    # (The migration script should detect this sentinel and exit without making changes)
    touch "$repo/plugin.json"

    local exit_code=0
    local output
    output=$(cd "$repo" && bash "$MIGRATE_SCRIPT" 2>&1) || exit_code=$?

    assert_eq "plugin-source-repo guard: exits 0" "0" "$exit_code"

    # Must emit a notice (not silently exit)
    if [ -n "$output" ]; then
        assert_eq "plugin-source-repo guard: emits a notice" "notice-emitted" "notice-emitted"
    else
        assert_eq "plugin-source-repo guard: emits a notice" "notice-emitted" "silent-exit"
    fi

    # Marker file must NOT be written (guard bailed before making changes)
    if [ -f "$repo/.claude/.brainstorm-tag-migration-v1" ]; then
        assert_eq "plugin-source-repo guard: marker NOT written" "not-written" "written"
    else
        assert_eq "plugin-source-repo guard: marker NOT written" "not-written" "not-written"
    fi

    # No brainstorm:complete tags must have been added to any epic
    if _ticket_has_tag "$repo/.tickets-tracker" "$EPIC_PIL_DESC_ID" "brainstorm:complete"; then
        assert_eq "plugin-source-repo guard: pil-desc epic NOT tagged" "not-tagged" "tagged"
    else
        assert_eq "plugin-source-repo guard: pil-desc epic NOT tagged" "not-tagged" "not-tagged"
    fi

    if _ticket_has_tag "$repo/.tickets-tracker" "$EPIC_PIL_COMMENT_ID" "brainstorm:complete"; then
        assert_eq "plugin-source-repo guard: pil-comment epic NOT tagged" "not-tagged" "tagged"
    else
        assert_eq "plugin-source-repo guard: pil-comment epic NOT tagged" "not-tagged" "not-tagged"
    fi

    assert_pass_if_clean "test_plugin_source_repo_guard"
}
test_plugin_source_repo_guard

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
