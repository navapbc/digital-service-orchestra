#!/usr/bin/env bash
# tests/scripts/test-sprint-review-scope-check.sh
# RED tests for plugins/dso/scripts/sprint-review-scope-check.sh (does not exist yet).
# REVIEW-DEFENSE: Script intentionally absent — TDD RED phase. Sprint 9d3e-957d batch 4
# creates these tests; the script will be implemented in a subsequent batch. All 7 tests
# are registered with RED markers in .test-index.
#
# Behavioral tests: create mock reviewer-findings.json files and a mock ticket CLI
# that returns task descriptions with ## File Impact sections, then execute the
# script and assert on stdout (IN_SCOPE / OUT_OF_SCOPE) and exit codes.
#
# Usage: bash tests/scripts/test-sprint-review-scope-check.sh
# Returns: exit 0 if all pass (once GREEN), exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
# Pin CWD to REPO_ROOT so subshells inherit a stable directory (fb93-69da / 7993-e05f).
# suite-engine sets TMPDIR to a per-test dir that gets deleted after the test exits;
# on CI Linux, bash resolves CWD from TMPDIR at startup, causing getcwd failures
# when the test_tmpdir is removed.
cd "$REPO_ROOT"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint-review-scope-check.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

echo "=== test-sprint-review-scope-check.sh ==="

# ── Helper: create a mock ticket CLI that returns a task description ──────────
# Usage: _make_ticket_cli <dir> <task_id> <description_body>
# The description_body should be the full multi-line description string
# (can include a ## File Impact section).
_make_ticket_cli() {
    local dir="$1"
    local task_id="$2"
    local description_body="$3"

    mkdir -p "$dir"
    # Write description to a temp file so heredoc quoting is not an issue
    local desc_file="$dir/desc_${task_id}.txt"
    printf '%s' "$description_body" > "$desc_file"

    cat > "$dir/ticket" << 'TICKET_EOF'
#!/usr/bin/env bash
SUBCMD="${1:-}"
shift || true
case "$SUBCMD" in
    show)
        TICKET_ID="${1:-}"
        DESC_FILE="$(dirname "$0")/desc_${TICKET_ID}.txt"
        if [[ -f "$DESC_FILE" ]]; then
            python3 -c "
import json, sys
desc = open(sys.argv[1]).read()
print(json.dumps({'ticket_id': sys.argv[2], 'ticket_type': 'task', 'status': 'open',
                  'description': desc, 'title': 'Test task', 'comments': [], 'deps': []}))
" "$DESC_FILE" "$TICKET_ID"
            exit 0
        fi
        echo '{}'
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
TICKET_EOF
    chmod +x "$dir/ticket"
}

# ── Helper: write a reviewer-findings.json to a given path ───────────────────
# Usage: _write_findings <path> <findings_json_array>
_write_findings() {
    local path="$1"
    local findings_array="$2"
    python3 -c "
import json, sys
findings = json.loads(sys.argv[1])
out = {'scores': {'correctness': 4}, 'findings': findings, 'summary': 'Test summary.'}
with open(sys.argv[2], 'w') as f:
    json.dump(out, f)
" "$findings_array" "$path"
}

# ── Test 1: missing_args — no arguments exits non-zero with usage ─────────────
echo ""
echo "Test 1: missing_args — no arguments exits non-zero with usage message"

_t1_exit=0
_t1_output=$(bash "$SCRIPT" 2>&1) || _t1_exit=$?

assert_ne "missing-args: exits non-zero when no args given" "0" "$_t1_exit"
assert_contains "missing-args: output contains usage hint" "usage" "$(echo "$_t1_output" | tr '[:upper:]' '[:lower:]')"

# ── Test 2: in_scope — all findings reference files within the task impact table ─
echo ""
echo "Test 2: in_scope — all findings reference files in task impact table → IN_SCOPE, exit 0"

