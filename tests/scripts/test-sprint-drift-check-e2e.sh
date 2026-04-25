#!/usr/bin/env bash
# tests/scripts/test-sprint-drift-check-e2e.sh
#
# End-to-end tests for the relates_to drift detection path (sprint-drift-check.sh)
# and the brainstorm link suggestion structural boundary (epic-scrutiny-pipeline.md).
#
# Testing Mode: GREEN — implementation already exists.
#
# Test 1 (e2e execution):
#   Given: two epics linked via relates_to; epic-B closed AFTER impl plan timestamp
#   When:  sprint-drift-check.sh is run on epic-A
#   Then:  RELATES_TO_DRIFT is emitted containing epic-B's ID
#
# Test 2 (structural boundary — Rule 5 compliant):
#   Verify epic-scrutiny-pipeline.md Part C contains the relates_to link suggestion
#   section.  This tests the structural contract of the non-executable instruction
#   document (section heading / marker presence), not its wording.
#
# Usage: bash tests/scripts/test-sprint-drift-check-e2e.sh
# Returns: exit 0 if all pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint-drift-check.sh"
PIPELINE_MD="$REPO_ROOT/plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"

source "$SCRIPT_DIR/../lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

echo "=== test-sprint-drift-check-e2e.sh ==="

# ── Helper: create a minimal git repo ────────────────────────────────────────
_make_git_repo() {
    local dir="$1"
    git init -q -b main "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    touch "$dir/README.md"
    git -C "$dir" add README.md
    git -C "$dir" commit -q -m "initial"
}

# ── Helper: create a mock ticket CLI supporting two epics (epic-A + epic-B) ──
# Usage: _make_ticket_cli <dir> <epic_a_id> <epic_a_json>
#                         <children_json>
#                         <epic_b_id> <epic_b_json>
#
# Responds to:
#   show <epic_a_id>  → epic_a_json  (has relates_to dep on epic_b_id)
#   show <epic_b_id>  → epic_b_json  (the neighbor epic that was closed)
#   show <child_id>   → dispatched from children_json
#   list              → children_json
_make_ticket_cli() {
    local dir="$1"
    local epic_a_id="$2"
    local epic_a_json="$3"
    local children_json="$4"
    local epic_b_id="$5"
    local epic_b_json="$6"

    mkdir -p "$dir"
    cat > "$dir/ticket" << TICKET_SCRIPT
#!/usr/bin/env bash
SUBCMD="\${1:-}"
shift || true
case "\$SUBCMD" in
    show)
        TICKET_ID="\${1:-}"
        if [[ "\$TICKET_ID" == "$epic_a_id" ]]; then
            printf '%s\n' '$epic_a_json'
            exit 0
        fi
        if [[ "\$TICKET_ID" == "$epic_b_id" ]]; then
            printf '%s\n' '$epic_b_json'
            exit 0
        fi
        # Child ticket dispatch from children array
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

# ── Test: test_relates_to_drift_e2e — end-to-end relates_to drift detection ───
# Given: epic-A has a relates_to dep on epic-B.
#        epic-A has one impl-plan child task (created at T=impl_plan_ts).
#        epic-B is closed at T=(impl_plan_ts + 100) — AFTER the impl plan.
# When:  sprint-drift-check.sh is run on epic-A.
# Then:  RELATES_TO_DRIFT is emitted containing epic-B's ID.
echo ""
echo "Test: test_relates_to_drift_e2e — epic-B closed after impl plan → RELATES_TO_DRIFT emitted"

_e2e1_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_e2e1_repo")
_make_git_repo "$_e2e1_repo"

# T=impl_plan_ts: when the implementation plan tasks were created
_e2e1_impl_plan_ts=$(date +%s)

# epic-B was closed 100 seconds AFTER the impl plan — this is the drift trigger
_e2e1_epic_b_closed_at=$((_e2e1_impl_plan_ts + 100))

_e2e1_ticket_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_e2e1_ticket_dir")

# epic-B: closed after impl plan timestamp
_e2e1_epic_b_json='{"ticket_id":"e2e1-epic-b","ticket_type":"epic","status":"closed","parent_id":null,"created_at":'"$((_e2e1_impl_plan_ts - 200))"',"closed_at":'"$_e2e1_epic_b_closed_at"',"title":"Related Epic B","description":"","comments":[],"deps":[]}'

# epic-A: open, has a relates_to dep linking to epic-B
_e2e1_children_json='[{"ticket_id":"e2e1-task-1","ticket_type":"task","status":"open","parent_id":"e2e1-epic-a","created_at":'"$_e2e1_impl_plan_ts"',"title":"Impl task","description":"## File Impact\n- src/feature.py\n","comments":[],"deps":[]}]'
_e2e1_epic_a_json='{"ticket_id":"e2e1-epic-a","ticket_type":"epic","status":"open","parent_id":null,"created_at":'"$((_e2e1_impl_plan_ts - 300))"',"title":"Main Epic A","description":"","comments":[],"deps":[{"target_id":"e2e1-epic-b","relation":"relates_to","link_uuid":"e2e1-aaaa-1111"}]}'

_make_ticket_cli "$_e2e1_ticket_dir" \
    "e2e1-epic-a" "$_e2e1_epic_a_json" \
    "$_e2e1_children_json" \
    "e2e1-epic-b" "$_e2e1_epic_b_json"

