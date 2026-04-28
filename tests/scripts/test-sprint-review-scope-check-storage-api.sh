#!/usr/bin/env bash
# tests/scripts/test-sprint-review-scope-check-storage-api.sh
# RED tests for sprint-review-scope-check.sh storage-API refactor.
#
# These tests assert behavior AFTER sprint-review-scope-check.sh is refactored
# to use `ticket get-file-impact` as the primary source of file paths (with
# markdown parsing as fallback). All new assertions FAIL in the current
# (pre-refactor) state.
#
# Tests:
#   a. When `ticket get-file-impact <id>` returns a non-empty array, scope-check
#      uses those paths (primary path — not markdown)
#   b. When `ticket get-file-impact <id>` returns `[]`, scope-check falls through
#      to the markdown parser (fallback)
#
# Usage: bash tests/scripts/test-sprint-review-scope-check-storage-api.sh
# Returns: exit 0 if all pass (once GREEN), exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint-review-scope-check.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

echo "=== test-sprint-review-scope-check-storage-api.sh ==="

# ── Helper: write a reviewer-findings.json ────────────────────────────────────
_write_findings() {
    local path="$1"
    local findings_array="$2"
    python3 -c "
import json, sys
findings = json.loads(sys.argv[1])
out = {'scores': {'correctness': 4}, 'findings': findings, 'summary': 'Test.'}
with open(sys.argv[2], 'w') as f:
    json.dump(out, f)
" "$findings_array" "$path"
}

# ── Helper: create a mock ticket CLI with configurable get-file-impact ─────────
# The ticket's description deliberately has NO ## File Impact section to isolate
# the get-file-impact API path from the markdown fallback path.
#
# Usage: _make_ticket_cli_with_api <dir> <task_id> <get_impact_json>
_make_ticket_cli_with_api() {
    local dir="$1"
    local task_id="$2"
    local get_impact_json="$3"

    mkdir -p "$dir"

    local impact_file="$dir/get-file-impact-${task_id}.json"
    printf '%s\n' "$get_impact_json" > "$impact_file"

    # Ticket has NO markdown File Impact section in description
    local ticket_json_file="$dir/ticket-${task_id}.json"
    python3 -c "
import json, sys
t = {
    'ticket_id': sys.argv[1],
    'ticket_type': 'task',
    'status': 'open',
    'title': 'Test task for scope check storage API',
    'description': '## Description\nDo the thing. No markdown file impact section.',
    'comments': [],
    'deps': []
}
print(json.dumps(t))
" "$task_id" > "$ticket_json_file"

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
        echo '{}' ; exit 1
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

# ── Helper: create a call-recording ticket CLI with get-file-impact support ───
# Like _make_ticket_cli_with_api but records all calls to <call_log>.
_make_recording_ticket_cli() {
    local dir="$1"
    local task_id="$2"
    local description_body="$3"
    local get_impact_json="$4"
    local call_log="$5"

    mkdir -p "$dir"

    local impact_file="$dir/get-file-impact-${task_id}.json"
    printf '%s\n' "$get_impact_json" > "$impact_file"

    local desc_file="$dir/desc_${task_id}.txt"
    printf '%s' "$description_body" > "$desc_file"

    cat > "$dir/ticket" << TICKET_SCRIPT
#!/usr/bin/env bash
SUBCMD="\${1:-}"
CALL_LOG="$call_log"
shift || true
echo "\$SUBCMD \$*" >> "\$CALL_LOG"
case "\$SUBCMD" in
    show)
        TICKET_ID="\${1:-}"
        DESC_FILE="$dir/desc_\${TICKET_ID}.txt"
        if [[ -f "\$DESC_FILE" ]]; then
            python3 -c "
import json, sys
desc = open(sys.argv[1]).read()
print(json.dumps({'ticket_id': sys.argv[2], 'ticket_type': 'task', 'status': 'open',
                  'description': desc, 'title': 'Test task', 'comments': [], 'deps': []}))
" "\$DESC_FILE" "\$TICKET_ID"
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

# ── Test a: non-empty get-file-impact → uses API paths for scope check ─────────
# Set up: a task has NO markdown ## File Impact section, but
# `ticket get-file-impact` returns [src/api-scope.py].
# A reviewer finding references src/api-scope.py → should be IN_SCOPE.
# Another finding references lib/other.py → OUT_OF_SCOPE.
# RED (current): scope-check only parses markdown description; no section found →
# falls through to IN_SCOPE by default. After refactor, it must use the API paths.
echo ""
echo "Test a: non-empty get-file-impact → scope-check uses API paths (primary)"

_ta_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta_dir")
_ta_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta_ticket_dir")

_ta_findings_path="$_ta_dir/reviewer-findings.json"
_ta_findings='[
  {"severity":"important","description":"In-scope finding","file":"src/api-scope.py","category":"correctness"},
  {"severity":"minor","description":"Out-of-scope finding","file":"lib/other.py","category":"hygiene"}
]'
_write_findings "$_ta_findings_path" "$_ta_findings"

# Task has no markdown File Impact section; get-file-impact returns paths
_ta_impact_json='[{"file":"src/api-scope.py","reason":"API layer"},{"file":"tests/test_api_scope.py","reason":"unit tests"}]'
_make_ticket_cli_with_api "$_ta_ticket_dir" "ta-scope-task" "$_ta_impact_json"

_ta_exit=0
_ta_output=$(TICKET_CMD="$_ta_ticket_dir/ticket" bash "$SCRIPT" "$_ta_findings_path" "ta-scope-task" 2>&1) || _ta_exit=$?

