#!/usr/bin/env bash
# tests/scripts/test-sprint-drift-check.sh
# RED tests for plugins/dso/scripts/sprint-drift-check.sh (does not exist yet).
#
# Behavioral tests: create mock git repos with known commit histories and mock
# ticket CLIs, then execute the script and assert on stdout and exit codes.
#
# Usage: bash tests/scripts/test-sprint-drift-check.sh
# Returns: exit 0 if all pass (once GREEN), exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint-drift-check.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

echo "=== test-sprint-drift-check.sh ==="

# ── Helper: create a minimal git repo with a configurable commit history ───────
# Usage: _make_git_repo <dir>
# After calling, use git -C <dir> commands to add commits.
_make_git_repo() {
    local dir="$1"
    git init -q -b main "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    # Initial commit so the repo has a HEAD
    touch "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
}

# ── Helper: create a mock ticket CLI ─────────────────────────────────────────
# Usage: _make_ticket_cli <dir> <epic_id> <epic_json> <children_json>
# Creates <dir>/ticket that responds to show <epic_id> and list --parent <epic_id>
_make_ticket_cli() {
    local dir="$1"
    local epic_id="$2"
    local epic_json="$3"
    local children_json="$4"

    mkdir -p "$dir"
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
        # For child ticket show calls, dispatch from the children array
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
    *)
        exit 0
        ;;
esac
TICKET_SCRIPT
    chmod +x "$dir/ticket"
}

# ── Test: test_missing_args — missing epic-id exits non-zero with usage ────────
echo ""
echo "Test: test_missing_args — missing epic-id exits non-zero with usage message"

missing_args_exit=0
missing_args_output=$(bash "$SCRIPT" 2>&1) || missing_args_exit=$?

assert_ne "exits non-zero when no args given" "0" "$missing_args_exit"
assert_contains "output contains usage hint" "usage" "$(echo "$missing_args_output" | tr '[:upper:]' '[:lower:]')"

# ── Test: test_no_drift — files in impact table not modified since task creation ─
echo ""
echo "Test: test_no_drift — files not modified after task creation → NO_DRIFT"

_t2_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t2_repo")
_make_git_repo "$_t2_repo"

# Record epoch AFTER the initial commit — this will be the task created_at timestamp
_t2_task_created_at=$(date +%s)

# No commits touch src/app.py after this timestamp
_t2_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t2_ticket_dir")

_t2_child_desc="## Description\nDo the thing\n\n## File Impact\n- src/app.py\n- tests/test_app.py\n"
_t2_children_json='[{"ticket_id":"t2-task-1","ticket_type":"task","status":"open","parent_id":"t2-epic","created_at":'"$_t2_task_created_at"',"title":"Child task","description":"## Description\nDo the thing\n\n## File Impact\n- src/app.py\n- tests/test_app.py\n","comments":[],"deps":[]}]'
_t2_epic_json='{"ticket_id":"t2-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_t2_task_created_at - 100))"',"title":"Test Epic","description":"Epic desc","comments":[],"deps":[]}'

_make_ticket_cli "$_t2_ticket_dir" "t2-epic" "$_t2_epic_json" "$_t2_children_json"

_t2_exit=0
_t2_output=$(TICKET_CMD="$_t2_ticket_dir/ticket" bash "$SCRIPT" "t2-epic" --repo="$_t2_repo" 2>&1) || _t2_exit=$?

assert_eq "no-drift: exits 0" "0" "$_t2_exit"
assert_contains "no-drift: output contains NO_DRIFT" "NO_DRIFT" "$_t2_output"

# ── Test: test_drift_detected — external commit modified an impact file after task creation ──
echo ""
echo "Test: test_drift_detected — external commit modifies impact file after task creation → DRIFT_DETECTED"

_t3_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t3_repo")
_make_git_repo "$_t3_repo"

# Record task creation timestamp BEFORE adding the external commit
_t3_task_created_at=$(date +%s)

# Simulate an external commit (after task creation) that modifies src/core.py
mkdir -p "$_t3_repo/src"
echo "# modified" > "$_t3_repo/src/core.py"
git -C "$_t3_repo" add src/core.py
git -C "$_t3_repo" commit -q -m "external: modify core.py"

