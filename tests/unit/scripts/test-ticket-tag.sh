#!/usr/bin/env bash
# tests/unit/scripts/test-ticket-tag.sh
# RED tests for _tag_add/_tag_remove helpers in ticket-lib.sh and
# the ticket tag / ticket untag CLI subcommands (ticket-tag.sh, ticket-untag.sh).
#
# All 7 tests MUST FAIL until the implementation exists:
#   - plugins/dso/scripts/ticket-lib.sh: _tag_add, _tag_remove functions
#   - plugins/dso/scripts/ticket-tag.sh: ticket tag <id> <tag>
#   - plugins/dso/scripts/ticket-untag.sh: ticket untag <id> <tag>
#   - plugins/dso/scripts/ticket: tag/untag routing entries
#
# Usage: bash tests/unit/scripts/test-ticket-tag.sh
# Returns: exit 1 (RED) until implementation is present.

# NOTE: -e intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner on
# the first expected failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

# Finding 1: Explicit initialization BEFORE sourcing git-fixtures.sh so
# _CLEANUP_DIRS is always defined even if the source call fails.
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-tag.sh ==="

# ── Helper: create a fresh isolated ticket repo, return path ─────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: create a ticket in a repo (cd-based) and return its ID ───────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local extra_args="${4:-}"
    local out
    # shellcheck disable=SC2086
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" $extra_args 2>/dev/null) || true
    echo "$out"
}

# ── Helper: get tags list from ticket show JSON output ───────────────────────
_get_tags() {
    local repo="$1"
    local ticket_id="$2"
    cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(','.join(d.get('tags',[])))"
}

# ── Helper: create a ticket with optional initial tags at create time ─────────
# Finding 4: Use --tags at create time instead of a brittle post-create edit.
_create_fixture_ticket() {
    local repo_dir="$1"
    local initial_tags="${2:-}"

    local create_args=("story" "test story")
    if [[ -n "$initial_tags" ]]; then
        create_args+=("--tags" "$initial_tags")
    fi

    (cd "$repo_dir" && bash "$TICKET_SCRIPT" create "${create_args[@]}" 2>/dev/null) \
        | tr -d '[:space:]'
}

# ── Helper: get most-recent EDIT event file path in tracker ──────────────────
_latest_edit_event() {
    local tracker_dir="$1"
    local ticket_id="$2"
    find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-EDIT.json' ! -name '.*' 2>/dev/null \
        | sort | tail -1
}

# =============================================================================
# Test 1 — _tag_add appends new tag and preserves existing siblings
# =============================================================================
echo ""
echo "--- test_tag_add_appends_new_tag_preserves_siblings ---"

test_tag_add_appends_new_tag_preserves_siblings() {
    _snapshot_fail

    # Finding 2: fail explicitly if ticket-lib.sh not found
    if ! source "$TICKET_LIB" 2>/dev/null; then
        (( ++FAIL ))
        echo "FAIL: test_tag_add_appends_new_tag_preserves_siblings: ticket-lib.sh not found at expected path" >&2
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Given: a ticket with "existing-tag" already applied at create time
    local ticket_id
    ticket_id=$(_create_fixture_ticket "$repo" "existing-tag")
    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty-id" "empty-id" 2>/dev/null
        assert_pass_if_clean "test_tag_add_appends_new_tag_preserves_siblings"
        return
    fi

    # When: _tag_add is called (sourcing ticket-lib.sh)
    (
        cd "$repo"
        # shellcheck source=/dev/null
        source "$TICKET_LIB"
        _tag_add "$ticket_id" "new-tag"
    ) 2>/dev/null

    # Then: ticket show output contains BOTH tags
    local tags
    tags=$(_get_tags "$repo" "$ticket_id")

    assert_contains "test_tag_add_appends_new_tag_preserves_siblings: existing-tag present" \
        "existing-tag" "$tags"
    assert_contains "test_tag_add_appends_new_tag_preserves_siblings: new-tag present" \
        "new-tag" "$tags"

    assert_pass_if_clean "test_tag_add_appends_new_tag_preserves_siblings"
}

