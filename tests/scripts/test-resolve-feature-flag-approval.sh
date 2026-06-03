#!/usr/bin/env bash
# tests/scripts/test-resolve-feature-flag-approval.sh
# Behavioral suite for plugins/dso/scripts/implementation-plan/resolve-feature-flag-approval.sh
#
# The helper implements the two-hop tag-lookup contract:
#   1. Check the story for rollout:feature-flags-approved → approved, source=story
#   2. Check the parent epic for the same tag → approved, source=parent
#   3. Neither has the tag → prohibited, non-empty reason, source=none
#   4. Story has no parent (orphan) → prohibited, non-empty reason
#   5. Ticket-show lookup fails (non-zero / unparseable) → safe-default prohibited, non-empty reason
#
# Stub strategy: each test creates a sandbox tmpdir, writes a .claude/scripts/dso shim,
# then cd into the sandbox and runs the helper. The helper calls the shim for
# `ticket show <id>`. The helper does NOT yet exist; this suite is therefore RED.
#
# Per behavioral-testing-standard.md Rule 1: each test invokes the real
# script and asserts on its observable output (stdout JSON) and exit code.
#
# Usage: bash tests/scripts/test-resolve-feature-flag-approval.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/plugins/dso/scripts/implementation-plan/resolve-feature-flag-approval.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-resolve-feature-flag-approval.sh ==="
echo ""

# ─── Helpers ──────────────────────────────────────────────────────────────────

# _make_sandbox — creates an isolated tmpdir with a configurable dso stub.
# Usage: _sandbox=$(_make_sandbox)
# The caller writes the stub to "$_sandbox/.claude/scripts/dso" (already chmod +x).
_make_sandbox() {
    local _dir
    _dir=$(mktemp -d "${TMPDIR:-/tmp}/rff-sandbox.XXXXXX")
    mkdir -p "$_dir/.claude/scripts"
    echo "$_dir"
}

# _run_helper sandbox story_id → stdout from helper, exit code in $_helper_rc
_run_helper() {
    local _sb="$1" _sid="$2"
    set +e
    _helper_out=$(cd "$_sb" && bash "$HELPER" "$_sid" 2>/dev/null)
    _helper_rc=$?
    set -e
}

# JSON story fixture with rollout:feature-flags-approved tag and a parent_id
_story_with_tag() {
    cat <<'JSON'
{
  "ticket_id": "story-aaa1",
  "ticket_type": "story",
  "title": "Story with flag tag",
  "status": "in_progress",
  "parent_id": "epic-bbb2",
  "tags": ["rollout:feature-flags-approved"]
}
JSON
}

# JSON story fixture WITHOUT the tag but WITH a parent
_story_without_tag() {
    cat <<'JSON'
{
  "ticket_id": "story-aaa2",
  "ticket_type": "story",
  "title": "Story without flag tag",
  "status": "in_progress",
  "parent_id": "epic-bbb2",
  "tags": []
}
JSON
}

# JSON story fixture with no parent (orphan)
_story_no_parent() {
    cat <<'JSON'
{
  "ticket_id": "story-aaa3",
  "ticket_type": "story",
  "title": "Orphan story (no parent)",
  "status": "in_progress",
  "parent_id": null,
  "tags": []
}
JSON
}

# JSON epic fixture WITH the tag
_epic_with_tag() {
    cat <<'JSON'
{
  "ticket_id": "epic-bbb2",
  "ticket_type": "epic",
  "title": "Epic with flag tag",
  "status": "in_progress",
  "parent_id": null,
  "tags": ["rollout:feature-flags-approved"]
}
JSON
}

# JSON epic fixture WITHOUT the tag
_epic_without_tag() {
    cat <<'JSON'
{
  "ticket_id": "epic-bbb2",
  "ticket_type": "epic",
  "title": "Epic without flag tag",
  "status": "in_progress",
  "parent_id": null,
  "tags": []
}
JSON
}

# ─── Test 1: tag on story only → approved, source=story ──────────────────────

