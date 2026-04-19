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

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