test_tag_add_appends_new_tag_preserves_siblings

# =============================================================================
# Test 2 — _tag_add is idempotent (no duplicate tags)
# =============================================================================
echo ""
echo "--- test_tag_add_idempotent ---"

test_tag_add_idempotent() {
    _snapshot_fail

    # Finding 2: fail explicitly if ticket-lib.sh not found
    if ! source "$TICKET_LIB" 2>/dev/null; then
        (( ++FAIL ))
        echo "FAIL: test_tag_add_idempotent: ticket-lib.sh not found at expected path" >&2
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Given: a ticket with tag "foo" applied at create time
    local ticket_id
    ticket_id=$(_create_fixture_ticket "$repo" "foo")
    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty-id" "empty-id" 2>/dev/null
        assert_pass_if_clean "test_tag_add_idempotent"
        return
    fi

    # When: _tag_add called twice with the same tag.
    # RED gate: _tag_add must exist (function defined in ticket-lib.sh).
    # If absent, the subshell exits non-zero from set -e or command-not-found;
    # we detect this and force a RED assertion.
    local add_exit=0
    (
        set -e
        cd "$repo"
        # shellcheck source=/dev/null
        source "$TICKET_LIB"
        _tag_add "$ticket_id" "foo"
        _tag_add "$ticket_id" "foo"
    ) 2>/dev/null || add_exit=$?

    # _tag_add must succeed (exit 0) — RED until function exists
    assert_eq "test_tag_add_idempotent: _tag_add exists and exits 0" "0" "$add_exit"

    # Then: "foo" appears exactly once (no duplicate)
    local tags
    tags=$(_get_tags "$repo" "$ticket_id")

    # Count occurrences of "foo" by splitting on comma
    local count
    count=$(echo "$tags" | tr ',' '\n' | grep -c '^foo$' 2>/dev/null || echo "0")

    assert_eq "test_tag_add_idempotent: foo appears exactly once" "1" "$count"

    assert_pass_if_clean "test_tag_add_idempotent"
}

test_tag_add_idempotent

# =============================================================================
# Test 3 — _tag_remove removes target tag, preserves sibling tags
# =============================================================================
echo ""
echo "--- test_tag_remove_removes_target_preserves_siblings ---"

test_tag_remove_removes_target_preserves_siblings() {
    _snapshot_fail

    # Finding 2: fail explicitly if ticket-lib.sh not found
    if ! source "$TICKET_LIB" 2>/dev/null; then
        (( ++FAIL ))
        echo "FAIL: test_tag_remove_removes_target_preserves_siblings: ticket-lib.sh not found at expected path" >&2
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Given: a ticket with tags ["keep-tag", "remove-tag"] applied at create time
    local ticket_id
    ticket_id=$(_create_fixture_ticket "$repo" "keep-tag,remove-tag")
    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty-id" "empty-id" 2>/dev/null
        assert_pass_if_clean "test_tag_remove_removes_target_preserves_siblings"
        return
    fi

    # When: _tag_remove called with "remove-tag"
    (
        cd "$repo"
        # shellcheck source=/dev/null
        source "$TICKET_LIB"
        _tag_remove "$ticket_id" "remove-tag"
    ) 2>/dev/null

    # Then: "keep-tag" present, "remove-tag" absent
    local tags
    tags=$(_get_tags "$repo" "$ticket_id")

    assert_contains "test_tag_remove_removes_target_preserves_siblings: keep-tag present" \
        "keep-tag" "$tags"

    # Assert remove-tag is NOT present: the tags string should not contain it
    local has_remove
    has_remove=0
    if [[ "$tags" == *"remove-tag"* ]]; then
        has_remove=1
    fi
    assert_eq "test_tag_remove_removes_target_preserves_siblings: remove-tag absent" \
        "0" "$has_remove"

    assert_pass_if_clean "test_tag_remove_removes_target_preserves_siblings"
}

test_tag_remove_removes_target_preserves_siblings

# =============================================================================
# Test 4 — _tag_remove is idempotent when tag is absent (exits 0, preserves others)
# =============================================================================
echo ""
echo "--- test_tag_remove_idempotent_when_absent ---"