_t2_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t2_dir")
_t2_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t2_ticket_dir")

_t2_findings_path="$_t2_dir/reviewer-findings.json"
_t2_findings='[
  {"severity":"important","description":"Needs improvement","file":"src/app.py","category":"correctness"},
  {"severity":"minor","description":"Style nit","file":"tests/test_app.py","category":"hygiene"}
]'
_write_findings "$_t2_findings_path" "$_t2_findings"

_t2_description="## Description
Implement the feature.

## File Impact
- src/app.py
- tests/test_app.py
"
_make_ticket_cli "$_t2_ticket_dir" "t2-task" "$_t2_description"

_t2_exit=0
_t2_output=$(TICKET_CMD="$_t2_ticket_dir/ticket" bash "$SCRIPT" "$_t2_findings_path" "t2-task" 2>&1) || _t2_exit=$?

assert_eq "in-scope: exits 0" "0" "$_t2_exit"
assert_contains "in-scope: output contains IN_SCOPE" "IN_SCOPE" "$_t2_output"

# ── Test 3: out_of_scope — finding references file outside the task impact table ─
echo ""
echo "Test 3: out_of_scope — finding references file outside task impact table → OUT_OF_SCOPE, exit 0"

_t3_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t3_dir")
_t3_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t3_ticket_dir")

_t3_findings_path="$_t3_dir/reviewer-findings.json"
# Finding references plugins/dso/scripts/other.sh which is NOT in the impact table
_t3_findings='[
  {"severity":"critical","description":"Bug in scope","file":"src/app.py","category":"correctness"},
  {"severity":"important","description":"Issue outside scope","file":"plugins/dso/scripts/other.sh","category":"correctness"}
]'
_write_findings "$_t3_findings_path" "$_t3_findings"

_t3_description="## Description
Implement the feature.

## File Impact
- src/app.py
- tests/test_app.py
"
_make_ticket_cli "$_t3_ticket_dir" "t3-task" "$_t3_description"

_t3_exit=0
_t3_output=$(TICKET_CMD="$_t3_ticket_dir/ticket" bash "$SCRIPT" "$_t3_findings_path" "t3-task" 2>&1) || _t3_exit=$?

assert_eq "out-of-scope: exits 0" "0" "$_t3_exit"
assert_contains "out-of-scope: output contains OUT_OF_SCOPE" "OUT_OF_SCOPE" "$_t3_output"
assert_contains "out-of-scope: output lists the out-of-scope file" "plugins/dso/scripts/other.sh" "$_t3_output"

# ── Test 4: missing_findings_file — no reviewer-findings.json → graceful skip, IN_SCOPE ─
echo ""
echo "Test 4: missing_findings_file — reviewer-findings.json does not exist → graceful skip, IN_SCOPE"

_t4_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t4_dir")
_t4_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t4_ticket_dir")

_t4_nonexistent_path="$_t4_dir/nonexistent-reviewer-findings.json"

_t4_description="## Description
Implement the feature.

## File Impact
- src/app.py
"
_make_ticket_cli "$_t4_ticket_dir" "t4-task" "$_t4_description"

_t4_exit=0
_t4_output=$(TICKET_CMD="$_t4_ticket_dir/ticket" bash "$SCRIPT" "$_t4_nonexistent_path" "t4-task" 2>&1) || _t4_exit=$?

assert_eq "missing-findings: exits 0" "0" "$_t4_exit"
assert_contains "missing-findings: output contains IN_SCOPE" "IN_SCOPE" "$_t4_output"

# ── Test 5: no_file_impact_section — task has no ## File Impact section → graceful skip, IN_SCOPE ─
echo ""
echo "Test 5: no_file_impact_section — task description has no File Impact section → graceful skip, IN_SCOPE"

_t5_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t5_dir")
_t5_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t5_ticket_dir")

