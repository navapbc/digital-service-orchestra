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

# ── Test: test_status_open_only_processes_open_children ──────────────────────
# When --status=open is passed, only children with status "open" are processed;
# in_progress and closed children are excluded from drift detection.
echo ""
echo "Test: test_status_open_only_processes_open_children — --status=open excludes non-open children"

_t6_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t6_repo")
_make_git_repo "$_t6_repo"

_t6_task_created_at=$(date +%s)

# Add a commit that touches a file listed in the in_progress child's impact table
# If the in_progress child were processed, this would trigger DRIFT_DETECTED.
# When --status=open filters it out, only the open child is processed (which has no drift).
mkdir -p "$_t6_repo/src"
echo "# external change" > "$_t6_repo/src/inprogress_file.py"
git -C "$_t6_repo" add src/inprogress_file.py
git -C "$_t6_repo" commit -q -m "external: touch inprogress file"

_t6_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t6_ticket_dir")

# Three children: open (no drift), in_progress (has drift), closed (has drift)
_t6_children_json='[
  {"ticket_id":"t6-open","ticket_type":"task","status":"open","parent_id":"t6-epic","created_at":'"$_t6_task_created_at"',"title":"Open task","description":"## File Impact\n- src/open_file.py\n","comments":[],"deps":[]},
  {"ticket_id":"t6-inprog","ticket_type":"task","status":"in_progress","parent_id":"t6-epic","created_at":'"$_t6_task_created_at"',"title":"In progress task","description":"## File Impact\n- src/inprogress_file.py\n","comments":[],"deps":[]},
  {"ticket_id":"t6-closed","ticket_type":"task","status":"closed","parent_id":"t6-epic","created_at":'"$_t6_task_created_at"',"title":"Closed task","description":"## File Impact\n- src/inprogress_file.py\n","comments":[],"deps":[]}
]'
_t6_epic_json='{"ticket_id":"t6-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_t6_task_created_at - 100))"',"title":"Test Epic","description":"Epic desc","comments":[],"deps":[]}'

_make_ticket_cli "$_t6_ticket_dir" "t6-epic" "$_t6_epic_json" "$_t6_children_json"

_t6_exit=0
_t6_output=$(TICKET_CMD="$_t6_ticket_dir/ticket" bash "$SCRIPT" "t6-epic" --repo="$_t6_repo" --status=open 2>&1) || _t6_exit=$?

assert_eq "status-open-only: exits 0" "0" "$_t6_exit"
assert_contains "status-open-only: open child processed → NO_DRIFT (no changes to its file)" "NO_DRIFT" "$_t6_output"

# ── Test: test_status_absent_processes_all_children_backward_compat ──────────
# When --status is not passed, all children are processed (backward compatibility).
# A drifted in_progress child should still trigger DRIFT_DETECTED.
echo ""
echo "Test: test_status_absent_processes_all_children_backward_compat — no --status processes all children"

_t7_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t7_repo")
_make_git_repo "$_t7_repo"

_t7_task_created_at=$(date +%s)

# Add an external commit modifying the in_progress child's impact file
mkdir -p "$_t7_repo/src"
echo "# external change" > "$_t7_repo/src/inprogress_file.py"
git -C "$_t7_repo" add src/inprogress_file.py
git -C "$_t7_repo" commit -q -m "external: touch inprogress file"

_t7_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t7_ticket_dir")

_t7_children_json='[
  {"ticket_id":"t7-open","ticket_type":"task","status":"open","parent_id":"t7-epic","created_at":'"$_t7_task_created_at"',"title":"Open task","description":"## File Impact\n- src/open_file.py\n","comments":[],"deps":[]},
  {"ticket_id":"t7-inprog","ticket_type":"task","status":"in_progress","parent_id":"t7-epic","created_at":'"$_t7_task_created_at"',"title":"In progress task","description":"## File Impact\n- src/inprogress_file.py\n","comments":[],"deps":[]}
]'
_t7_epic_json='{"ticket_id":"t7-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_t7_task_created_at - 100))"',"title":"Test Epic","description":"Epic desc","comments":[],"deps":[]}'

_make_ticket_cli "$_t7_ticket_dir" "t7-epic" "$_t7_epic_json" "$_t7_children_json"

_t7_exit=0
_t7_output=$(TICKET_CMD="$_t7_ticket_dir/ticket" bash "$SCRIPT" "t7-epic" --repo="$_t7_repo" 2>&1) || _t7_exit=$?