test_tag_remove_idempotent_when_absent() {
    _snapshot_fail

    # Finding 2: fail explicitly if ticket-lib.sh not found
    if ! source "$TICKET_LIB" 2>/dev/null; then
        (( ++FAIL ))
        echo "FAIL: test_tag_remove_idempotent_when_absent: ticket-lib.sh not found at expected path" >&2
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Given: a ticket with tag "foo" only, applied at create time
    local ticket_id
    ticket_id=$(_create_fixture_ticket "$repo" "foo")
    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty-id" "empty-id" 2>/dev/null
        assert_pass_if_clean "test_tag_remove_idempotent_when_absent"
        return
    fi

    # When: _tag_remove called with "bar" (absent tag)
    local exit_code=0
    (
        cd "$repo"
        # shellcheck source=/dev/null
        source "$TICKET_LIB"
        _tag_remove "$ticket_id" "bar"
    ) 2>/dev/null || exit_code=$?

    assert_eq "test_tag_remove_idempotent_when_absent: exits 0" "0" "$exit_code"

    # "foo" still present after removing absent "bar"
    local tags
    tags=$(_get_tags "$repo" "$ticket_id")
    assert_contains "test_tag_remove_idempotent_when_absent: foo still present" \
        "foo" "$tags"

    assert_pass_if_clean "test_tag_remove_idempotent_when_absent"
}

test_tag_remove_idempotent_when_absent

# =============================================================================
# Test 5 — _tag_remove on last tag writes data.fields.tags = [] in EDIT event
# =============================================================================
echo ""
echo "--- test_tag_remove_empty_set_uses_fields_schema ---"

test_tag_remove_empty_set_uses_fields_schema() {
    _snapshot_fail

    # Finding 2: fail explicitly if ticket-lib.sh not found
    if ! source "$TICKET_LIB" 2>/dev/null; then
        (( ++FAIL ))
        echo "FAIL: test_tag_remove_empty_set_uses_fields_schema: ticket-lib.sh not found at expected path" >&2
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Given: a ticket with exactly one tag "last-tag", applied at create time
    local ticket_id
    ticket_id=$(_create_fixture_ticket "$repo" "last-tag")
    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty-id" "empty-id" 2>/dev/null
        assert_pass_if_clean "test_tag_remove_empty_set_uses_fields_schema"
        return
    fi

    # When: _tag_remove called with "last-tag"
    local exit_code=0
    (
        cd "$repo"
        # shellcheck source=/dev/null
        source "$TICKET_LIB"
        _tag_remove "$ticket_id" "last-tag"
    ) 2>/dev/null || exit_code=$?

    assert_eq "test_tag_remove_empty_set_uses_fields_schema: exits 0" "0" "$exit_code"

    # Then: most recent EDIT event has data.fields.tags == []
    local latest_edit
    latest_edit=$(_latest_edit_event "$tracker_dir" "$ticket_id")

    if [ -z "$latest_edit" ]; then
        assert_eq "test_tag_remove_empty_set_uses_fields_schema: EDIT event exists" \
            "non-empty-path" "empty-path"
        assert_pass_if_clean "test_tag_remove_empty_set_uses_fields_schema"
        return
    fi

    local tags_json
    tags_json=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    ev = json.load(f)
tags = ev.get('data', {}).get('fields', {}).get('tags', 'MISSING')
print(json.dumps(tags))
" "$latest_edit" 2>/dev/null || echo '"MISSING"')

    assert_eq "test_tag_remove_empty_set_uses_fields_schema: data.fields.tags is []" \
        "[]" "$tags_json"

    assert_pass_if_clean "test_tag_remove_empty_set_uses_fields_schema"
}

test_tag_remove_empty_set_uses_fields_schema

# =============================================================================
# Test 6 — ticket tag CLI adds a tag
# =============================================================================
echo ""
echo "--- test_ticket_tag_cli_adds_tag ---"

