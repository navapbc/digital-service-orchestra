#!/usr/bin/env bash
# tests/scripts/test-archive-tombstone.sh
# RED tests for tombstone file creation in archive-closed-tickets.sh.
#
# Story: w20-qxu2 — RED test: tombstone file written on archive
# Epic:  w21-6llo  — As a developer, I can archive closed tickets without
#                    breaking dependency references
#
# These tests MUST FAIL (RED) until w20-v9eo implements tombstone write in
# archive-closed-tickets.sh. Currently the archiver moves ticket .md files
# but does NOT write .tickets/archive/tombstones/<id>.json files.
# After implementation the archiver must create exactly-3-field JSON tombstones
# atomically for each ticket moved to .tickets/archive/.
#
# Contract: plugins/dso/docs/contracts/tombstone-archive-format.md
#
# Usage: bash tests/scripts/test-archive-tombstone.sh
# Returns: exit non-zero (RED) until archive-closed-tickets.sh writes tombstones.
#
# Suite-runner guard: when _RUN_ALL_ACTIVE=1 and tombstone write is not yet
# implemented in archive-closed-tickets.sh, exits 0 with a SKIP message so
# that run-all.sh continues to pass during the RED phase.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
ARCHIVE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/archive-closed-tickets.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-archive-tombstone.sh ==="

# ── Suite-runner guard ─────────────────────────────────────────────────────
# RED tests fail by design (tombstone write not yet implemented).
# When auto-discovered by run-script-tests.sh (_RUN_ALL_ACTIVE=1), skip with
# exit 0 so the full suite remains green during the RED phase.
# Detection: grep for "tombstone" write logic inside archive-closed-tickets.sh.
# The implementation must reference "tombstones" in the archive write section.
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ]; then
    if ! grep -q "tombstones" "$ARCHIVE_SCRIPT" 2>/dev/null; then
        echo "SKIP: archive-closed-tickets.sh tombstone write not yet implemented (RED) — tests deferred"
        echo ""
        printf "PASSED: 0  FAILED: 0\n"
        exit 0
    fi
fi

# ── Temp dir cleanup ───────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Helper: create a minimal closed ticket .md file ───────────────────────
# Usage: _make_ticket <dir> <id> <status> <type> [deps]
_make_ticket() {
    local dir="$1" id="$2" status="$3" type="$4" deps="${5:-[]}"
    cat > "$dir/${id}.md" <<EOF
---
id: ${id}
status: ${status}
deps: ${deps}
links: []
created: 2026-01-01T00:00:00Z
type: ${type}
priority: 2
---
# Ticket ${id}
EOF
}

# ── Helper: make a temp tickets dir ───────────────────────────────────────
_make_tickets_dir() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: test_tombstone_created_on_archive
#
# When a closed ticket is archived, a tombstone JSON file must appear at
# .tickets/archive/tombstones/<id>.json. Currently archive-closed-tickets.sh
# does NOT create tombstone files, so this test MUST FAIL (RED).
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_tombstone_created_on_archive"
_snapshot_fail

TICKETS_DIR=$(_make_tickets_dir)
_make_ticket "$TICKETS_DIR" "arch-001" "closed" "task"

TICKETS_DIR="$TICKETS_DIR" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

tombstone_path="$TICKETS_DIR/archive/tombstones/arch-001.json"
assert_eq \
    "test_tombstone_created_on_archive: tombstone file exists after archive" \
    "1" \
    "$(test -f "$tombstone_path" && echo 1 || echo 0)"

assert_pass_if_clean "test_tombstone_created_on_archive"

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: test_tombstone_not_created_for_protected_ticket
#
# A closed ticket that is protected (depended on by an open ticket) must NOT
# be moved to archive/ and must NOT receive a tombstone. Currently the archiver
# correctly skips the move, but we assert here that no tombstone appears either.
# This test would pass today by accident (no tombstone written at all), but
# combined with test 1 it will drive the correct conditional write in the impl.
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_tombstone_not_created_for_protected_ticket"
_snapshot_fail

TICKETS_DIR=$(_make_tickets_dir)
# dep-001 is closed but open-001 depends on it → protected from archival
_make_ticket "$TICKETS_DIR" "dep-001"  "closed" "task" "[]"
_make_ticket "$TICKETS_DIR" "open-001" "open"   "task" "[dep-001]"

TICKETS_DIR="$TICKETS_DIR" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