assert_eq "status-absent-backward-compat: exits 0" "0" "$_t7_exit"
# Without --status filter, the in_progress child is processed and drift is detected
assert_contains "status-absent-backward-compat: in_progress child drifted → DRIFT_DETECTED" "DRIFT_DETECTED" "$_t7_output"
assert_contains "status-absent-backward-compat: drifted file listed" "src/inprogress_file.py" "$_t7_output"

# ── Test: test_status_invalid_exits_nonzero ───────────────────────────────────
# --status=invalid should return a non-zero exit code.
echo ""
echo "Test: test_status_invalid_exits_nonzero — --status=invalid exits non-zero"

_t8_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t8_repo")
_make_git_repo "$_t8_repo"

_t8_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t8_ticket_dir")

_t8_epic_json='{"ticket_id":"t8-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":1700000000,"title":"Test Epic","description":"","comments":[],"deps":[]}'
_t8_children_json='[]'

_make_ticket_cli "$_t8_ticket_dir" "t8-epic" "$_t8_epic_json" "$_t8_children_json"

_t8_exit=0
_t8_output=$(TICKET_CMD="$_t8_ticket_dir/ticket" bash "$SCRIPT" "t8-epic" --repo="$_t8_repo" --status=invalid 2>&1) || _t8_exit=$?

assert_ne "status-invalid: exits non-zero" "0" "$_t8_exit"

# ── Test: test_status_open_mixed_children_drift_output ───────────────────────
# With mixed-status children (open, in_progress, closed), when --status=open is
# passed, only the open child's files appear in the drift output; files from
# in_progress and closed children must NOT appear.
echo ""
echo "Test: test_status_open_mixed_children_drift_output — only open child files appear in drift output"

_t9_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t9_repo")
_make_git_repo "$_t9_repo"

_t9_task_created_at=$(date +%s)

# Commit modifies ALL three impact files so that without filtering, all would drift.
mkdir -p "$_t9_repo/src"
echo "change" > "$_t9_repo/src/open_file.py"
echo "change" > "$_t9_repo/src/inprog_file.py"
echo "change" > "$_t9_repo/src/closed_file.py"
git -C "$_t9_repo" add src/open_file.py src/inprog_file.py src/closed_file.py
git -C "$_t9_repo" commit -q -m "external: touch all three files"

_t9_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t9_ticket_dir")

_t9_children_json='[
  {"ticket_id":"t9-open","ticket_type":"task","status":"open","parent_id":"t9-epic","created_at":'"$_t9_task_created_at"',"title":"Open task","description":"## File Impact\n- src/open_file.py\n","comments":[],"deps":[]},
  {"ticket_id":"t9-inprog","ticket_type":"task","status":"in_progress","parent_id":"t9-epic","created_at":'"$_t9_task_created_at"',"title":"In progress task","description":"## File Impact\n- src/inprog_file.py\n","comments":[],"deps":[]},
  {"ticket_id":"t9-closed","ticket_type":"task","status":"closed","parent_id":"t9-epic","created_at":'"$_t9_task_created_at"',"title":"Closed task","description":"## File Impact\n- src/closed_file.py\n","comments":[],"deps":[]}
]'
_t9_epic_json='{"ticket_id":"t9-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_t9_task_created_at - 100))"',"title":"Test Epic","description":"Epic desc","comments":[],"deps":[]}'

_make_ticket_cli "$_t9_ticket_dir" "t9-epic" "$_t9_epic_json" "$_t9_children_json"

_t9_exit=0
_t9_output=$(TICKET_CMD="$_t9_ticket_dir/ticket" bash "$SCRIPT" "t9-epic" --repo="$_t9_repo" --status=open 2>&1) || _t9_exit=$?

assert_eq "status-mixed-drift: exits 0" "0" "$_t9_exit"
# The open child's file was externally modified → DRIFT_DETECTED
assert_contains "status-mixed-drift: open child drifted → DRIFT_DETECTED" "DRIFT_DETECTED" "$_t9_output"
# Open child's file appears in drift output
assert_contains "status-mixed-drift: open file listed" "src/open_file.py" "$_t9_output"
# in_progress and closed files must NOT appear in drift output (filtered out)
_t9_inprog_absent=0
grep -q "src/inprog_file.py" <<< "$_t9_output" && _t9_inprog_absent=1 || true
assert_eq "status-mixed-drift: in_progress file absent from drift output" "0" "$_t9_inprog_absent"
_t9_closed_absent=0
grep -q "src/closed_file.py" <<< "$_t9_output" && _t9_closed_absent=1 || true
assert_eq "status-mixed-drift: closed file absent from drift output" "0" "$_t9_closed_absent"


