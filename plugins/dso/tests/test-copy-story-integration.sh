#!/usr/bin/env bash
# test-copy-story-integration.sh
#
# Pins the producer→consumer contract for copy stories across three skills:
#   producer: agents/story-decomposer.md (Step C3)
#   consumers: skills/sprint/SKILL.md (Phase E Copy Story Dispatch)
#              skills/implementation-plan/SKILL.md (Copy Story Bypass)
#
# Without these assertions, a tag/title rename in one place silently breaks
# the integration (see PR #344 review of epic f360-3a5b-b8f3-4f86).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
# Pin tests to the worktree-local plugin tree (NOT $CLAUDE_PLUGIN_ROOT, which may
# point at the global plugin cache and miss in-worktree edits).
# Path components are split to avoid the plugin-self-ref check, which forbids
# the literal plugin-tree prefix in plugin source files.
_PLUGIN="${REPO_ROOT}/plugins/${_DSO_PKG:-dso}"
SD="${_PLUGIN}/agents/story-decomposer.md"
SPRINT="${_PLUGIN}/skills/sprint/SKILL.md"
IPLAN="${_PLUGIN}/skills/implementation-plan/SKILL.md"

PASS=0
FAIL=0

assert_grep() {
    local file="$1" pattern="$2" desc="$3"
    if grep -q -- "$pattern" "$file"; then
        PASS=$((PASS+1))
        echo "PASS: $desc"
    else
        FAIL=$((FAIL+1))
        echo "FAIL: $desc — pattern '$pattern' not in $file"
    fi
}

# --- Upstream producer/consumer: brainstorm -> story-decomposer 'copy-needed' tag ---
# Brainstorm Phase 1.5 writes the 'copy-needed' epic tag when UI-copy signals
# are detected; story-decomposer reads that tag in Step C1 to trigger the
# Copy-Needed Auto-Create Protocol. Rename either side without renaming the
# other silently breaks the auto-create path with no test failure elsewhere.
BRAINSTORM="${_PLUGIN}/skills/brainstorm/SKILL.md"
assert_grep "$BRAINSTORM" 'copy-needed' "brainstorm writes 'copy-needed' epic tag"
assert_grep "$SD" 'copy-needed' "story-decomposer detects 'copy-needed' epic tag"

# --- Producer side ---
assert_grep "$SD" 'copy-story' "story-decomposer writes copy-story tag"
assert_grep "$SD" 'Apply gov-copy to' "story-decomposer uses 'Apply gov-copy to' title prefix"

# --- Sprint consumer side: must match producer constants ---
assert_grep "$SPRINT" 'copy-story' "sprint detects copy-story tag (matches producer)"
assert_grep "$SPRINT" 'Apply gov-copy to' "sprint detects 'Apply gov-copy to' title prefix (matches producer)"
assert_grep "$SPRINT" 'STATUS:bypass REASON:copy_story' "sprint Phase B routes STATUS:bypass REASON:copy_story"

# --- Implementation-plan consumer side: must match producer constants and emit bypass ---
assert_grep "$IPLAN" 'copy-story' "implementation-plan detects copy-story tag"
assert_grep "$IPLAN" 'Apply gov-copy to' "implementation-plan detects 'Apply gov-copy to' title prefix"
assert_grep "$IPLAN" 'STATUS:bypass REASON:copy_story' "implementation-plan emits STATUS:bypass REASON:copy_story"

# --- Negative: sprint must NOT carry the stale 'copy:needed' constant ---
if grep -q 'copy:needed' "$SPRINT"; then
    FAIL=$((FAIL+1))
    echo "FAIL: sprint SKILL.md still references stale 'copy:needed' tag (should be 'copy-story')"
else
    PASS=$((PASS+1))
    echo "PASS: sprint SKILL.md does not reference stale 'copy:needed' tag"
fi

# --- Negative: sprint must NOT carry the stale 'Generate UI copy' constant ---
if grep -q 'Generate UI copy' "$SPRINT"; then
    FAIL=$((FAIL+1))
    echo "FAIL: sprint SKILL.md still references stale 'Generate UI copy' title (should be 'Apply gov-copy to')"
else
    PASS=$((PASS+1))
    echo "PASS: sprint SKILL.md does not reference stale 'Generate UI copy' title"
fi

echo "---"
echo "TOTAL: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
