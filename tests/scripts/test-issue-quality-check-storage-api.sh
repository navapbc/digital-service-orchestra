#!/usr/bin/env bash
# tests/scripts/test-issue-quality-check-storage-api.sh
# RED tests for issue-quality-check.sh storage-API refactor.
#
# These tests assert behavior AFTER issue-quality-check.sh is refactored to use
# `ticket get-file-impact` as the primary source for file impact item count
# (falling back to markdown awk parsing when get-file-impact returns []).
# All new assertions FAIL in the current (pre-refactor) state.
#
# Tests:
#   a. When `ticket get-file-impact <id>` returns a non-empty array,
#      file_impact_items count is non-zero → quality check passes for that
#      dimension even with no markdown ## File Impact section
#
# Usage: bash tests/scripts/test-issue-quality-check-storage-api.sh
# Returns: exit 0 if all pass (once GREEN), exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1
SCRIPT="$REPO_ROOT/plugins/dso/scripts/issue-quality-check.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

echo "=== test-issue-quality-check-storage-api.sh ==="

# ── Helper: create a mock ticket CLI with configurable get-file-impact output ──
# The ticket JSON has enough prose (≥5 lines, ≥1 keyword) for legacy pass,
# but deliberately NO markdown ## File Impact or ## Acceptance Criteria sections.
# This isolates the test to confirm whether get-file-impact is consulted.
#
# Usage: _make_ticket_cli_with_api <dir> <ticket_id> <get_impact_json>
_make_ticket_cli_with_api() {
    local dir="$1"
    local ticket_id="$2"
    local get_impact_json="$3"

    mkdir -p "$dir"

    local impact_file="$dir/get-file-impact-${ticket_id}.json"
    printf '%s\n' "$get_impact_json" > "$impact_file"

    # Build a ticket JSON with rich prose but NO markdown file impact or AC sections
    local ticket_json
    ticket_json=$(python3 -c "
import json, sys
tid = sys.argv[1]
desc = (
    '## Description\n'
    'This task must implement the feature correctly.\n'
    'It should handle edge cases and verify behavior.\n'
    'The implementation must be tested thoroughly.\n'
    'Ensure backward compatibility is maintained.\n'
    'Code must follow project conventions.\n'
    '## Notes\n'
    'No file impact section is present in the markdown description.\n'
    'No acceptance criteria block is present.\n'
)
t = {
    'ticket_id': tid,
    'ticket_type': 'task',
    'status': 'open',
    'title': 'Implement the feature',
    'description': desc,
    'comments': [],
    'deps': []
}
print(json.dumps(t))
" "$ticket_id")

    local ticket_json_file="$dir/ticket-${ticket_id}.json"
    printf '%s\n' "$ticket_json" > "$ticket_json_file"

    cat > "$dir/ticket" << TICKET_SCRIPT
#!/usr/bin/env bash
SUBCMD="\${1:-}"
shift || true
case "\$SUBCMD" in
    show)
        TICKET_ID="\${1:-}"
        TFILE="$dir/ticket-\${TICKET_ID}.json"
        if [[ -f "\$TFILE" ]]; then
            cat "\$TFILE"
            exit 0
        fi
        echo '{}'; exit 1
        ;;
    get-file-impact)
        TICKET_ID="\${1:-}"
        IFILE="$dir/get-file-impact-\${TICKET_ID}.json"
        if [[ -f "\$IFILE" ]]; then
            cat "\$IFILE"
        else
            printf '[]\n'
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TICKET_SCRIPT
    chmod +x "$dir/ticket"
}

# ── Helper: recording version of the ticket CLI ────────────────────────────────
_make_recording_ticket_cli() {
    local dir="$1"
    local ticket_id="$2"
    local get_impact_json="$3"
    local call_log="$4"

    mkdir -p "$dir"

    local impact_file="$dir/get-file-impact-${ticket_id}.json"
    printf '%s\n' "$get_impact_json" > "$impact_file"

    local ticket_json
    ticket_json=$(python3 -c "
import json, sys
tid = sys.argv[1]
desc = (
    '## Description\n'
    'This task must implement the feature correctly.\n'
    'It should handle edge cases and verify behavior.\n'
    'The implementation must be tested thoroughly.\n'
    'Ensure backward compatibility is maintained.\n'
    'Code must follow project conventions.\n'
)
t = {
    'ticket_id': tid,
    'ticket_type': 'task',
    'status': 'open',
    'title': 'Implement the feature',
    'description': desc,
    'comments': [],
    'deps': []
}
print(json.dumps(t))
" "$ticket_id")

    local ticket_json_file="$dir/ticket-${ticket_id}.json"
    printf '%s\n' "$ticket_json" > "$ticket_json_file"

    cat > "$dir/ticket" << TICKET_SCRIPT
#!/usr/bin/env bash
SUBCMD="\${1:-}"
CALL_LOG="$call_log"
shift || true
echo "\$SUBCMD \$*" >> "\$CALL_LOG"
case "\$SUBCMD" in
    show)
        TICKET_ID="\${1:-}"
        TFILE="$dir/ticket-\${TICKET_ID}.json"
        if [[ -f "\$TFILE" ]]; then
            cat "\$TFILE"
            exit 0
        fi
        echo '{}'; exit 1
        ;;
    get-file-impact)
        TICKET_ID="\${1:-}"
        IFILE="$dir/get-file-impact-\${TICKET_ID}.json"
        if [[ -f "\$IFILE" ]]; then
            cat "\$IFILE"
        else
            printf '[]\n'
        fi
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TICKET_SCRIPT
    chmod +x "$dir/ticket"
}