# ── Helper: extend _make_ticket_cli to support relates_to neighbors ───────────
# Usage: _make_ticket_cli_with_relates_to <dir> <epic_id> <epic_json> \
#           <children_json> <neighbor_id> <neighbor_json>
# Creates <dir>/ticket that responds to:
#   show <epic_id>         → epic_json (which includes a relates_to dep on neighbor_id)
#   show <neighbor_id>     → neighbor_json
#   show <child_id>        → dispatched from children_json
#   list --parent <epic_id> → children_json
_make_ticket_cli_with_relates_to() {
    local dir="$1"
    local epic_id="$2"
    local epic_json="$3"
    local children_json="$4"
    local neighbor_id="$5"
    local neighbor_json="$6"

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
        if [[ "\$TICKET_ID" == "$neighbor_id" ]]; then
            printf '%s\n' '$neighbor_json'
            exit 0
        fi
        # For child ticket show calls, dispatch from children array
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

# ── Helper: create a mock ticket CLI that fails for a specific ticket ID ──────
# All show calls for <fail_id> exit 1 (simulating CLI failure).
_make_ticket_cli_with_failing_neighbor() {
    local dir="$1"
    local epic_id="$2"
    local epic_json="$3"
    local children_json="$4"
    local fail_id="$5"

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
        if [[ "\$TICKET_ID" == "$fail_id" ]]; then
            echo "Error: ticket $fail_id not found" >&2
            exit 1
        fi
        exit 1
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

# ── Test: test_relates_to_drift_neighbor_closed_after_impl_plan ──────────────
# Given: epic has a relates_to dep on a neighbor epic that was closed AFTER
#        the impl plan timestamp (i.e., after children were created)
# When:  sprint-drift-check.sh runs
# Then:  RELATES_TO_DRIFT is emitted containing the neighbor epic ID
echo ""
echo "Test: test_relates_to_drift_neighbor_closed_after_impl_plan — RELATES_TO_DRIFT emitted"

_rt1_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt1_repo")
_make_git_repo "$_rt1_repo"

# Implementation plan timestamp: "now"
_rt1_impl_plan_ts=$(date +%s)

# Neighbor was closed AFTER the impl plan — add 100 seconds
_rt1_neighbor_closed_at=$((_rt1_impl_plan_ts + 100))

_rt1_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt1_ticket_dir")

# The neighbor epic is closed; closed_at is after impl plan timestamp
_rt1_neighbor_json='{"ticket_id":"rt1-neighbor","ticket_type":"epic","status":"closed","parent_id":null,"created_at":'"$((_rt1_impl_plan_ts - 200))"',"closed_at":'"$_rt1_neighbor_closed_at"',"title":"Neighbor Epic","description":"","comments":[],"deps":[]}'

# The epic under test has a relates_to dep on rt1-neighbor
# and a child whose created_at == impl plan timestamp
_rt1_children_json='[{"ticket_id":"rt1-task-1","ticket_type":"task","status":"open","parent_id":"rt1-epic","created_at":'"$_rt1_impl_plan_ts"',"title":"Impl task","description":"## File Impact\n- src/app.py\n","comments":[],"deps":[]}]'
_rt1_epic_json='{"ticket_id":"rt1-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_rt1_impl_plan_ts - 300))"',"title":"Main Epic","description":"","comments":[],"deps":[{"target_id":"rt1-neighbor","relation":"relates_to","link_uuid":"aaaa-1111"}]}'

_make_ticket_cli_with_relates_to "$_rt1_ticket_dir" "rt1-epic" "$_rt1_epic_json" "$_rt1_children_json" "rt1-neighbor" "$_rt1_neighbor_json"

_rt1_exit=0
_rt1_output=$(TICKET_CMD="$_rt1_ticket_dir/ticket" bash "$SCRIPT" "rt1-epic" --repo="$_rt1_repo" 2>&1) || _rt1_exit=$?

assert_eq "rt-drift-after: exits 0" "0" "$_rt1_exit"
assert_contains "rt-drift-after: RELATES_TO_DRIFT emitted" "RELATES_TO_DRIFT" "$_rt1_output"
assert_contains "rt-drift-after: neighbor epic ID in output" "rt1-neighbor" "$_rt1_output"

# ── Test: test_relates_to_no_drift_neighbor_closed_before_impl_plan ──────────
# Given: epic has a relates_to dep on a neighbor closed BEFORE impl plan timestamp
# When:  sprint-drift-check.sh runs
# Then:  NO RELATES_TO_DRIFT emitted (pre-existing closure, not a new signal)
echo ""
echo "Test: test_relates_to_no_drift_neighbor_closed_before_impl_plan — no RELATES_TO_DRIFT"

_rt2_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt2_repo")
_make_git_repo "$_rt2_repo"

_rt2_impl_plan_ts=$(date +%s)

# Neighbor was closed BEFORE the impl plan (subtract 200 seconds)
_rt2_neighbor_closed_at=$((_rt2_impl_plan_ts - 200))

_rt2_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt2_ticket_dir")

_rt2_neighbor_json='{"ticket_id":"rt2-neighbor","ticket_type":"epic","status":"closed","parent_id":null,"created_at":'"$((_rt2_impl_plan_ts - 500))"',"closed_at":'"$_rt2_neighbor_closed_at"',"title":"Neighbor Epic","description":"","comments":[],"deps":[]}'

_rt2_children_json='[{"ticket_id":"rt2-task-1","ticket_type":"task","status":"open","parent_id":"rt2-epic","created_at":'"$_rt2_impl_plan_ts"',"title":"Impl task","description":"## File Impact\n- src/app.py\n","comments":[],"deps":[]}]'
_rt2_epic_json='{"ticket_id":"rt2-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_rt2_impl_plan_ts - 300))"',"title":"Main Epic","description":"","comments":[],"deps":[{"target_id":"rt2-neighbor","relation":"relates_to","link_uuid":"bbbb-2222"}]}'

