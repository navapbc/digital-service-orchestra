#!/usr/bin/env bash
# tests/scripts/test-check-orphan-epics.sh
# Behavioral tests for plugins/dso/scripts/end-session/check-orphan-epics.sh.
# Mocks the ticket CLI via TICKET_CMD env var so child enumeration is fully
# controlled by the test fixture.
#
# Usage: bash tests/scripts/test-check-orphan-epics.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$PLUGIN_ROOT/plugins/dso/scripts/end-session/check-orphan-epics.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-orphan-epics.sh ==="

# ---------------------------------------------------------------------------
# Fixture: install a fake repo with controllable git log + a mock ticket CLI.
# ---------------------------------------------------------------------------

# _setup: create temp dir with a git repo (so `git log <base>..HEAD` works) and
# a mock ticket binary. Returns: prints TMPDIR on stdout.
_setup() {
    local tmp; tmp=$(mktemp -d)
    (
        cd "$tmp" || exit 1
        git init -q
        git config user.email t@t
        git config user.name t
        git commit -q --allow-empty -m "initial"
        git branch -M main
        git checkout -q -b worktree
    )
    mkdir -p "$tmp/bin"
    echo "$tmp"
}

# _add_commit: append a commit to the worktree branch with the given message.
_add_commit() {
    local tmp="$1" msg="$2"
    (cd "$tmp" && git commit -q --allow-empty -m "$msg")
}

# _install_mock_ticket: writes a mock ticket binary that returns canned JSON
# for `ticket list ...`. The fixture file maps invocation patterns to JSON.
# Format: pattern<TAB>json (one per line); first match wins.
_install_mock_ticket() {
    local tmp="$1" fixture="$2"
    local mock="$tmp/bin/ticket"
    cat > "$mock" <<MOCKEOF
#!/usr/bin/env bash
set -uo pipefail
ARGS="\$*"
while IFS=\$'\t' read -r pattern payload; do
    [[ -z "\$pattern" ]] && continue
    if [[ "\$ARGS" == *"\$pattern"* ]]; then
        printf '%s\n' "\$payload"
        exit 0
    fi
done < "$fixture"
echo "[]"
exit 0
MOCKEOF
    chmod +x "$mock"
}

# _run: run the helper inside the temp repo with the mock ticket CLI bound.
# Args: $1=tmpdir
# Stdout: helper's JSON output
_run() {
    local tmp="$1"
    (cd "$tmp" && TICKET_CMD="$tmp/bin/ticket" bash "$HELPER" --base-ref main 2>/dev/null)
}

# Each test must produce no orphan files in $tmp; trap cleans up.