assert_eq "api-scope: exits 0" "0" "$_ta_exit"
# RED assertion: must report OUT_OF_SCOPE (lib/other.py is not in get-file-impact array)
# Current behavior: no markdown section → IN_SCOPE (misses the out-of-scope finding)
assert_contains "api-scope: OUT_OF_SCOPE detected via get-file-impact paths" "OUT_OF_SCOPE" "$_ta_output"
assert_contains "api-scope: out-of-scope file listed (lib/other.py)" "lib/other.py" "$_ta_output"

# ── Test a2: non-empty get-file-impact, all findings in scope → IN_SCOPE ──────
echo ""
echo "Test a2: non-empty get-file-impact, all findings in scope → IN_SCOPE"

_ta2_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta2_dir")
_ta2_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta2_ticket_dir")

_ta2_findings_path="$_ta2_dir/reviewer-findings.json"
_ta2_findings='[
  {"severity":"important","description":"In-scope finding","file":"src/api-scope.py","category":"correctness"}
]'
_write_findings "$_ta2_findings_path" "$_ta2_findings"

_ta2_impact_json='[{"file":"src/api-scope.py","reason":"API layer"},{"file":"tests/test_api_scope.py","reason":"unit tests"}]'
_make_ticket_cli_with_api "$_ta2_ticket_dir" "ta2-scope-task" "$_ta2_impact_json"

_ta2_exit=0
_ta2_output=$(TICKET_CMD="$_ta2_ticket_dir/ticket" bash "$SCRIPT" "$_ta2_findings_path" "ta2-scope-task" 2>&1) || _ta2_exit=$?

assert_eq "api-scope-all-in: exits 0" "0" "$_ta2_exit"
# RED assertion: must report IN_SCOPE using get-file-impact paths
# (current behavior also returns IN_SCOPE but because no markdown section found —
#  after refactor it must use API paths; call-log check below verifies the route taken)
assert_contains "api-scope-all-in: IN_SCOPE via get-file-impact" "IN_SCOPE" "$_ta2_output"

# KEY RED assertion: verify get-file-impact was actually called
_ta2_call_log=$(mktemp)
_CLEANUP_DIRS+=("$_ta2_call_log")
_ta2_desc="## Description\nNo markdown file impact section here."
_make_recording_ticket_cli "$_ta2_ticket_dir/v2" "ta2-scope-task" "$_ta2_desc" "$_ta2_impact_json" "$_ta2_call_log"

TICKET_CMD="$_ta2_ticket_dir/v2/ticket" bash "$SCRIPT" "$_ta2_findings_path" "ta2-scope-task" >/dev/null 2>&1 || true

_ta2_gfi_called=0
grep -q "get-file-impact ta2-scope-task" "$_ta2_call_log" && _ta2_gfi_called=1 || true
assert_eq "api-scope-all-in: ticket get-file-impact was called" "1" "$_ta2_gfi_called"

# ── Test b: empty get-file-impact → falls through to markdown parser ──────────
# Set up: `ticket get-file-impact` returns `[]`, but the ticket description HAS
# a markdown ## File Impact section. A reviewer finding references a file outside
# the markdown list → OUT_OF_SCOPE (markdown fallback path).
# After refactor: tries get-file-impact first (empty), then parses markdown.
# Existing behavior also parses markdown. Key RED assertion: get-file-impact is tried first.
echo ""
echo "Test b: empty get-file-impact → falls through to markdown parser (fallback)"

_tb_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_tb_dir")
_tb_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_tb_ticket_dir")
_tb_call_log=$(mktemp)
_CLEANUP_DIRS+=("$_tb_call_log")

_tb_findings_path="$_tb_dir/reviewer-findings.json"
_tb_findings='[
  {"severity":"important","description":"In-scope finding","file":"src/md-listed.py","category":"correctness"},
  {"severity":"minor","description":"Out-of-scope finding","file":"lib/not-listed.py","category":"hygiene"}
]'
_write_findings "$_tb_findings_path" "$_tb_findings"

# Task HAS markdown File Impact section (real newlines, not escaped)
_tb_description="$(printf '## Description\nDo the thing.\n\n## File Impact\n- src/md-listed.py\n- tests/test_md.py\n')"

# get-file-impact returns [] for this task (not stored via API yet)
_make_recording_ticket_cli "$_tb_ticket_dir" "tb-scope-task" "$_tb_description" "[]" "$_tb_call_log"

_tb_exit=0
_tb_output=$(TICKET_CMD="$_tb_ticket_dir/ticket" bash "$SCRIPT" "$_tb_findings_path" "tb-scope-task" 2>&1) || _tb_exit=$?

assert_eq "md-fallback: exits 0" "0" "$_tb_exit"
# Markdown fallback must detect out-of-scope (existing behavior preserved)
assert_contains "md-fallback: OUT_OF_SCOPE detected via markdown fallback" "OUT_OF_SCOPE" "$_tb_output"
assert_contains "md-fallback: out-of-scope file listed" "lib/not-listed.py" "$_tb_output"

# KEY RED assertion: get-file-impact was attempted BEFORE falling back to markdown
_tb_gfi_called=0
grep -q "get-file-impact tb-scope-task" "$_tb_call_log" && _tb_gfi_called=1 || true
assert_eq "md-fallback: get-file-impact attempted first (before markdown fallback)" "1" "$_tb_gfi_called"

echo ""
print_summary
