#!/usr/bin/env bash
# tests/scripts/test-design-approve.sh
# Tests: verify design-approve.sh approval command behavior.
#
# Tests exercise observable effects of design-approve.sh:
#   exit codes, stderr error messages, and ticket tag state changes.
#
# Test scenarios:
#   DA-APPROVE-1: Happy path — PNG exists, tag swapped to design:approved
#   DA-APPROVE-2: Missing PNG — exit 1, error message
#   DA-APPROVE-3: Empty (0-byte) PNG — exit 1, error message
#   DA-APPROVE-4: Tag preservation — other tags kept after approval
#   DA-APPROVE-5: No awaiting tag — exit 1, appropriate error
#
# Usage: bash tests/scripts/test-design-approve.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
APPROVE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/design-approve.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-design-approve.sh ==="

# ── Pre-execution guard: verify ticket tag/untag dispatcher routing ────────────
# design-approve.sh uses `ticket tag` and `ticket untag` subcommands.
# If the dispatcher doesn't route them yet, skip the suite.
_TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
if ! grep -q "tag)" "$_TICKET_SCRIPT" 2>/dev/null; then
    echo "SKIP: ticket tag dispatcher not present in $_TICKET_SCRIPT — skipping test suite" >&2
    exit 0
fi

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Helper: create an isolated test workspace ─────────────────────────────────
# Sets up:
#   - $tmpdir/designs/<story_id>/   (designs directory for PNG placement)
#   - $tmpdir/ticket                (stub ticket CLI that records calls)
#   - $tmpdir/ticket.log            (log of all ticket CLI invocations)
#   - $tmpdir/tag-calls.txt         (captured args from `ticket tag` calls)
#   - $tmpdir/untag-calls.txt       (captured args from `ticket untag` calls)
#
# The stub ticket CLI handles:
#   show <id>          → returns JSON with configurable tags (via fixture_tags)
#   tag <id> <tag>     → records "<id> <tag>" to tag-calls.txt; exits 0
#   untag <id> <tag>   → records "<id> <tag>" to untag-calls.txt; exits 0
#   edit <id> --tags=VALUE → records VALUE to tags-written.txt (legacy path); exits 0
#   *                  → exits 0 silently
_setup_workspace() {
    local story_id="$1"
    local fixture_tags="${2:-}"   # JSON array string e.g. '["design:awaiting_import"]'

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")

    mkdir -p "$tmpdir/designs/$story_id"

    # Write the stub ticket CLI
    cat > "$tmpdir/ticket" << STUB
#!/usr/bin/env bash
set -uo pipefail
subcmd="\${1:-}"; shift || true

# Log every invocation
echo "\$subcmd \$*" >> "${tmpdir}/ticket.log"

case "\$subcmd" in
    show)
        story_id="\${1:-}"
        echo '{"ticket_id":"'"$story_id"'","ticket_type":"story","status":"open","title":"Test story","priority":2,"tags":${fixture_tags:-[]}}'
        ;;
    tag)
        # Record: <ticket_id> <tag_name>
        echo "\${1:-} \${2:-}" >> "${tmpdir}/tag-calls.txt"
        ;;
    untag)
        # Record: <ticket_id> <tag_name>
        echo "\${1:-} \${2:-}" >> "${tmpdir}/untag-calls.txt"
        ;;
    edit)
        # Legacy path: parse --tags=VALUE from remaining args
        ticket_id="\${1:-}"; shift || true
        for arg in "\$@"; do
            case "\$arg" in
                --tags=*)
                    echo "\${arg#--tags=}" > "${tmpdir}/tags-written.txt"
                    ;;
            esac
        done
        ;;
    *)
        ;;
esac
exit 0
STUB
    chmod +x "$tmpdir/ticket"

    echo "$tmpdir"
}

# ── Test DA-APPROVE-1: Happy path — PNG exists, tag swapped ──────────────────
# Given: story has design:awaiting_import tag, designs/<id>/figma-revision.png exists (non-empty)
# When: design-approve.sh <story_id> runs
# Then: exit 0, `ticket tag` called with design:approved, `ticket untag` called with design:awaiting_import
echo ""
echo "Test DA-APPROVE-1: happy path — PNG exists, tag swapped to design:approved"