# ---------------------------------------------------------------------------
# test_no_in_progress_epics_returns_empty
# When `ticket list --type=epic --status=in_progress` returns [], helper
# emits an empty array and exits 0.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
fixture="$tmp/fixture"
printf 'list --type=epic --status=in_progress\t[]\n' > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_eq "test_no_in_progress_epics_emits_empty_array" "[]" "$out"
assert_pass_if_clean "test_no_in_progress_epics_returns_empty"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_no_children_classifies_as_no_children
# An in-progress epic with zero children gets child_status=no_children.
# session_related stays false (irrelevant for this status).
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
fixture="$tmp/fixture"
{
    printf 'list --type=epic --status=in_progress\t[{"ticket_id":"e1","title":"Lonely epic","status":"in_progress"}]\n'
    printf 'list --parent=e1\t[]\n'
} > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_contains "test_no_children_status" '"child_status": "no_children"' "$out"
assert_contains "test_no_children_session_related_false" '"session_related": false' "$out"
assert_pass_if_clean "test_no_children_classifies_as_no_children"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_open_children_blocks_close
# An epic with at least one non-closed child gets child_status=open_children.
# This is the primary safety gate — if missed, the helper would mark a still-
# active epic as closeable.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
fixture="$tmp/fixture"
{
    printf 'list --type=epic --status=in_progress\t[{"ticket_id":"e2","title":"Live work","status":"in_progress"}]\n'
    printf 'list --parent=e2\t[{"ticket_id":"c1","status":"closed"},{"ticket_id":"c2","status":"open"}]\n'
} > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_contains "test_open_children_status" '"child_status": "open_children"' "$out"
# match_reason should be null when we don't compute relatedness for non-candidates
assert_contains "test_open_children_no_match_reason" '"match_reason": null' "$out"
assert_pass_if_clean "test_open_children_blocks_close"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_all_closed_with_epic_id_in_commit_marks_session_related
# All children closed AND the epic id appears in a commit message → candidate
# is session-related, match_reason="epic_id".
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
_add_commit "$tmp" "feat: complete e3 deliverables"
fixture="$tmp/fixture"
{
    printf 'list --type=epic --status=in_progress\t[{"ticket_id":"e3","title":"Epic three","status":"in_progress"}]\n'
    printf 'list --parent=e3\t[{"ticket_id":"c1","status":"closed"}]\n'
} > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_contains "test_all_closed_session_related_true" '"session_related": true' "$out"
assert_contains "test_all_closed_match_reason_epic_id" '"match_reason": "epic_id"' "$out"
assert_pass_if_clean "test_all_closed_with_epic_id_in_commit_marks_session_related"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_all_closed_with_child_id_in_commit_marks_session_related
# Epic id absent from commits, but a child id is — relatedness via child_id.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
_add_commit "$tmp" "implement child cccc-aaaa"
fixture="$tmp/fixture"
{
    printf 'list --type=epic --status=in_progress\t[{"ticket_id":"epic-x","title":"Some epic","status":"in_progress"}]\n'
    printf 'list --parent=epic-x\t[{"ticket_id":"cccc-aaaa","status":"closed"},{"ticket_id":"dddd-bbbb","status":"closed"}]\n'
} > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_contains "test_child_id_match_session_related" '"session_related": true' "$out"
assert_contains "test_child_id_match_reason" '"match_reason": "child_id"' "$out"
assert_pass_if_clean "test_all_closed_with_child_id_in_commit_marks_session_related"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_all_closed_with_two_title_keywords_marks_session_related
# Neither id present, but two non-stop title keywords appear in commit msgs.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
_add_commit "$tmp" "wireframe accessibility refactor for the dashboard"
fixture="$tmp/fixture"
{
    printf 'list --type=epic --status=in_progress\t[{"ticket_id":"epic-y","title":"Wireframe accessibility audit","status":"in_progress"}]\n'
    printf 'list --parent=epic-y\t[{"ticket_id":"qqqq","status":"closed"}]\n'
} > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_contains "test_title_kw_session_related" '"session_related": true' "$out"
assert_contains "test_title_kw_match_reason" '"match_reason": "title_keywords"' "$out"
assert_pass_if_clean "test_all_closed_with_two_title_keywords_marks_session_related"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_all_closed_unrelated_session_marks_false
# All closed, but commits are completely unrelated. session_related=false.
# This is the case Step 3 handles by reporting informationally without
# closing — must not be misclassified as candidate.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
_add_commit "$tmp" "completely unrelated work over here"
fixture="$tmp/fixture"
{
    printf 'list --type=epic --status=in_progress\t[{"ticket_id":"epic-z","title":"Migration tooling","status":"in_progress"}]\n'
    printf 'list --parent=epic-z\t[{"ticket_id":"q1","status":"closed"}]\n'
} > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_contains "test_unrelated_status" '"child_status": "all_closed"' "$out"
assert_contains "test_unrelated_session_false" '"session_related": false' "$out"
assert_contains "test_unrelated_match_null" '"match_reason": null' "$out"
assert_pass_if_clean "test_all_closed_unrelated_session_marks_false"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_one_keyword_does_not_match
# Single matching keyword is below the >=2 threshold; session_related=false.
# Guards against false-positive auto-close on superficial title overlap.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
_add_commit "$tmp" "minor migration cleanup"
fixture="$tmp/fixture"
{
    printf 'list --type=epic --status=in_progress\t[{"ticket_id":"epic-q","title":"Migration tooling overhaul","status":"in_progress"}]\n'
    printf 'list --parent=epic-q\t[{"ticket_id":"q1","status":"closed"}]\n'
} > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
assert_contains "test_one_keyword_session_false" '"session_related": false' "$out"
assert_pass_if_clean "test_one_keyword_does_not_match"
rm -rf "$tmp"

# ---------------------------------------------------------------------------
# test_helper_emits_valid_json
# Output parses as JSON regardless of input shape.
# ---------------------------------------------------------------------------
_snapshot_fail
tmp=$(_setup)
fixture="$tmp/fixture"
printf 'list --type=epic --status=in_progress\t[{"ticket_id":"e","title":"t","status":"in_progress"}]\nlist --parent=e\t[]\n' > "$fixture"
_install_mock_ticket "$tmp" "$fixture"
out=$(_run "$tmp")
echo "$out" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null
parse_rc=$?
assert_eq "test_emits_parseable_json_rc" "0" "$parse_rc"
assert_pass_if_clean "test_helper_emits_valid_json"
rm -rf "$tmp"

echo
print_summary