_make_ticket_cli_with_relates_to "$_rt2_ticket_dir" "rt2-epic" "$_rt2_epic_json" "$_rt2_children_json" "rt2-neighbor" "$_rt2_neighbor_json"

_rt2_exit=0
_rt2_output=$(TICKET_CMD="$_rt2_ticket_dir/ticket" bash "$SCRIPT" "rt2-epic" --repo="$_rt2_repo" 2>&1) || _rt2_exit=$?

assert_eq "closed_before: exits 0" "0" "$_rt2_exit"
# Pre-existing closure must NOT trigger RELATES_TO_DRIFT
_rt2_drift_present=0
grep -q "RELATES_TO_DRIFT" <<< "$_rt2_output" && _rt2_drift_present=1 || true
assert_eq "closed_before: no RELATES_TO_DRIFT emitted" "0" "$_rt2_drift_present"

# ── Test: test_empty_relates_to_set ──────────────────────────────────────────
# Given: epic has no relates_to deps (deps array is empty)
# When:  sprint-drift-check.sh runs
# Then:  clean exit 0, no RELATES_TO_DRIFT emitted, existing behavior unchanged
echo ""
echo "Test: test_empty_relates_to_set — clean exit, no RELATES_TO_DRIFT"

_rt3_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt3_repo")
_make_git_repo "$_rt3_repo"

_rt3_impl_plan_ts=$(date +%s)

_rt3_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt3_ticket_dir")

# Epic has no deps at all
_rt3_children_json='[{"ticket_id":"rt3-task-1","ticket_type":"task","status":"open","parent_id":"rt3-epic","created_at":'"$_rt3_impl_plan_ts"',"title":"Impl task","description":"## File Impact\n- src/app.py\n","comments":[],"deps":[]}]'
_rt3_epic_json='{"ticket_id":"rt3-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_rt3_impl_plan_ts - 200))"',"title":"Main Epic","description":"","comments":[],"deps":[]}'

_make_ticket_cli "$_rt3_ticket_dir" "rt3-epic" "$_rt3_epic_json" "$_rt3_children_json"

_rt3_exit=0
_rt3_output=$(TICKET_CMD="$_rt3_ticket_dir/ticket" bash "$SCRIPT" "rt3-epic" --repo="$_rt3_repo" 2>&1) || _rt3_exit=$?

assert_eq "empty-relates-to: exits 0" "0" "$_rt3_exit"
# No RELATES_TO_DRIFT when there are no relates_to links
_rt3_drift_present=0
grep -q "RELATES_TO_DRIFT" <<< "$_rt3_output" && _rt3_drift_present=1 || true
assert_eq "empty-relates-to: no RELATES_TO_DRIFT emitted" "0" "$_rt3_drift_present"