test_da_approve_1_happy_path() {
    local story_id="test-story-1"
    local tmpdir
    tmpdir=$(_setup_workspace "$story_id" '["design:awaiting_import"]')

    # Create a non-empty PNG fixture
    printf '\x89PNG\r\n\x1a\n' > "$tmpdir/designs/$story_id/figma-revision.png"

    local _exit=0
    TICKET_CMD="$tmpdir/ticket" \
    PROJECT_ROOT="$tmpdir" \
        bash "$APPROVE_SCRIPT" "$story_id" >/dev/null 2>&1 || _exit=$?

    # Assert exit 0
    assert_eq "DA-APPROVE-1: exit code" "0" "$_exit"

    # Assert `ticket tag` was called with design:approved
    local tag_calls=""
    tag_calls=$(cat "$tmpdir/tag-calls.txt" 2>/dev/null || echo "")
    assert_contains "DA-APPROVE-1: design:approved in tag calls" "design:approved" "$tag_calls"

    # Assert `ticket untag` was called with design:awaiting_import
    local untag_calls=""
    untag_calls=$(cat "$tmpdir/untag-calls.txt" 2>/dev/null || echo "")
    if [[ -n "$untag_calls" ]] && [[ "$untag_calls" == *"design:awaiting_import"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: DA-APPROVE-1: ticket untag should have been called with design:awaiting_import\n  untag-calls: '%s'\n" "$untag_calls" >&2
    fi
}
test_da_approve_1_happy_path

# ── Test DA-APPROVE-2: Missing PNG — exit 1, error message ───────────────────
# Given: story has design:awaiting_import tag, designs/<id>/figma-revision.png does NOT exist
# When: design-approve.sh <story_id> runs
# Then: exit 1, stderr contains error message mentioning the missing file
echo ""
echo "Test DA-APPROVE-2: missing PNG — exit 1 with error message"

test_da_approve_2_missing_png() {
    local story_id="test-story-2"
    local tmpdir
    tmpdir=$(_setup_workspace "$story_id" '["design:awaiting_import"]')

    # No PNG created — designs/<id>/figma-revision.png is absent

    local _exit=0
    local _stderr
    _stderr=$(TICKET_CMD="$tmpdir/ticket" \
              PROJECT_ROOT="$tmpdir" \
              bash "$APPROVE_SCRIPT" "$story_id" 2>&1 >/dev/null) || _exit=$?

    assert_eq "DA-APPROVE-2: exit code on missing PNG" "1" "$_exit"
    assert_contains "DA-APPROVE-2: error message mentions figma-revision.png" "figma-revision.png" "$_stderr"
}
test_da_approve_2_missing_png

# ── Test DA-APPROVE-3: Empty (0-byte) PNG — exit 1, error message ────────────
# Given: story has design:awaiting_import tag, designs/<id>/figma-revision.png is 0 bytes
# When: design-approve.sh <story_id> runs
# Then: exit 1, stderr contains error message indicating empty/invalid file
echo ""
echo "Test DA-APPROVE-3: empty PNG — exit 1 with error message"

test_da_approve_3_empty_png() {
    local story_id="test-story-3"
    local tmpdir
    tmpdir=$(_setup_workspace "$story_id" '["design:awaiting_import"]')

    # Create a 0-byte file
    touch "$tmpdir/designs/$story_id/figma-revision.png"

    local _exit=0
    local _stderr
    _stderr=$(TICKET_CMD="$tmpdir/ticket" \
              PROJECT_ROOT="$tmpdir" \
              bash "$APPROVE_SCRIPT" "$story_id" 2>&1 >/dev/null) || _exit=$?

    assert_eq "DA-APPROVE-3: exit code on empty PNG" "1" "$_exit"
    # Error message should indicate the file is empty or invalid
    if [[ "$_stderr" == *"empty"* ]] || [[ "$_stderr" == *"invalid"* ]] || [[ "$_stderr" == *"figma-revision.png"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: DA-APPROVE-3: stderr should mention empty/invalid PNG\n  stderr: %s\n" "$_stderr" >&2
    fi
}
test_da_approve_3_empty_png

# ── Test DA-APPROVE-4: Tag preservation — other tags kept after approval ──────
# Given: story has design:awaiting_import AND priority:high tags
# When: design-approve.sh <story_id> runs with a valid PNG
# Then: exit 0, `ticket tag` called with design:approved,
#       `ticket untag` called with design:awaiting_import,
#       no `ticket edit` invocation for tag modification
echo ""
echo "Test DA-APPROVE-4: tag preservation — other tags kept after approval"

test_da_approve_4_tag_preservation() {
    local story_id="test-story-4"
    local tmpdir
    tmpdir=$(_setup_workspace "$story_id" '["design:awaiting_import","priority:high","sprint:current"]')

    # Create a non-empty PNG fixture
    printf '\x89PNG\r\n\x1a\n' > "$tmpdir/designs/$story_id/figma-revision.png"

    local _exit=0
    TICKET_CMD="$tmpdir/ticket" \
    PROJECT_ROOT="$tmpdir" \
        bash "$APPROVE_SCRIPT" "$story_id" >/dev/null 2>&1 || _exit=$?

    assert_eq "DA-APPROVE-4: exit code" "0" "$_exit"

    # Assert `ticket tag` was called with design:approved
    local tag_calls=""
    tag_calls=$(cat "$tmpdir/tag-calls.txt" 2>/dev/null || echo "")
    assert_contains "DA-APPROVE-4: design:approved in tag calls" "design:approved" "$tag_calls"

    # Assert `ticket untag` was called with design:awaiting_import
    local untag_calls=""
    untag_calls=$(cat "$tmpdir/untag-calls.txt" 2>/dev/null || echo "")
    if [[ -n "$untag_calls" ]] && [[ "$untag_calls" == *"design:awaiting_import"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: DA-APPROVE-4: ticket untag should have been called with design:awaiting_import\n  untag-calls: '%s'\n" "$untag_calls" >&2
    fi

    # Assert no `ticket edit` invocation for tag modification (no --tags= in ticket.log)
    local ticket_log=""
    ticket_log=$(cat "$tmpdir/ticket.log" 2>/dev/null || echo "")
    if [[ "$ticket_log" != *"--tags="* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: DA-APPROVE-4: ticket edit --tags= should not be called; use ticket tag/untag instead\n  ticket.log: '%s'\n" "$ticket_log" >&2
    fi
}
test_da_approve_4_tag_preservation

# ── Test DA-APPROVE-5: No awaiting tag — exit 1, appropriate error ────────────
# Given: story does NOT have design:awaiting_import tag
# When: design-approve.sh <story_id> runs
# Then: exit 1, stderr indicates story is not in awaiting_import state
echo ""
echo "Test DA-APPROVE-5: no awaiting tag — exit 1 with appropriate error"

test_da_approve_5_no_awaiting_tag() {
    local story_id="test-story-5"
    local tmpdir
    tmpdir=$(_setup_workspace "$story_id" '[]')

    # Create a non-empty PNG so file validation is not the cause of failure
    printf '\x89PNG\r\n\x1a\n' > "$tmpdir/designs/$story_id/figma-revision.png"

    local _exit=0
    local _stderr
    _stderr=$(TICKET_CMD="$tmpdir/ticket" \
              PROJECT_ROOT="$tmpdir" \
              bash "$APPROVE_SCRIPT" "$story_id" 2>&1 >/dev/null) || _exit=$?

    assert_eq "DA-APPROVE-5: exit code when awaiting tag absent" "1" "$_exit"
    # Error message should indicate the story is not in the awaiting state
    if [[ "$_stderr" == *"awaiting_import"* ]] || [[ "$_stderr" == *"design:awaiting"* ]] || [[ "$_stderr" == *"not awaiting"* ]] || [[ "$_stderr" == *"not in"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: DA-APPROVE-5: stderr should mention awaiting_import state\n  stderr: %s\n" "$_stderr" >&2
    fi
}
test_da_approve_5_no_awaiting_tag

print_summary
