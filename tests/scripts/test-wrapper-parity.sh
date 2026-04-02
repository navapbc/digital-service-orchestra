#!/usr/bin/env bash
# tests/scripts/test-wrapper-parity.sh
# Structural guard: verifies that every skill with user-invocable: true has a
# corresponding .claude/commands/<name>.md wrapper file, and vice versa.
#
# This test catches future drift when new skills are added without wrappers or
# when wrapper files are added without corresponding skill directories.
#
# Usage: bash tests/scripts/test-wrapper-parity.sh
# Returns: exit 0 if all pass, exit 1 with details if any missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-wrapper-parity.sh ==="

SKILLS_DIR="$PLUGIN_ROOT/plugins/dso/skills"
COMMANDS_DIR="$PLUGIN_ROOT/.claude/commands"

# ── test_user_invocable_skills_have_wrappers ──────────────────────────────────
# Every skill with user-invocable: true must have a .claude/commands/<name>.md
test_user_invocable_skills_have_wrappers() {
    local missing=()

    while IFS= read -r skill_md; do
        local skill_name
        skill_name="$(basename "$(dirname "$skill_md")")"
        local wrapper="$COMMANDS_DIR/${skill_name}.md"
        if [[ ! -f "$wrapper" ]]; then
            missing+=("$skill_name")
        fi
    done < <(grep -rl "user-invocable: true" "$SKILLS_DIR" 2>/dev/null | sort)

    if [[ "${#missing[@]}" -eq 0 ]]; then
        (( ++PASS ))
        echo "test_user_invocable_skills_have_wrappers ... PASS"
    else
        (( ++FAIL ))
        printf "FAIL: test_user_invocable_skills_have_wrappers\n" >&2
        for name in "${missing[@]}"; do
            printf "  missing wrapper: .claude/commands/%s.md (skill has user-invocable: true)\n" "$name" >&2
        done
    fi
}

# ── test_wrappers_have_skill_directories ─────────────────────────────────────
# Every .claude/commands/<name>.md must have a corresponding skill directory
# plugins/dso/skills/<name>/ (no orphan wrappers).
test_wrappers_have_skill_directories() {
    local orphans=()

    for wrapper in "$COMMANDS_DIR"/*.md; do
        [[ -f "$wrapper" ]] || continue
        local name
        name="$(basename "$wrapper" .md)"
        local skill_dir="$SKILLS_DIR/$name"
        if [[ ! -d "$skill_dir" ]]; then
            orphans+=("$name")
        fi
    done

    if [[ "${#orphans[@]}" -eq 0 ]]; then
        (( ++PASS ))
        echo "test_wrappers_have_skill_directories ... PASS (no orphan wrappers)"
    else
        (( ++FAIL ))
        printf "FAIL: test_wrappers_have_skill_directories\n" >&2
        for name in "${orphans[@]}"; do
            printf "  orphan wrapper: .claude/commands/%s.md has no matching skill directory\n" "$name" >&2
        done
    fi
}

# ── test_wrapper_count_matches_user_invocable_count ──────────────────────────
# The number of wrappers must equal the number of user-invocable skills.
# Catches asymmetries not caught by the above two directional checks.
test_wrapper_count_matches_user_invocable_count() {
    local invocable_count
    invocable_count="$(grep -rl "user-invocable: true" "$SKILLS_DIR" 2>/dev/null | wc -l | tr -d ' ')"

    local wrapper_count=0
    for wrapper in "$COMMANDS_DIR"/*.md; do
        [[ -f "$wrapper" ]] && (( ++wrapper_count )) || true
    done

    assert_eq "test_wrapper_count_matches_user_invocable_count" \
        "$invocable_count" "$wrapper_count"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_user_invocable_skills_have_wrappers
test_wrappers_have_skill_directories
test_wrapper_count_matches_user_invocable_count

print_summary