# Given: story has rollout:feature-flags-approved; epic does NOT
# When: resolve-feature-flag-approval.sh story-aaa1 is called
# Then: prints JSON with feature-flags=approved and source=story; exits 0
test_story_tag_yields_approved_with_source_story() {
    local _sb
    _sb=$(_make_sandbox)

    cat > "$_sb/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "story-aaa1" ]]; then
    cat <<'JSON'
$(_story_with_tag)
JSON
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "epic-bbb2" ]]; then
    cat <<'JSON'
$(_epic_without_tag)
JSON
    exit 0
fi
exit 1
STUB
    chmod +x "$_sb/.claude/scripts/dso"

    _run_helper "$_sb" "story-aaa1"
    rm -rf "$_sb"

    assert_eq "test_story_tag_yields_approved_with_source_story: helper exits 0" \
              "0" "$_helper_rc"

    local _verdict
    _verdict=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('feature-flags','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_story_tag_yields_approved_with_source_story: verdict is approved" \
              "approved" "$_verdict"

    local _source
    _source=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('source','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_story_tag_yields_approved_with_source_story: source is story" \
              "story" "$_source"
}

# ─── Test 2: tag on parent epic only → approved, source=parent ───────────────

# Given: story has NO rollout:feature-flags-approved; epic DOES
# When: resolve-feature-flag-approval.sh story-aaa2 is called
# Then: prints JSON with feature-flags=approved and source=parent; exits 0
test_parent_tag_yields_approved_with_source_parent() {
    local _sb
    _sb=$(_make_sandbox)

    cat > "$_sb/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "story-aaa2" ]]; then
    cat <<'JSON'
$(_story_without_tag)
JSON
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "epic-bbb2" ]]; then
    cat <<'JSON'
$(_epic_with_tag)
JSON
    exit 0
fi
exit 1
STUB
    chmod +x "$_sb/.claude/scripts/dso"

    _run_helper "$_sb" "story-aaa2"
    rm -rf "$_sb"

    assert_eq "test_parent_tag_yields_approved_with_source_parent: helper exits 0" \
              "0" "$_helper_rc"

    local _verdict
    _verdict=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('feature-flags','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_parent_tag_yields_approved_with_source_parent: verdict is approved" \
              "approved" "$_verdict"

    local _source
    _source=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('source','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_parent_tag_yields_approved_with_source_parent: source is parent" \
              "parent" "$_source"
}

# ─── Test 3: tag on both → approved, source=story (story wins) ───────────────

# Given: BOTH story and epic have rollout:feature-flags-approved
# When: resolve-feature-flag-approval.sh story-aaa1 is called
# Then: prints JSON with feature-flags=approved; exits 0
test_tag_on_both_yields_approved() {
    local _sb
    _sb=$(_make_sandbox)

    cat > "$_sb/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "story-aaa1" ]]; then
    cat <<'JSON'
$(_story_with_tag)
JSON
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "epic-bbb2" ]]; then
    cat <<'JSON'
$(_epic_with_tag)
JSON
    exit 0
fi
exit 1
STUB
    chmod +x "$_sb/.claude/scripts/dso"

    _run_helper "$_sb" "story-aaa1"
    rm -rf "$_sb"

    assert_eq "test_tag_on_both_yields_approved: helper exits 0" \
              "0" "$_helper_rc"

    local _verdict
    _verdict=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('feature-flags','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_tag_on_both_yields_approved: verdict is approved" \
              "approved" "$_verdict"
}

# ─── Test 4: tag on neither → prohibited, source=none, non-empty reason ──────

# Given: story has no tag, epic has no tag
# When: resolve-feature-flag-approval.sh story-aaa2 is called
# Then: prints JSON with feature-flags=prohibited, source=none, and a non-empty reason; exits 0
test_no_tag_yields_prohibited_with_reason() {
    local _sb
    _sb=$(_make_sandbox)

    cat > "$_sb/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "story-aaa2" ]]; then
    cat <<'JSON'
$(_story_without_tag)
JSON
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "epic-bbb2" ]]; then
    cat <<'JSON'
$(_epic_without_tag)
JSON
    exit 0