test_ticket_tag_cli_adds_tag() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Given: a ticket exists
    local ticket_id
    ticket_id=$(_create_ticket "$repo" story "CLI tag test story")
    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty-id" "empty-id" 2>/dev/null
        assert_pass_if_clean "test_ticket_tag_cli_adds_tag"
        return
    fi

    # When: ticket tag CLI is invoked
    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" tag "$ticket_id" "cli-new-tag" 2>/dev/null) || exit_code=$?

    assert_eq "test_ticket_tag_cli_adds_tag: exits 0" "0" "$exit_code"

    # Then: ticket show contains the new tag
    local tags
    tags=$(_get_tags "$repo" "$ticket_id")
    assert_contains "test_ticket_tag_cli_adds_tag: cli-new-tag in output" \
        "cli-new-tag" "$tags"

    assert_pass_if_clean "test_ticket_tag_cli_adds_tag"
}

test_ticket_tag_cli_adds_tag

# =============================================================================
# Test 7 — ticket untag CLI removes a tag
# =============================================================================
echo ""
echo "--- test_ticket_untag_cli_removes_tag ---"

test_ticket_untag_cli_removes_tag() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Given: a ticket with "test-tag" applied
    local ticket_id
    ticket_id=$(_create_ticket "$repo" story "CLI untag test story")
    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty-id" "empty-id" 2>/dev/null
        assert_pass_if_clean "test_ticket_untag_cli_removes_tag"
        return
    fi
    (cd "$repo" && bash "$TICKET_SCRIPT" edit "$ticket_id" --tags="test-tag,sibling-tag" 2>/dev/null) || true

    # When: ticket untag CLI is invoked
    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" untag "$ticket_id" "test-tag" 2>/dev/null) || exit_code=$?

    assert_eq "test_ticket_untag_cli_removes_tag: exits 0" "0" "$exit_code"

    # Then: ticket show output does NOT contain "test-tag"
    local tags
    tags=$(_get_tags "$repo" "$ticket_id")

    local has_test_tag=0
    if [[ "$tags" == *"test-tag"* ]]; then
        has_test_tag=1
    fi
    assert_eq "test_ticket_untag_cli_removes_tag: test-tag removed" "0" "$has_test_tag"

    # sibling-tag should still be present
    assert_contains "test_ticket_untag_cli_removes_tag: sibling-tag preserved" \
        "sibling-tag" "$tags"

    assert_pass_if_clean "test_ticket_untag_cli_removes_tag"
}

test_ticket_untag_cli_removes_tag

# ── PIL detection and _tag_add_checked guard (Story 2: c095-26fe) ─────────────
# RED tests for _ticket_has_pil and _tag_add_checked (task 4d04-b152).
# These MUST FAIL until ticket-lib.sh implements _ticket_has_pil and
# _tag_add_checked, and ticket-tag.sh dispatches through _tag_add_checked.
#
# PIL marker convention: events containing "### Planning Intelligence Log"
# heading in description or comment body are treated as evidence of scrutiny.
# This matches the heading written by /dso:brainstorm (brainstorm SKILL.md).

# ── Test 8: _ticket_has_pil — finds PIL in CREATE description ─────────────────
echo ""
echo "--- test_ticket_has_pil_finds_pil_in_create_description ---"

test_ticket_has_pil_finds_pil_in_create_description() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    # Create an epic with PIL marker in the description
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "PIL epic" \
        --description "### Planning Intelligence Log

scrutiny complete" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_ticket_has_pil_finds_pil_in_create_description: could not create ticket" >&2; return; }

    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _ticket_has_pil "$ticket_id") 2>/dev/null || _exit=$?

    assert_eq "test_ticket_has_pil_finds_pil_in_create_description: exit 0 when PIL in description" "0" "$_exit"
    assert_pass_if_clean "test_ticket_has_pil_finds_pil_in_create_description"
}

test_ticket_has_pil_finds_pil_in_create_description

# ── Test 9: _ticket_has_pil — finds PIL in EDIT fields.description ────────────
echo ""
echo "--- test_ticket_has_pil_finds_pil_in_edit_fields_description ---"