protected_tombstone="$TICKETS_DIR/archive/tombstones/dep-001.json"
assert_eq \
    "test_tombstone_not_created_for_protected_ticket: no tombstone for protected ticket" \
    "0" \
    "$(test -f "$protected_tombstone" && echo 1 || echo 0)"

assert_pass_if_clean "test_tombstone_not_created_for_protected_ticket"

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: test_tombstone_format_valid_json (exactly 3 fields)
#
# The tombstone JSON must be valid, must contain exactly 3 top-level keys
# (id, type, final_status), and must contain no extra fields. Per the contract:
#   plugins/dso/docs/contracts/tombstone-archive-format.md
# Currently no tombstone is written, so this test MUST FAIL (RED).
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_tombstone_format_valid_json"
_snapshot_fail

TICKETS_DIR=$(_make_tickets_dir)
_make_ticket "$TICKETS_DIR" "arch-002" "closed" "story"

TICKETS_DIR="$TICKETS_DIR" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

tombstone_path="$TICKETS_DIR/archive/tombstones/arch-002.json"

# Assert tombstone exists first (prerequisite for field-count check)
if [ ! -f "$tombstone_path" ]; then
    assert_eq \
        "test_tombstone_format_valid_json: tombstone file must exist" \
        "exists" "missing"
else
    # Assert: valid JSON with exactly 3 top-level keys
    field_count=$(python3 -c "
import json, sys
try:
    with open('$tombstone_path') as f:
        data = json.load(f)
    print(len(data.keys()))
except Exception as e:
    print('parse_error:' + str(e))
    sys.exit(1)
" 2>&1)
    assert_eq \
        "test_tombstone_format_valid_json: exactly 3 top-level fields" \
        "3" "$field_count"

    # Assert: all 3 required keys are present
    required_keys=$(python3 -c "
import json, sys
with open('$tombstone_path') as f:
    data = json.load(f)
required = {'id', 'type', 'final_status'}
present = set(data.keys())
missing = required - present
extra = present - required
if missing:
    print('missing_keys:' + ','.join(sorted(missing)))
elif extra:
    print('extra_keys:' + ','.join(sorted(extra)))
else:
    print('ok')
" 2>&1)
    assert_eq \
        "test_tombstone_format_valid_json: required keys id/type/final_status present, no extras" \
        "ok" "$required_keys"
fi

assert_pass_if_clean "test_tombstone_format_valid_json"

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: test_tombstone_final_status_correct
#
# The tombstone must record:
#   - id:           the ticket ID (matching the filename stem)
#   - type:         the ticket type from the source .md frontmatter
#   - final_status: "closed"
#
# Currently no tombstone is written, so this test MUST FAIL (RED).
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "test_tombstone_final_status_correct"
_snapshot_fail

TICKETS_DIR=$(_make_tickets_dir)
_make_ticket "$TICKETS_DIR" "arch-003" "closed" "epic"

TICKETS_DIR="$TICKETS_DIR" bash "$ARCHIVE_SCRIPT" >/dev/null 2>&1 || true

tombstone_path="$TICKETS_DIR/archive/tombstones/arch-003.json"

if [ ! -f "$tombstone_path" ]; then
    assert_eq \
        "test_tombstone_final_status_correct: tombstone file must exist" \
        "exists" "missing"
else
    # Assert id field matches ticket ID
    id_val=$(python3 -c "
import json
with open('$tombstone_path') as f:
    data = json.load(f)
print(data.get('id', 'MISSING'))
" 2>&1)
    assert_eq \
        "test_tombstone_final_status_correct: id field equals ticket id" \
        "arch-003" "$id_val"

    # Assert type field matches ticket type from frontmatter
    type_val=$(python3 -c "
import json
with open('$tombstone_path') as f:
    data = json.load(f)
print(data.get('type', 'MISSING'))
" 2>&1)
    assert_eq \
        "test_tombstone_final_status_correct: type field matches source ticket type 'epic'" \
        "epic" "$type_val"

    # Assert final_status is "closed"
    fs_val=$(python3 -c "
import json
with open('$tombstone_path') as f:
    data = json.load(f)
print(data.get('final_status', 'MISSING'))
" 2>&1)
    assert_eq \
        "test_tombstone_final_status_correct: final_status is 'closed'" \
        "closed" "$fs_val"

    # Assert id matches filename stem (integrity invariant from contract)
    stem="arch-003"
    assert_eq \
        "test_tombstone_final_status_correct: id field matches filename stem" \
        "$stem" "$id_val"
fi

assert_pass_if_clean "test_tombstone_final_status_correct"

# ── Summary ────────────────────────────────────────────────────────────────

print_summary