# ── Test a: non-empty get-file-impact → file_impact_items non-zero → quality pass ──
# Set up: a task has NO markdown ## File Impact or ## Acceptance Criteria sections,
# but `ticket get-file-impact` returns a 2-item array.
# After refactor: file_impact_items count is 2 → QUALITY: pass (file impact) path.
# RED (current): issue-quality-check.sh does not call `ticket get-file-impact` at all.
# It counts file_impact_items from the markdown awk pattern → finds 0 items from the
# description (no section). It then falls through to the legacy path (prose check)
# which also passes — but for the wrong reason. The output says "legacy" instead of
# "file impact", and get-file-impact was never consulted.
echo ""
echo "Test a: non-empty get-file-impact → file_impact_items non-zero → quality pass via file impact"

_ta_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta_dir")
_ta_call_log=$(mktemp)
_CLEANUP_DIRS+=("$_ta_call_log")

# get-file-impact returns a non-empty array (2 files)
_ta_impact_json='[{"file":"src/feature.py","reason":"core logic"},{"file":"tests/test_feature.py","reason":"unit tests"}]'
_make_recording_ticket_cli "$_ta_dir" "ta-qcheck-task" "$_ta_impact_json" "$_ta_call_log"

_ta_exit=0
_ta_output=$(TICKET_CMD="$_ta_dir/ticket" bash "$SCRIPT" "ta-qcheck-task" 2>&1) || _ta_exit=$?

# Quality check must pass (exit 0)
assert_eq "api-file-impact: exits 0 (quality pass)" "0" "$_ta_exit"

# KEY RED assertion: output must indicate quality passed via file impact (not legacy)
# Current output (before refactor): "QUALITY: pass (legacy - no AC/file impact) (...)"
# Expected output (after refactor):  "QUALITY: pass (..., 2 file impact)" — no "legacy"
_ta_output_lower=$(echo "$_ta_output" | tr '[:upper:]' '[:lower:]')

_ta_file_impact_in_output=0
echo "$_ta_output" | grep -qiE "file impact" && _ta_file_impact_in_output=1 || true
assert_eq "api-file-impact: output mentions 'file impact' (not legacy-only)" "1" "$_ta_file_impact_in_output"

# KEY RED assertion: the output must NOT say "legacy" when file impact is found via API
_ta_legacy_in_output=0
echo "$_ta_output" | grep -qi "legacy" && _ta_legacy_in_output=1 || true
assert_eq "api-file-impact: output does NOT say 'legacy' (file impact path taken)" "0" "$_ta_legacy_in_output"

# KEY RED assertion: `ticket get-file-impact ta-qcheck-task` must have been called
_ta_gfi_called=0
grep -q "get-file-impact ta-qcheck-task" "$_ta_call_log" && _ta_gfi_called=1 || true
assert_eq "api-file-impact: ticket get-file-impact was called" "1" "$_ta_gfi_called"

# ── Test a2: empty get-file-impact → markdown awk path unchanged ───────────────
# When get-file-impact returns [], the script must fall through to the existing
# markdown awk parsing. A ticket WITH a markdown ## File Impact section must still
# pass via the file impact path (regression guard).
echo ""
echo "Test a2: empty get-file-impact → markdown awk path used as fallback (regression guard)"

_ta2_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta2_dir")

mkdir -p "$_ta2_dir/ticket-bin"

# Build ticket JSON with a markdown ## File Impact section
_ta2_ticket_json=$(python3 -c "
import json, sys
desc = (
    '## Description\n'
    'This task must implement the feature correctly.\n'
    'It should handle edge cases and verify behavior.\n\n'
    '## File Impact\n'
    '- src/feature.py (core logic)\n'
    '- tests/test_feature.py (unit tests)\n'
)
t = {
    'ticket_id': 'ta2-qcheck-task',
    'ticket_type': 'task',
    'status': 'open',
    'title': 'Implement the feature',
    'description': desc,
    'comments': [],
    'deps': []
}
print(json.dumps(t))
")

printf '%s\n' "$_ta2_ticket_json" > "$_ta2_dir/ticket-bin/ticket-ta2-qcheck-task.json"
printf '[]\n' > "$_ta2_dir/ticket-bin/get-file-impact-ta2-qcheck-task.json"

cat > "$_ta2_dir/ticket-bin/ticket" << TICKET_SCRIPT2
#!/usr/bin/env bash
SUBCMD="\${1:-}"
shift || true
case "\$SUBCMD" in
    show)
        TICKET_ID="\${1:-}"
        TFILE="$_ta2_dir/ticket-bin/ticket-\${TICKET_ID}.json"
        [[ -f "\$TFILE" ]] && cat "\$TFILE" && exit 0
        echo '{}'; exit 1
        ;;
    get-file-impact)
        TICKET_ID="\${1:-}"
        IFILE="$_ta2_dir/ticket-bin/get-file-impact-\${TICKET_ID}.json"
        [[ -f "\$IFILE" ]] && cat "\$IFILE" || printf '[]\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TICKET_SCRIPT2
chmod +x "$_ta2_dir/ticket-bin/ticket"

_ta2_exit=0
_ta2_output=$(TICKET_CMD="$_ta2_dir/ticket-bin/ticket" bash "$SCRIPT" "ta2-qcheck-task" 2>&1) || _ta2_exit=$?

# Must still pass (markdown fallback must still work)
assert_eq "md-fallback-regression: exits 0 (quality pass via markdown)" "0" "$_ta2_exit"
# Output must reference file impact (from markdown section)
_ta2_fi_found=0
echo "$_ta2_output" | grep -qiE "file impact" && _ta2_fi_found=1 || true
assert_eq "md-fallback-regression: output mentions 'file impact' (from markdown awk)" "1" "$_ta2_fi_found"

echo ""
print_summary