# ── Test: test_ticket_cli_failure_on_neighbor_warns_continues ────────────────
# Given: epic has a relates_to dep on a neighbor, but ticket CLI fails on show
# When:  sprint-drift-check.sh runs
# Then:  warning emitted to stderr, script continues without error, exits 0
echo ""
echo "Test: test_ticket_cli_failure_on_neighbor_warns_continues — warn to stderr, exit 0"

_rt4_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt4_repo")
_make_git_repo "$_rt4_repo"

_rt4_impl_plan_ts=$(date +%s)

_rt4_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt4_ticket_dir")

_rt4_children_json='[{"ticket_id":"rt4-task-1","ticket_type":"task","status":"open","parent_id":"rt4-epic","created_at":'"$_rt4_impl_plan_ts"',"title":"Impl task","description":"## File Impact\n- src/app.py\n","comments":[],"deps":[]}]'
# Epic deps reference a neighbor "rt4-missing" that will fail on ticket show
_rt4_epic_json='{"ticket_id":"rt4-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_rt4_impl_plan_ts - 200))"',"title":"Main Epic","description":"","comments":[],"deps":[{"target_id":"rt4-missing","relation":"relates_to","link_uuid":"cccc-3333"}]}'

_make_ticket_cli_with_failing_neighbor "$_rt4_ticket_dir" "rt4-epic" "$_rt4_epic_json" "$_rt4_children_json" "rt4-missing"

_rt4_exit=0
_rt4_stderr=$(mktemp)
_CLEANUP_DIRS+=("$_rt4_stderr")
_rt4_output=$(TICKET_CMD="$_rt4_ticket_dir/ticket" bash "$SCRIPT" "rt4-epic" --repo="$_rt4_repo" 2>"$_rt4_stderr") || _rt4_exit=$?
_rt4_err_content=$(cat "$_rt4_stderr")

assert_eq "cli-failure: exits 0 (continues on neighbor lookup failure)" "0" "$_rt4_exit"
# Warning must be emitted to stderr
assert_contains "cli-failure: warning emitted to stderr" "rt4-missing" "$_rt4_err_content"

# ── Test: test_preplanning_context_timestamp_preferred_over_children ─────────
# Given: epic has a PREPLANNING_CONTEXT comment (contains generatedAt timestamp)
#        AND child tasks with a different (later) created_at
# When:  sprint-drift-check.sh runs
# Then:  PREPLANNING_CONTEXT generatedAt is used as impl plan timestamp
#        (neighbor closed between PREPLANNING_CONTEXT and children.created_at triggers drift)
echo ""
echo "Test: test_preplanning_context_timestamp_preferred — PREPLANNING_CONTEXT generatedAt used"

_rt5_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt5_repo")
_make_git_repo "$_rt5_repo"

# Timeline:
#   T=1000: PREPLANNING_CONTEXT generatedAt (earliest child in theory too)
#   T=1100: neighbor closed  ← after PREPLANNING_CONTEXT → should trigger RELATES_TO_DRIFT
#   T=1200: child created_at ← if children ts used instead, neighbor would be "before" child → no drift
# Using PREPLANNING_CONTEXT ts (T=1000) correctly detects drift; using children ts (T=1200) would miss it.
_rt5_base_ts=1700000000
_rt5_preplanning_ts=$((_rt5_base_ts + 1000))
_rt5_neighbor_closed_at=$((_rt5_base_ts + 1100))
_rt5_child_ts=$((_rt5_base_ts + 1200))

_rt5_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt5_ticket_dir")

_rt5_neighbor_json='{"ticket_id":"rt5-neighbor","ticket_type":"epic","status":"closed","parent_id":null,"created_at":'"$((_rt5_base_ts + 500))"',"closed_at":'"$_rt5_neighbor_closed_at"',"title":"Neighbor Epic","description":"","comments":[],"deps":[]}'

# Epic includes a PREPLANNING_CONTEXT comment with generatedAt at T=1000
_rt5_preplanning_iso=$(date -u -r "$_rt5_preplanning_ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$_rt5_preplanning_ts" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "2023-11-14T18:46:40Z")
_rt5_preplanning_payload="{\"generatedAt\":\"${_rt5_preplanning_iso}\",\"stories\":[]}"
_rt5_preplanning_comment_body="PREPLANNING_CONTEXT: ${_rt5_preplanning_payload}"