_e2e1_exit=0
_e2e1_output=$(TICKET_CMD="$_e2e1_ticket_dir/ticket" bash "$SCRIPT" "e2e1-epic-a" --repo="$_e2e1_repo" 2>&1) || _e2e1_exit=$?

assert_eq "e2e1: script exits 0" "0" "$_e2e1_exit"
assert_contains "e2e1: RELATES_TO_DRIFT emitted" "RELATES_TO_DRIFT" "$_e2e1_output"
assert_contains "e2e1: epic-B ID present in drift output" "e2e1-epic-b" "$_e2e1_output"

# ── Test: test_brainstorm_suggestion_structural_boundary ─────────────────────
# Given: epic-scrutiny-pipeline.md exists and contains a Part C section.
# When:  Part C content is extracted and inspected for the relates_to suggestion.
# Then:  The relates_to link suggestion section is present in Part C.
#
# Rule 5 compliance: This test checks section heading / structural marker presence
# in a non-executable instruction document.  The structural markers (section label,
# relates_to keyword, and ticket link CLI reference within Part C) are the
# deterministic integration interface consumed by LLM agents at runtime.
echo ""
echo "Test: test_brainstorm_suggestion_structural_boundary — epic-scrutiny-pipeline.md Part C contains relates_to suggestion"

if [[ ! -f "$PIPELINE_MD" ]]; then
    (( ++FAIL ))
    echo "FAIL: e2e2: epic-scrutiny-pipeline.md not found at $PIPELINE_MD" >&2
else
    # Extract Part C section (from '### Part C' to next '###' or '##' heading)
    _part_c_start=$(grep -n "^### Part C" "$PIPELINE_MD" | head -1 | cut -d: -f1)

    if [[ -z "$_part_c_start" ]]; then
        (( ++FAIL ))
        echo "FAIL: e2e2: Part C section not found in epic-scrutiny-pipeline.md" >&2
    else
        _part_c_content=$(awk "NR==${_part_c_start}{found=1} found && NR>${_part_c_start} && /^##/{exit} found{print}" "$PIPELINE_MD")

        # Assert: relates_to keyword present in Part C
        _e2e2_has_relates_to=0
        grep -qiE "relates_to|relates-to" <<< "$_part_c_content" && _e2e2_has_relates_to=1 || true
        assert_eq "e2e2: Part C contains relates_to link suggestion section" "1" "$_e2e2_has_relates_to"

        # Assert: user approval gate present before link creation (Rule 5 structural contract)
        _e2e2_has_approval_gate=0
        grep -qiE "(AskUser|user.*approv|user.*confirm|confirm.*user|approv.*link|before.*creat)" <<< "$_part_c_content" && _e2e2_has_approval_gate=1 || true
        assert_eq "e2e2: Part C contains user approval gate before relates_to link creation" "1" "$_e2e2_has_approval_gate"

        # Assert: ticket link CLI command referenced in Part C for relates_to relation
        _e2e2_has_ticket_link=0
        grep -qiE "(ticket link|dso ticket link)" <<< "$_part_c_content" && _e2e2_has_ticket_link=1 || true
        assert_eq "e2e2: Part C references ticket link CLI for relates_to relation" "1" "$_e2e2_has_ticket_link"
    fi
fi

# ── Test: test_sprint_skill_relates_to_drift_handler_structural_boundary ─────
# Given: plugins/dso/skills/sprint/SKILL.md exists with a RELATES_TO_DRIFT handler.
# When:  The file is inspected for the RELATES_TO_DRIFT section and its content.
# Then:  RELATES_TO_DRIFT is present AND the handler references REPLAN_TRIGGER.
#
# Rule 5 compliance: This test checks structural markers in a non-executable
# instruction document. The presence of RELATES_TO_DRIFT and its reference to
# REPLAN_TRIGGER constitutes the deterministic structural boundary contract
# consumed by LLM agents at sprint runtime.
echo ""
echo "Test: test_sprint_skill_relates_to_drift_handler_structural_boundary — sprint SKILL.md contains RELATES_TO_DRIFT referencing REPLAN_TRIGGER"

_sprint_skill_md="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

if [[ ! -f "$_sprint_skill_md" ]]; then
    (( ++FAIL ))
    echo "FAIL: e2e3: sprint SKILL.md not found at $_sprint_skill_md" >&2
else
    # Assert 1: RELATES_TO_DRIFT handler section exists
    _e2e3_has_relates_to_drift=0
    grep -qF "RELATES_TO_DRIFT" "$_sprint_skill_md" && _e2e3_has_relates_to_drift=1 || true
    assert_eq "e2e3: sprint SKILL.md contains RELATES_TO_DRIFT" "1" "$_e2e3_has_relates_to_drift"

    # Assert 2: The RELATES_TO_DRIFT section references REPLAN_TRIGGER
    # Extract the RELATES_TO_DRIFT handler block (from the header line to the next
    # blank-line-terminated section boundary or the next bold heading).
    _e2e3_section=$(awk '/\*\*If `RELATES_TO_DRIFT`/{found=1} found && /^\*\*If `(NO_DRIFT|DRIFT_DETECTED)`/{exit} found{print}' "$_sprint_skill_md")
    _e2e3_has_replan_trigger=0
    grep -qF "REPLAN_TRIGGER" <<< "$_e2e3_section" && _e2e3_has_replan_trigger=1 || true
    assert_eq "e2e3: RELATES_TO_DRIFT section references REPLAN_TRIGGER" "1" "$_e2e3_has_replan_trigger"
fi

echo ""
print_summary