_t3_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t3_ticket_dir")

_t3_children_json='[{"ticket_id":"t3-task-1","ticket_type":"task","status":"open","parent_id":"t3-epic","created_at":'"$_t3_task_created_at"',"title":"Child task","description":"## Description\nRefactor core\n\n## File Impact\n- src/core.py\n","comments":[],"deps":[]}]'
_t3_epic_json='{"ticket_id":"t3-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_t3_task_created_at - 100))"',"title":"Test Epic","description":"Epic desc","comments":[],"deps":[]}'

_make_ticket_cli "$_t3_ticket_dir" "t3-epic" "$_t3_epic_json" "$_t3_children_json"

_t3_exit=0
_t3_output=$(TICKET_CMD="$_t3_ticket_dir/ticket" bash "$SCRIPT" "t3-epic" --repo="$_t3_repo" 2>&1) || _t3_exit=$?

assert_eq "drift-detected: exits 0" "0" "$_t3_exit"
assert_contains "drift-detected: output contains DRIFT_DETECTED" "DRIFT_DETECTED" "$_t3_output"
assert_contains "drift-detected: output lists the modified file" "src/core.py" "$_t3_output"

# ── Test: test_no_file_impact — task with no File Impact section → skip gracefully ──
echo ""
echo "Test: test_no_file_impact — task ticket has no File Impact section → skips gracefully, NO_DRIFT"

_t4_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t4_repo")
_make_git_repo "$_t4_repo"

_t4_task_created_at=$(date +%s)

# Add a commit that would be "after" creation — but there are no files to check
mkdir -p "$_t4_repo/src"
echo "# some change" > "$_t4_repo/src/other.py"
git -C "$_t4_repo" add src/other.py
git -C "$_t4_repo" commit -q -m "unrelated commit"

_t4_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t4_ticket_dir")

# Child ticket has no "## File Impact" section
_t4_children_json='[{"ticket_id":"t4-task-1","ticket_type":"task","status":"open","parent_id":"t4-epic","created_at":'"$_t4_task_created_at"',"title":"No impact task","description":"## Description\nJust write some docs.\n","comments":[],"deps":[]}]'
_t4_epic_json='{"ticket_id":"t4-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_t4_task_created_at - 100))"',"title":"Test Epic","description":"Epic desc","comments":[],"deps":[]}'

_make_ticket_cli "$_t4_ticket_dir" "t4-epic" "$_t4_epic_json" "$_t4_children_json"

_t4_exit=0
_t4_output=$(TICKET_CMD="$_t4_ticket_dir/ticket" bash "$SCRIPT" "t4-epic" --repo="$_t4_repo" 2>&1) || _t4_exit=$?

assert_eq "no-file-impact: exits 0" "0" "$_t4_exit"
# Must not report DRIFT_DETECTED for a task with no file impact section
assert_contains "no-file-impact: output is NO_DRIFT" "NO_DRIFT" "$_t4_output"

# ── Test: test_epic_no_children — epic with no child tickets → NO_DRIFT ───────
echo ""
echo "Test: test_epic_no_children — epic with no children → NO_DRIFT, exit 0"

_t5_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t5_repo")
_make_git_repo "$_t5_repo"

_t5_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t5_ticket_dir")

_t5_epic_json='{"ticket_id":"t5-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":1700000000,"title":"Empty Epic","description":"Empty","comments":[],"deps":[]}'
# Empty children array
_t5_children_json='[]'

_make_ticket_cli "$_t5_ticket_dir" "t5-epic" "$_t5_epic_json" "$_t5_children_json"

_t5_exit=0
_t5_output=$(TICKET_CMD="$_t5_ticket_dir/ticket" bash "$SCRIPT" "t5-epic" --repo="$_t5_repo" 2>&1) || _t5_exit=$?

assert_eq "no-children: exits 0" "0" "$_t5_exit"
assert_contains "no-children: output contains NO_DRIFT" "NO_DRIFT" "$_t5_output"

echo ""
print_summary