test_ticket_has_pil_finds_pil_in_edit_fields_description() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "Edit PIL epic" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_ticket_has_pil_finds_pil_in_edit_fields_description: could not create ticket" >&2; return; }

    # Edit the ticket to add PIL marker in description
    (cd "$repo" && bash "$TICKET_SCRIPT" edit "$ticket_id" \
        --description "### Planning Intelligence Log

added via edit" 2>/dev/null) || {
        (( ++FAIL ))
        echo "FAIL: test_ticket_has_pil_finds_pil_in_edit_fields_description: ticket edit setup failed" >&2
        return
    }

    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _ticket_has_pil "$ticket_id") 2>/dev/null || _exit=$?

    assert_eq "test_ticket_has_pil_finds_pil_in_edit_fields_description: exit 0 when PIL in edit description" "0" "$_exit"
    assert_pass_if_clean "test_ticket_has_pil_finds_pil_in_edit_fields_description"
}

test_ticket_has_pil_finds_pil_in_edit_fields_description

# ── Test 10: _ticket_has_pil — finds PIL in comment body ─────────────────────
echo ""
echo "--- test_ticket_has_pil_finds_pil_in_comment_body ---"

test_ticket_has_pil_finds_pil_in_comment_body() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "Comment PIL epic" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_ticket_has_pil_finds_pil_in_comment_body: could not create ticket" >&2; return; }

    (cd "$repo" && bash "$TICKET_SCRIPT" comment "$ticket_id" \
        "### Planning Intelligence Log

brainstorm complete, see attached notes" 2>/dev/null) || {
        (( ++FAIL ))
        echo "FAIL: test_ticket_has_pil_finds_pil_in_comment_body: ticket comment setup failed" >&2
        return
    }

    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _ticket_has_pil "$ticket_id") 2>/dev/null || _exit=$?

    assert_eq "test_ticket_has_pil_finds_pil_in_comment_body: exit 0 when PIL in comment" "0" "$_exit"
    assert_pass_if_clean "test_ticket_has_pil_finds_pil_in_comment_body"
}

test_ticket_has_pil_finds_pil_in_comment_body

# ── Test 11: _ticket_has_pil — returns exit 1 when PIL absent ────────────────
# Uses assert_eq "1" to fail RED (function missing → exit 127) but pass GREEN
# (function implemented → exit 1 for absent PIL).
echo ""
echo "--- test_ticket_has_pil_returns_nonzero_when_absent ---"

test_ticket_has_pil_returns_nonzero_when_absent() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "No PIL epic" \
        --description "Just a regular description" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_ticket_has_pil_returns_nonzero_when_absent: could not create ticket" >&2; return; }

    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _ticket_has_pil "$ticket_id") 2>/dev/null || _exit=$?

    assert_eq "test_ticket_has_pil_returns_nonzero_when_absent: exit 1 when PIL absent" "1" "$_exit"
    assert_pass_if_clean "test_ticket_has_pil_returns_nonzero_when_absent"
}

test_ticket_has_pil_returns_nonzero_when_absent

# ── Test 12: _tag_add_checked — bypasses PIL check for non-brainstorm tags ────
echo ""
echo "--- test_tag_add_checked_bypasses_check_for_non_brainstorm_tags ---"

test_tag_add_checked_bypasses_check_for_non_brainstorm_tags() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Non-brainstorm task" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_tag_add_checked_bypasses_check_for_non_brainstorm_tags: could not create ticket" >&2; return; }

    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _tag_add_checked "$ticket_id" "priority:high") 2>/dev/null || _exit=$?

    assert_eq "test_tag_add_checked_bypasses_check_for_non_brainstorm_tags: exit 0 for non-brainstorm tag" "0" "$_exit"
    assert_pass_if_clean "test_tag_add_checked_bypasses_check_for_non_brainstorm_tags"
}

test_tag_add_checked_bypasses_check_for_non_brainstorm_tags

# ── Test 13: _tag_add_checked — rejects brainstorm:complete without PIL ───────
# Uses assert_eq "1" to fail RED (function missing → exit 127) but pass GREEN
# (function implemented → exit 1 for rejected tag).
echo ""
echo "--- test_tag_add_checked_rejects_brainstorm_complete_without_pil ---"