fi
exit 1
STUB
    chmod +x "$_sb/.claude/scripts/dso"

    _run_helper "$_sb" "story-aaa2"
    rm -rf "$_sb"

    assert_eq "test_no_tag_yields_prohibited_with_reason: helper exits 0" \
              "0" "$_helper_rc"

    local _verdict
    _verdict=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('feature-flags','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_no_tag_yields_prohibited_with_reason: verdict is prohibited" \
              "prohibited" "$_verdict"

    local _source
    _source=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('source','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_no_tag_yields_prohibited_with_reason: source is none" \
              "none" "$_source"

    local _reason
    _reason=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('reason',''))" 2>/dev/null || echo "")
    assert_ne "test_no_tag_yields_prohibited_with_reason: reason is non-empty" \
              "" "$_reason"
}

# ─── Test 5: no parent (orphan story) → safe-default prohibited, non-empty reason, exits 0 ──

# Given: story has no parent_id and no tag
# When: resolve-feature-flag-approval.sh story-aaa3 is called
# Then: safe-default → feature-flags=prohibited, non-empty reason, exits 0
#       (helper must NOT exit non-zero; non-zero would break Step 1 for ordinary stories)
test_no_parent_yields_safe_default_prohibited_exits_zero() {
    local _sb
    _sb=$(_make_sandbox)

    cat > "$_sb/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ticket" && "\$2" == "show" && "\$3" == "story-aaa3" ]]; then
    cat <<'JSON'
$(_story_no_parent)
JSON
    exit 0
fi
# If helper tries to look up a null/empty parent, fail
exit 1
STUB
    chmod +x "$_sb/.claude/scripts/dso"

    _run_helper "$_sb" "story-aaa3"
    rm -rf "$_sb"

    assert_eq "test_no_parent_yields_safe_default_prohibited_exits_zero: helper exits 0" \
              "0" "$_helper_rc"

    local _verdict
    _verdict=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('feature-flags','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_no_parent_yields_safe_default_prohibited_exits_zero: verdict is prohibited" \
              "prohibited" "$_verdict"

    local _reason
    _reason=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('reason',''))" 2>/dev/null || echo "")
    assert_ne "test_no_parent_yields_safe_default_prohibited_exits_zero: reason is non-empty" \
              "" "$_reason"
}

# ─── Test 6: ticket-show lookup failure → safe-default prohibited, non-empty reason, exits 0 ──

# Given: ticket show for the story returns non-zero (simulating lookup failure)
# When: resolve-feature-flag-approval.sh story-aaa1 is called
# Then: safe-default → feature-flags=prohibited, non-empty reason, exits 0
#       (helper must NOT exit non-zero; lookup failures are normal for new tickets)
test_lookup_failure_yields_safe_default_prohibited_exits_zero() {
    local _sb
    _sb=$(_make_sandbox)

    cat > "$_sb/.claude/scripts/dso" <<'STUB'
#!/usr/bin/env bash
# All ticket show calls fail (simulate network/lookup failure)
if [[ "$1" == "ticket" && "$2" == "show" ]]; then
    echo "ERROR: ticket not found" >&2
    exit 1
fi
exit 1
STUB
    chmod +x "$_sb/.claude/scripts/dso"

    _run_helper "$_sb" "story-aaa1"
    rm -rf "$_sb"

    assert_eq "test_lookup_failure_yields_safe_default_prohibited_exits_zero: helper exits 0" \
              "0" "$_helper_rc"

    local _verdict
    _verdict=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('feature-flags','MISSING'))" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_lookup_failure_yields_safe_default_prohibited_exits_zero: verdict is prohibited" \
              "prohibited" "$_verdict"

    local _reason
    _reason=$(echo "$_helper_out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('reason',''))" 2>/dev/null || echo "")
    assert_ne "test_lookup_failure_yields_safe_default_prohibited_exits_zero: reason is non-empty" \
              "" "$_reason"
}

# ─── Run all tests ─────────────────────────────────────────────────────────────

test_story_tag_yields_approved_with_source_story
test_parent_tag_yields_approved_with_source_parent
test_tag_on_both_yields_approved
test_no_tag_yields_prohibited_with_reason
test_no_parent_yields_safe_default_prohibited_exits_zero
test_lookup_failure_yields_safe_default_prohibited_exits_zero

print_summary