_t5_findings_path="$_t5_dir/reviewer-findings.json"
_t5_findings='[
  {"severity":"minor","description":"Small nit","file":"docs/README.md","category":"hygiene"}
]'
_write_findings "$_t5_findings_path" "$_t5_findings"

# No ## File Impact section in description
_t5_description="## Description
Just write some documentation. No code changes needed.
"
_make_ticket_cli "$_t5_ticket_dir" "t5-task" "$_t5_description"

_t5_exit=0
_t5_output=$(TICKET_CMD="$_t5_ticket_dir/ticket" bash "$SCRIPT" "$_t5_findings_path" "t5-task" 2>&1) || _t5_exit=$?

assert_eq "no-file-impact: exits 0" "0" "$_t5_exit"
assert_contains "no-file-impact: output contains IN_SCOPE" "IN_SCOPE" "$_t5_output"

# ── Test 6: findings_with_empty_file_paths — silently ignored, not OUT_OF_SCOPE ─
echo ""
echo "Test 6: findings_with_empty_file_paths — findings with empty/missing file field are ignored"

_t6_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t6_dir")
_t6_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t6_ticket_dir")

_t6_findings_path="$_t6_dir/reviewer-findings.json"
# One finding has empty file, one has missing file key — both should be silently ignored
_t6_findings='[
  {"severity":"minor","description":"General style concern","file":"","category":"hygiene"},
  {"severity":"important","description":"Structural concern with no file","category":"correctness"},
  {"severity":"minor","description":"In-scope finding","file":"src/app.py","category":"hygiene"}
]'
_write_findings "$_t6_findings_path" "$_t6_findings"

_t6_description="## Description
Implement the feature.

## File Impact
- src/app.py
"
_make_ticket_cli "$_t6_ticket_dir" "t6-task" "$_t6_description"

_t6_exit=0
_t6_output=$(TICKET_CMD="$_t6_ticket_dir/ticket" bash "$SCRIPT" "$_t6_findings_path" "t6-task" 2>&1) || _t6_exit=$?

assert_eq "empty-file-paths: exits 0" "0" "$_t6_exit"
# Empty/missing file paths must NOT trigger OUT_OF_SCOPE
assert_contains "empty-file-paths: output is IN_SCOPE (empty paths ignored)" "IN_SCOPE" "$_t6_output"

# ── Test 7: multiple_out_of_scope — multiple out-of-scope files all listed ────
echo ""
echo "Test 7: multiple_out_of_scope — multiple out-of-scope files all appear in output"

_t7_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t7_dir")
_t7_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t7_ticket_dir")

_t7_findings_path="$_t7_dir/reviewer-findings.json"
_t7_findings='[
  {"severity":"critical","description":"In-scope issue","file":"src/app.py","category":"correctness"},
  {"severity":"important","description":"Out-of-scope issue 1","file":"lib/utils.py","category":"correctness"},
  {"severity":"minor","description":"Out-of-scope issue 2","file":"config/settings.yaml","category":"hygiene"}
]'
_write_findings "$_t7_findings_path" "$_t7_findings"

_t7_description="## Description
Implement the feature.

## File Impact
- src/app.py
"
_make_ticket_cli "$_t7_ticket_dir" "t7-task" "$_t7_description"

_t7_exit=0
_t7_output=$(TICKET_CMD="$_t7_ticket_dir/ticket" bash "$SCRIPT" "$_t7_findings_path" "t7-task" 2>&1) || _t7_exit=$?

assert_eq "multiple-out-of-scope: exits 0" "0" "$_t7_exit"
assert_contains "multiple-out-of-scope: output contains OUT_OF_SCOPE" "OUT_OF_SCOPE" "$_t7_output"
assert_contains "multiple-out-of-scope: lists lib/utils.py" "lib/utils.py" "$_t7_output"
assert_contains "multiple-out-of-scope: lists config/settings.yaml" "config/settings.yaml" "$_t7_output"

echo ""
print_summary
