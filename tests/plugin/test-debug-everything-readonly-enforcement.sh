#!/usr/bin/env bash
# tests/plugin/test-debug-everything-readonly-enforcement.sh
# Regression test: all debug-everything validation/diagnostic prompt files must contain a
# READ-ONLY ENFORCEMENT section with hard-stop framing that names prohibited tools explicitly.
#
# Bug: dso-gg0v — debug-everything validation sub-agent prompts use soft "Do NOT fix"
# language instead of the hard-stop READ-ONLY ENFORCEMENT section pattern fixed in w20-w7pm.
#
# This test verifies:
#   A. All 5 prompt files contain a "READ-ONLY ENFORCEMENT" section header
#   B. Each prompt file explicitly names prohibited tools (Edit, Write)
#   C. Each prompt file explicitly names prohibited Bash commands (git commit, git push, ticket transition)
#   D. The enforcement uses hard-stop framing (STOP/TERMINATE/HALT or "must not")
#
# Manual run:
#   bash tests/plugin/test-debug-everything-readonly-enforcement.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMPTS_DIR="$PLUGIN_ROOT/plugins/dso/skills/debug-everything/prompts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== debug-everything read-only enforcement regression test ==="
echo ""

# All 5 prompt files that must contain enforcement
PROMPT_FILES=(
    "$PROMPTS_DIR/full-validation.md"
    "$PROMPTS_DIR/post-batch-validation.md"
    "$PROMPTS_DIR/tier-transition-validation.md"
    "$PROMPTS_DIR/critic-review.md"
    "$PROMPTS_DIR/diagnostic-and-cluster.md"
)

# file_contains_pattern FILE PATTERN
# Returns "true" if FILE contains a line matching PATTERN (case-insensitive), "false" otherwise.
file_contains_pattern() {
    local file="$1"
    local pattern="$2"
    if grep -qiE "$pattern" "$file" 2>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

# ---------------------------------------------------------------------------
# Prerequisite: all prompt files must exist
# ---------------------------------------------------------------------------
echo "--- prerequisite: all prompt files exist ---"

for prompt_file in "${PROMPT_FILES[@]}"; do
    filename="$(basename "$prompt_file")"
    assert_eq "$filename exists" "true" \
        "$(test -f "$prompt_file" && echo true || echo false)"
done

# ---------------------------------------------------------------------------
# Test A: READ-ONLY ENFORCEMENT section header present in all prompt files
# ---------------------------------------------------------------------------
echo ""
echo "--- Test A: READ-ONLY ENFORCEMENT section header in all prompt files ---"

for prompt_file in "${PROMPT_FILES[@]}"; do
    filename="$(basename "$prompt_file")"
    assert_eq "$filename contains READ-ONLY ENFORCEMENT header" "true" \
        "$(file_contains_pattern "$prompt_file" "read-only enforcement")"
done

# ---------------------------------------------------------------------------
# Test B: Prohibited tools explicitly named (Edit and Write)
# ---------------------------------------------------------------------------
echo ""
echo "--- Test B: prohibited tools explicitly named (Edit, Write) in all prompt files ---"

for prompt_file in "${PROMPT_FILES[@]}"; do
    filename="$(basename "$prompt_file")"
    assert_eq "$filename explicitly names 'Edit' tool as prohibited" "true" \
        "$(file_contains_pattern "$prompt_file" "\bEdit\b")"
    assert_eq "$filename explicitly names 'Write' tool as prohibited" "true" \
        "$(file_contains_pattern "$prompt_file" "\bWrite\b")"
done

# ---------------------------------------------------------------------------
# Test C: Prohibited Bash commands explicitly named
# ---------------------------------------------------------------------------
echo ""
echo "--- Test C: prohibited Bash commands explicitly named in all prompt files ---"

for prompt_file in "${PROMPT_FILES[@]}"; do
    filename="$(basename "$prompt_file")"
    assert_eq "$filename names 'git commit' as prohibited" "true" \
        "$(file_contains_pattern "$prompt_file" "git commit")"
    assert_eq "$filename names 'git push' as prohibited" "true" \
        "$(file_contains_pattern "$prompt_file" "git push")"
    assert_eq "$filename names 'ticket transition' as prohibited" "true" \
        "$(file_contains_pattern "$prompt_file" "ticket transition")"
done

# ---------------------------------------------------------------------------
# Test D: Hard-stop framing (STOP, TERMINATE, HALT, or "must not")
# ---------------------------------------------------------------------------
echo ""
echo "--- Test D: hard-stop framing in all prompt files ---"

for prompt_file in "${PROMPT_FILES[@]}"; do
    filename="$(basename "$prompt_file")"
    assert_eq "$filename uses hard-stop framing (STOP/TERMINATE/HALT/must not)" "true" \
        "$(file_contains_pattern "$prompt_file" "\bSTOP\b|\bTERMINATE\b|\bHALT\b|must not|MUST NOT")"
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
