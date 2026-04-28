#!/usr/bin/env bash
# tests/scripts/test-sprint-drift-check-storage-api.sh
# RED tests for sprint-drift-check.sh storage-API refactor.
#
# These tests assert behavior AFTER sprint-drift-check.sh is refactored to use
# `ticket get-file-impact` as the primary source of file paths (with markdown
# as fallback). All tests FAIL in the current (pre-refactor) state.
#
# Tests:
#   a. When `ticket get-file-impact <id>` returns a non-empty array, drift-check
#      uses those paths (not markdown parsing)
#   b. When `ticket get-file-impact <id>` returns `[]`, drift-check falls through
#      to the existing markdown parser
#
# Usage: bash tests/scripts/test-sprint-drift-check-storage-api.sh
# Returns: exit 0 if all pass (once GREEN), exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
cd "$REPO_ROOT" || exit 1
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint-drift-check.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

echo "=== test-sprint-drift-check-storage-api.sh ==="

# ── Helper: create a minimal git repo ─────────────────────────────────────────
_make_git_repo() {
    local dir="$1"
    git init -q -b main "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    touch "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
}

# ── Helper: create a mock ticket CLI with configurable get-file-impact output ──
# The mock:
#   - `ticket show <epic_id>`              → returns epic_json
#   - `ticket show <child_id>`             → dispatches from children_json
#   - `ticket list --parent <epic_id>`     → returns children_json
#   - `ticket get-file-impact <ticket_id>` → returns get_impact_output (per ticket)
#
# Usage: _make_ticket_cli_with_api <dir> <epic_id> <epic_json> <children_json>
#        <child_id> <get_impact_json_for_child>
_make_ticket_cli_with_api() {
    local dir="$1"
    local epic_id="$2"
    local epic_json="$3"
    local children_json="$4"
    local child_id="$5"
    local get_impact_json="$6"

    mkdir -p "$dir"

    # Write the get-file-impact response to a file to avoid quoting pitfalls
    local impact_file="$dir/get-file-impact-${child_id}.json"
    printf '%s\n' "$get_impact_json" > "$impact_file"

    cat > "$dir/ticket" << TICKET_SCRIPT
#!/usr/bin/env bash
SUBCMD="\${1:-}"
shift || true
case "\$SUBCMD" in
    show)
        TICKET_ID="\${1:-}"
        if [[ "\$TICKET_ID" == "$epic_id" ]]; then
            printf '%s\n' '$epic_json'
            exit 0
        fi
        python3 -c "
import json, sys
children = json.loads('''$children_json''')
tid = sys.argv[1]
for c in children:
    if c.get('ticket_id') == tid:
        print(json.dumps(c))
        sys.exit(0)
sys.exit(1)
" "\$TICKET_ID"
        exit \$?
        ;;
    list)
        printf '%s\n' '$children_json'
        exit 0
        ;;
    get-file-impact)
        TICKET_ID="\${1:-}"
        IMPACT_FILE="$dir/get-file-impact-\${TICKET_ID}.json"
        if [[ -f "\$IMPACT_FILE" ]]; then
            cat "\$IMPACT_FILE"
        else
            # No impact stored for this ticket — return empty array
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

# ── Test a: non-empty get-file-impact → uses API paths for drift detection ────
# Set up: a child ticket has NO markdown ## File Impact section, but
# `ticket get-file-impact` returns a non-empty array with src/api-path.py.
# An external commit modifies src/api-path.py after the task was created.
# After refactor: drift-check finds src/api-path.py via get-file-impact → DRIFT_DETECTED.
# RED (current): drift-check only parses markdown; no ## File Impact section → NO_DRIFT.
echo ""
echo "Test a: non-empty get-file-impact → drift-check uses API paths (not markdown)"

_ta_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta_repo")
_make_git_repo "$_ta_repo"

_ta_task_created_at=$(date +%s)

# External commit modifies src/api-path.py AFTER task creation
mkdir -p "$_ta_repo/src"
echo "# externally modified" > "$_ta_repo/src/api-path.py"
git -C "$_ta_repo" add src/api-path.py
git -C "$_ta_repo" commit -q -m "external: modify api-path.py"

_ta_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_ta_ticket_dir")

# Child ticket has NO markdown File Impact section
_ta_children_json='[{"ticket_id":"ta-task-1","ticket_type":"task","status":"open","parent_id":"ta-epic","created_at":'"$_ta_task_created_at"',"title":"Child task","description":"## Description\nDo the thing. No markdown file impact here.","comments":[],"deps":[]}]'
_ta_epic_json='{"ticket_id":"ta-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_ta_task_created_at - 100))"',"title":"Test Epic","description":"","comments":[],"deps":[]}'

# get-file-impact returns a non-empty array for ta-task-1 (stored via API)
_ta_impact_json='[{"file":"src/api-path.py","reason":"core API logic"},{"file":"tests/test_api.py","reason":"unit tests"}]'
_make_ticket_cli_with_api "$_ta_ticket_dir" "ta-epic" "$_ta_epic_json" "$_ta_children_json" "ta-task-1" "$_ta_impact_json"

