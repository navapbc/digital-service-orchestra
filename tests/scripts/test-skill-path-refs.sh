#!/usr/bin/env bash
# tests/scripts/test-skill-path-refs.sh
# Regression guard: ensures plugin skill files do not reference .claude/docs/
# files that actually exist within the plugin itself. Such references should
# use plugin-relative paths (e.g., docs/...) instead.
#
# Usage: bash tests/scripts/test-skill-path-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/plugins/dso}"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-skill-path-refs (plugin skill .claude/docs/ references) ==="

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT}"
SKILLS_DIR="$PLUGIN_DIR/skills"

# ── Test 1: Skills directory exists ──────────────────────────────────────────
echo "Test 1: Plugin skills directory exists"
if [[ -d "$SKILLS_DIR" ]]; then
    echo "  PASS: Skills directory exists"
    (( PASS++ ))
else
    echo "  FAIL: Skills directory not found at $SKILLS_DIR" >&2
    (( FAIL++ ))
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# ── Test 2: All .claude/docs/ references in plugin skills resolve correctly ──
# For each .claude/docs/<filename> reference found in plugin skill files:
#   - If the file exists at .claude/docs/<filename> in the host project, it's OK
#     (host-project-specific reference)
#   - If the file exists at docs/<filename> in the plugin,
#     the reference is WRONG — it should use a plugin-relative path
echo "Test 2: .claude/docs/ references do not point to plugin-internal files"
bad_refs=()
while IFS= read -r match; do
    # match format: filepath:linenum:line content
    file="${match%%:*}"
    rest="${match#*:}"
    linenum="${rest%%:*}"
    line="${rest#*:}"

    # Extract the filename from .claude/docs/<filename>
    # Handle patterns like .claude/docs/REVIEW-SCHEMA.md
    ref_file=$(echo "$line" | grep -oE '\.claude/docs/[A-Za-z0-9_-]+(\.[a-z]+)+' | head -1)
    if [[ -z "$ref_file" ]]; then
        continue
    fi
    basename_ref="${ref_file#.claude/docs/}"

    # Check if this file exists in the plugin docs directory
    if [[ -f "$PLUGIN_DIR/docs/$basename_ref" ]]; then
        # File exists in plugin — this reference should use plugin-relative path
        rel_file="${file#"$REPO_ROOT"/}"
        bad_refs+=("$rel_file:$linenum references $ref_file but file exists at docs/$basename_ref")
    fi
done < <(grep -rn '\.claude/docs/' "$SKILLS_DIR" --include='*.md' 2>/dev/null || true)

if [[ ${#bad_refs[@]} -eq 0 ]]; then
    echo "  PASS: All .claude/docs/ references in skills are host-project-specific"
    (( PASS++ ))
else
    echo "  FAIL: Found ${#bad_refs[@]} .claude/docs/ reference(s) pointing to plugin-internal files:" >&2
    for ref in "${bad_refs[@]}"; do
        echo "    - $ref" >&2
    done
    (( FAIL++ ))
fi

# ── Test 3: REVIEW-SCHEMA.md is referenced via plugin-relative path ──────────
echo "Test 3: review-protocol/SKILL.md references REVIEW-SCHEMA.md via plugin-relative path"
REVIEW_SKILL="$SKILLS_DIR/review-protocol/SKILL.md"
if [[ ! -f "$REVIEW_SKILL" ]]; then
    echo "  FAIL: review-protocol/SKILL.md not found" >&2
    (( FAIL++ ))
elif grep -qE 'docs/REVIEW-SCHEMA|CLAUDE_PLUGIN_ROOT.*REVIEW-SCHEMA' "$REVIEW_SKILL"; then
    echo "  PASS: REVIEW-SCHEMA.md referenced via plugin-relative path"
    (( PASS++ ))
else
    echo "  FAIL: REVIEW-SCHEMA.md not referenced via plugin-relative path in review-protocol/SKILL.md" >&2
    echo "    Current reference:" >&2
    grep -n 'REVIEW-SCHEMA' "$REVIEW_SKILL" >&2 || true
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