test_tag_add_checked_rejects_brainstorm_complete_without_pil() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "No PIL epic" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_tag_add_checked_rejects_brainstorm_complete_without_pil: could not create ticket" >&2; return; }

    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _tag_add_checked "$ticket_id" "brainstorm:complete") 2>/dev/null || _exit=$?

    assert_eq "test_tag_add_checked_rejects_brainstorm_complete_without_pil: exit 1 when PIL absent" "1" "$_exit"
    assert_pass_if_clean "test_tag_add_checked_rejects_brainstorm_complete_without_pil"
}

test_tag_add_checked_rejects_brainstorm_complete_without_pil

# ── Test 14: _tag_add_checked — allows brainstorm:complete with PIL ───────────
echo ""
echo "--- test_tag_add_checked_allows_brainstorm_complete_with_pil ---"

test_tag_add_checked_allows_brainstorm_complete_with_pil() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "PIL present epic" \
        --description "### Planning Intelligence Log

brainstorm done" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_tag_add_checked_allows_brainstorm_complete_with_pil: could not create ticket" >&2; return; }

    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _tag_add_checked "$ticket_id" "brainstorm:complete") 2>/dev/null || _exit=$?

    assert_eq "test_tag_add_checked_allows_brainstorm_complete_with_pil: exit 0 when PIL present" "0" "$_exit"
    assert_pass_if_clean "test_tag_add_checked_allows_brainstorm_complete_with_pil"
}

test_tag_add_checked_allows_brainstorm_complete_with_pil

# ── Test 15: Round-trip via _tag_add_checked lib call (fails RED until Task 2) ──
echo ""
echo "--- test_ticket_tag_pil_round_trip ---"

test_ticket_tag_pil_round_trip() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "Round-trip PIL epic" \
        --description "### Planning Intelligence Log

all checks done" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_ticket_tag_pil_round_trip: could not create ticket" >&2; return; }

    # Call _tag_add_checked directly (fails RED until lib implements it)
    local _exit=0
    (cd "$repo" && source "$TICKET_LIB" && _tag_add_checked "$ticket_id" "brainstorm:complete") 2>/dev/null || _exit=$?

    assert_eq "test_ticket_tag_pil_round_trip: exit 0 when PIL present" "0" "$_exit"

    local tags
    tags=$(_get_tags "$repo" "$ticket_id")
    assert_contains "test_ticket_tag_pil_round_trip: brainstorm:complete in tags" "brainstorm:complete" "$tags"

    assert_pass_if_clean "test_ticket_tag_pil_round_trip"
}

test_ticket_tag_pil_round_trip

# ── Test 16: CLI rejects brainstorm:complete without PIL ─────────────────────
echo ""
echo "--- test_ticket_tag_cli_rejects_brainstorm_complete_without_pil ---"

test_ticket_tag_cli_rejects_brainstorm_complete_without_pil() {
    _snapshot_fail
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "No PIL epic for CLI" 2>/dev/null | tr -d '[:space:]')

    [[ -z "$ticket_id" ]] && { (( ++FAIL )); echo "FAIL: test_ticket_tag_cli_rejects_brainstorm_complete_without_pil: could not create ticket" >&2; return; }

    local _exit=0
    local _stderr
    _stderr=$(cd "$repo" && bash "$TICKET_SCRIPT" tag "$ticket_id" "brainstorm:complete" 2>&1 >/dev/null) || _exit=$?

    assert_eq "test_ticket_tag_cli_rejects_brainstorm_complete_without_pil: exit 1 when PIL absent" "1" "$_exit"
    assert_contains "test_ticket_tag_cli_rejects_brainstorm_complete_without_pil: stderr mentions Planning Intelligence Log" \
        "Planning Intelligence Log" "$_stderr"
    assert_contains "test_ticket_tag_cli_rejects_brainstorm_complete_without_pil: stderr mentions /dso:brainstorm" \
        "/dso:brainstorm" "$_stderr"
    assert_pass_if_clean "test_ticket_tag_cli_rejects_brainstorm_complete_without_pil"
}

test_ticket_tag_cli_rejects_brainstorm_complete_without_pil

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
