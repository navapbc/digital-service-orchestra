#!/usr/bin/env bash
# tests/scripts/test-no-v2-refs-in-claude-md.sh
# RED tests: assert no v2 ticket system references remain in CLAUDE.md.
#
# "v2 references" means:
#   - bare 'tk ' command invocations, including:
#       'the tk wrapper' — describes v2 tk binary as architecture component
#       'tk write commands' — instructs use of v2 tk command
#     Not caught: 'tk-sync-lib' (filename), 'the tk Session Close' (prose title)
#   - '.tickets/' paths (v2 worktree path; v3 uses '.tickets-tracker/')
#
# Tests:
#   test_no_tk_cmd_in_claude_md          — no bare tk command refs remain
#   test_no_v2_tickets_path_in_claude_md — no .tickets/ paths remain
#
# These tests are RED (fail) until task f14b-d217 updates CLAUDE.md to remove v2 refs.
#
# Usage: bash tests/scripts/test-no-v2-refs-in-claude-md.sh
# Returns: exit 1 in RED state (v2 refs present), exit 0 in GREEN state (v2 refs removed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-no-v2-refs-in-claude-md.sh ==="
echo ""

# ── test_no_tk_cmd_in_claude_md ───────────────────────────────────────────────
# CLAUDE.md must NOT contain bare 'tk ' command invocations (v2 pattern).
# Catches:
#   'the tk wrapper'   — v2 architecture description of the tk binary
#   '`tk`'             — inline code reference to the v2 tk command
# Excludes:
#   'tk-sync-lib'      — a v3 filename (not a command)
#   'tk Session Close' — prose title of an old checklist (not a command)
# RED: FAIL because CLAUDE.md still has 'the tk wrapper' and '`tk`' references.
_snapshot_fail

# Search for 'the tk wrapper' — explicit v2 architecture reference
tk_wrapper_hits=$(grep -n 'the tk wrapper' "$CLAUDE_MD" || true)

# Search for inline `tk` code spans that are v2 command references
# Exclude 'tk Session Close' (prose title) and 'tk-sync-lib' (filename)
tk_inline_hits=$(
    grep -n '`tk`' "$CLAUDE_MD" \
    | grep -v 'tk Session' \
    | grep -v 'tk-sync-lib' \
    || true
)

tk_hits="${tk_wrapper_hits}${tk_inline_hits}"

assert_eq "test_no_tk_cmd_in_claude_md: no bare tk command refs" "" "$tk_hits"

if [[ -n "$tk_hits" ]]; then
    echo "  Remaining bare tk command refs in CLAUDE.md:" >&2
    echo "$tk_hits" | head -10 >&2
fi

assert_pass_if_clean "test_no_tk_cmd_in_claude_md"
echo ""

# ── test_no_v2_tickets_path_in_claude_md ─────────────────────────────────────
# CLAUDE.md must NOT contain '.tickets/' paths (v2 worktree path).
# The v3 worktree path is '.tickets-tracker/'.
# '.tickets-tracker/' references are exempt (correct v3 path).
# RED: FAIL because CLAUDE.md still has '.tickets/.index.json' and '.tickets/' refs.
_snapshot_fail

tickets_hits=$(
    grep -n '\.tickets/' "$CLAUDE_MD" \
    | grep -v '\.tickets-tracker/' \
    || true
)

assert_eq "test_no_v2_tickets_path_in_claude_md: no .tickets/ paths" "" "$tickets_hits"

if [[ -n "$tickets_hits" ]]; then
    echo "  Remaining .tickets/ refs in CLAUDE.md:" >&2
    echo "$tickets_hits" | head -10 >&2
fi

assert_pass_if_clean "test_no_v2_tickets_path_in_claude_md"
echo ""

print_summary