_rt5_children_json='[{"ticket_id":"rt5-task-1","ticket_type":"task","status":"open","parent_id":"rt5-epic","created_at":'"$_rt5_child_ts"',"title":"Impl task","description":"## File Impact\n- src/app.py\n","comments":[],"deps":[]}]'
_rt5_epic_json='{"ticket_id":"rt5-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_rt5_base_ts + 800))"',"title":"Main Epic","description":"","comments":[{"body":"'"$_rt5_preplanning_comment_body"'","author":"Test","created_at":'"$_rt5_preplanning_ts"'}],"deps":[{"target_id":"rt5-neighbor","relation":"relates_to","link_uuid":"dddd-4444"}]}'

_make_ticket_cli_with_relates_to "$_rt5_ticket_dir" "rt5-epic" "$_rt5_epic_json" "$_rt5_children_json" "rt5-neighbor" "$_rt5_neighbor_json"

_rt5_exit=0
_rt5_output=$(TICKET_CMD="$_rt5_ticket_dir/ticket" bash "$SCRIPT" "rt5-epic" --repo="$_rt5_repo" 2>&1) || _rt5_exit=$?

assert_eq "preplanning-ts-preferred: exits 0" "0" "$_rt5_exit"
# PREPLANNING_CONTEXT ts (T=1000) < neighbor closed_at (T=1100) → RELATES_TO_DRIFT
assert_contains "preplanning-ts-preferred: RELATES_TO_DRIFT emitted (PREPLANNING_CONTEXT ts used)" "RELATES_TO_DRIFT" "$_rt5_output"

# ── Test: test_fallback_to_children_timestamp_when_no_preplanning_context ────
# Given: epic has NO PREPLANNING_CONTEXT comment, only child tasks
# When:  sprint-drift-check.sh runs
# Then:  earliest child created_at is used as impl plan timestamp
#        (neighbor closed before earliest child → no drift)
echo ""
echo "Test: test_fallback_to_children_timestamp — earliest child created_at used when no PREPLANNING_CONTEXT"

_rt6_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt6_repo")
_make_git_repo "$_rt6_repo"

# Timeline:
#   T=1000: neighbor closed
#   T=1200: earliest child created_at (impl plan fallback ts)
# neighbor closed BEFORE children → no RELATES_TO_DRIFT
_rt6_base_ts=1700000000
_rt6_neighbor_closed_at=$((_rt6_base_ts + 1000))
_rt6_child_ts=$((_rt6_base_ts + 1200))

_rt6_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_rt6_ticket_dir")

_rt6_neighbor_json='{"ticket_id":"rt6-neighbor","ticket_type":"epic","status":"closed","parent_id":null,"created_at":'"$((_rt6_base_ts + 500))"',"closed_at":'"$_rt6_neighbor_closed_at"',"title":"Neighbor Epic","description":"","comments":[],"deps":[]}'

# Epic has NO PREPLANNING_CONTEXT comment (empty comments array)
_rt6_children_json='[{"ticket_id":"rt6-task-1","ticket_type":"task","status":"open","parent_id":"rt6-epic","created_at":'"$_rt6_child_ts"',"title":"Impl task","description":"## File Impact\n- src/app.py\n","comments":[],"deps":[]}]'
_rt6_epic_json='{"ticket_id":"rt6-epic","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_rt6_base_ts + 800))"',"title":"Main Epic","description":"","comments":[],"deps":[{"target_id":"rt6-neighbor","relation":"relates_to","link_uuid":"eeee-5555"}]}'

_make_ticket_cli_with_relates_to "$_rt6_ticket_dir" "rt6-epic" "$_rt6_epic_json" "$_rt6_children_json" "rt6-neighbor" "$_rt6_neighbor_json"

_rt6_exit=0
_rt6_output=$(TICKET_CMD="$_rt6_ticket_dir/ticket" bash "$SCRIPT" "rt6-epic" --repo="$_rt6_repo" 2>&1) || _rt6_exit=$?

assert_eq "fallback-children-ts: exits 0" "0" "$_rt6_exit"
# Neighbor closed BEFORE earliest child → no RELATES_TO_DRIFT when using children fallback ts
_rt6_drift_present=0
grep -q "RELATES_TO_DRIFT" <<< "$_rt6_output" && _rt6_drift_present=1 || true
assert_eq "fallback-children-ts: no RELATES_TO_DRIFT (neighbor closed before children ts)" "0" "$_rt6_drift_present"

echo ""
print_summary