_ta_exit=0
_ta_output=$(TICKET_CMD="$_ta_ticket_dir/ticket" bash "$SCRIPT" "ta-epic" --repo="$_ta_repo" 2>&1) || _ta_exit=$?

assert_eq "api-paths-drift: exits 0" "0" "$_ta_exit"
# RED assertion: drift-check must detect drift via API paths, not markdown
assert_contains "api-paths-drift: DRIFT_DETECTED via get-file-impact paths" "DRIFT_DETECTED" "$_ta_output"
assert_contains "api-paths-drift: drifted file (from API) listed in output" "src/api-path.py" "$_ta_output"

# ── Test b: empty get-file-impact → falls through to markdown parser ──────────
# Set up: a child ticket has a markdown ## File Impact section but
# `ticket get-file-impact` returns `[]` (empty — not yet stored via new API).
# An external commit modifies the markdown-listed file.
# After refactor: fallback to markdown → DRIFT_DETECTED (existing behavior preserved).
# GREEN already: the current script does NOT call get-file-impact, it goes straight
# to markdown. So this test verifies backward-compatible fallback — it should PASS
# after refactor, and also pass now (verifying no regression).
# However, the KEY RED assertion is that get-file-impact was ATTEMPTED first.
echo ""
echo "Test b: empty get-file-impact → falls through to markdown parser (fallback)"

_tb_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_tb_repo")
_make_git_repo "$_tb_repo"

_tb_task_created_at=$(date +%s)

# External commit modifies src/md-path.py AFTER task creation
mkdir -p "$_tb_repo/src"
echo "# externally modified" > "$_tb_repo/src/md-path.py"
git -C "$_tb_repo" add src/md-path.py
git -C "$_tb_repo" commit -q -m "external: modify md-path.py"

_tb_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_tb_ticket_dir")

# Child ticket HAS markdown File Impact section
_tb_children_json='[{"ticket_id":"tb-task-1","ticket_type":"task","status":"open","parent_id":"tb-epic","created_at":'"$_tb_task_created_at"',"title":"Child task","description":"## Description\nDo the thing.\n\n## File Impact\n- src/md-path.py\n","comments":[],"deps":[]}]'
_tb_epic_json='{"ticket_id":"tb-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_tb_task_created_at - 100))"',"title":"Test Epic","description":"","comments":[],"deps":[]}'

# get-file-impact returns empty array for tb-task-1 (not stored via API)
_make_ticket_cli_with_api "$_tb_ticket_dir" "tb-epic" "$_tb_epic_json" "$_tb_children_json" "tb-task-1" "[]"

_tb_exit=0
_tb_output=$(TICKET_CMD="$_tb_ticket_dir/ticket" bash "$SCRIPT" "tb-epic" --repo="$_tb_repo" 2>&1) || _tb_exit=$?

assert_eq "markdown-fallback: exits 0" "0" "$_tb_exit"
# Fallback to markdown must still detect drift
assert_contains "markdown-fallback: DRIFT_DETECTED via markdown fallback" "DRIFT_DETECTED" "$_tb_output"
assert_contains "markdown-fallback: drifted file (from markdown) listed in output" "src/md-path.py" "$_tb_output"

# RED assertion: get-file-impact must have been ATTEMPTED before falling back
# We verify this by checking the ticket CLI call log
_tb_call_log=$(mktemp)
_CLEANUP_DIRS+=("$_tb_call_log")

# Recreate the ticket CLI with a call-recording version
mkdir -p "$_tb_ticket_dir/v2"
cat > "$_tb_ticket_dir/v2/ticket" << TICKET_V2
#!/usr/bin/env bash
SUBCMD="\${1:-}"
CALL_LOG="$_tb_call_log"
shift || true
echo "\$SUBCMD \$*" >> "\$CALL_LOG"
case "\$SUBCMD" in
    show)
        TICKET_ID="\${1:-}"
        if [[ "\$TICKET_ID" == "tb-epic" ]]; then
            printf '%s\n' '$_tb_epic_json'
            exit 0
        fi
        python3 -c "
import json, sys
children = json.loads('''$_tb_children_json''')
tid = sys.argv[1]
for c in children:
    if c.get('ticket_id') == tid:
        print(json.dumps(c))
        sys.exit(0)
sys.exit(1)
" "\$TICKET_ID"
        exit \$?
        ;;
    list)
        printf '%s\n' '$_tb_children_json'
        exit 0
        ;;
    get-file-impact)
        printf '[]\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TICKET_V2
chmod +x "$_tb_ticket_dir/v2/ticket"

TICKET_CMD="$_tb_ticket_dir/v2/ticket" bash "$SCRIPT" "tb-epic" --repo="$_tb_repo" >/dev/null 2>&1 || true

_tb_gfi_called=0
grep -q "get-file-impact" "$_tb_call_log" && _tb_gfi_called=1 || true
assert_eq "markdown-fallback: get-file-impact attempted before markdown fallback" "1" "$_tb_gfi_called"

echo ""
print_summary
