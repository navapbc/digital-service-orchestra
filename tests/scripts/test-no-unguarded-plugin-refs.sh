#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-no-unguarded-plugin-refs.sh
# Regression guard: ensures debug-everything/SKILL.md does not contain
# hard-coded subagent_type references to removed external plugin agents.
#
# These 6 plugin agent types were removed and should be dispatched via
# discover-agents.sh routing categories instead:
#   unit-testing, debugging-toolkit, code-simplifier,
#   backend-api-security, commit-commands, claude-md-management
#
# Usage: bash lockpick-workflow/tests/scripts/test-no-unguarded-plugin-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-no-unguarded-plugin-refs (debug-everything) ==="

SKILL_FILE="$REPO_ROOT/lockpick-workflow/skills/debug-everything/SKILL.md"

# List of removed plugin agent types that should NOT appear as hard-coded
# subagent_type values in the dispatch table or elsewhere in SKILL.md
REMOVED_PLUGINS=(
    "unit-testing"
    "debugging-toolkit"
    "code-simplifier"
    "backend-api-security"
    "commit-commands"
    "claude-md-management"
)

# ── Test 1: SKILL.md exists ──────────────────────────────────────────────────
echo "Test 1: debug-everything/SKILL.md exists"
if [[ -f "$SKILL_FILE" ]]; then
    echo "  PASS: SKILL.md exists"
    (( PASS++ ))
else
    echo "  FAIL: SKILL.md not found at $SKILL_FILE" >&2
    (( FAIL++ ))
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# ── Test 2-7: No hard-coded subagent_type refs for each removed plugin ───────
for plugin in "${REMOVED_PLUGINS[@]}"; do
    echo "Test: No hard-coded subagent_type=\"$plugin:\" in SKILL.md"
    matches=$(grep -c "subagent_type=\"${plugin}:" "$SKILL_FILE" 2>/dev/null || true)
    if [[ "$matches" -eq 0 ]]; then
        echo "  PASS: No subagent_type=\"$plugin:\" references found"
        (( PASS++ ))
    else
        echo "  FAIL: Found $matches hard-coded subagent_type=\"$plugin:\" reference(s)" >&2
        grep -n "subagent_type=\"${plugin}:" "$SKILL_FILE" >&2
        (( FAIL++ ))
    fi
done

# ── Test 8: error-debugging:error-detective is preserved ─────────────────────
echo "Test: error-debugging:error-detective references preserved"
if grep -q 'error-debugging:error-detective' "$SKILL_FILE"; then
    echo "  PASS: error-debugging:error-detective references present"
    (( PASS++ ))
else
    echo "  FAIL: error-debugging:error-detective references missing" >&2
    (( FAIL++ ))
fi

# ── Test 9: Dispatch table references routing system ─────────────────────────
echo "Test: Dispatch table references routing categories or discover-agents.sh"
if grep -qE 'discover-agents\.sh|routing category|agent-routing\.conf' "$SKILL_FILE"; then
    echo "  PASS: Routing system references found"
    (( PASS++ ))
else
    echo "  FAIL: No routing system references (discover-agents.sh, routing category, or agent-routing.conf) found" >&2
    (( FAIL++ ))
fi


# ── Test: No unguarded plugin refs in lockpick-workflow/scripts/ ─────────────
# Scans .sh and .yaml files in lockpick-workflow/scripts/ for hard-coded
# references to removed plugin names. Excludes:
#   - plugin-reference-catalog.sh (canonical registry of removed plugins)
#   - discover-agents.sh (routing system itself, references plugin names in docs)
#   - agent-profiles/*.yaml agent_type fields (definitions, not dispatch calls)
# Any other occurrence is considered "unguarded" — it should use a routing
# category from agent-routing.conf instead of a bare plugin name.

test_scripts_no_unguarded_removed_plugins() {
    echo ""
    echo "=== test-no-unguarded-plugin-refs (scripts) ==="

    local scripts_dir="$REPO_ROOT/lockpick-workflow/scripts"
    local removed_plugins=("unit-testing" "debugging-toolkit" "code-simplifier" "backend-api-security" "commit-commands" "claude-md-management")
    local excluded_files=("plugin-reference-catalog.sh" "discover-agents.sh")

    # Build grep -v filter pattern for excluded files
    local exclude_pattern
    exclude_pattern=$(printf '%s\|' "${excluded_files[@]}")
    exclude_pattern="${exclude_pattern%\\|}"  # strip trailing \|

    for plugin in "${removed_plugins[@]}"; do
        echo "Test: No unguarded '$plugin' references in scripts/"

        # Search .sh files (excluding allowed files by filtering output)
        local sh_matches
        sh_matches=$(grep -rn --include='*.sh' "$plugin" "$scripts_dir" 2>/dev/null | grep -v "$exclude_pattern" || true)

        # Search .yaml files, but filter out structural definition lines:
        #   - agent_type: lines (agent definitions in profile YAMLs)
        #   - expected_agent: lines (test case assertions in test-cases.yaml)
        local yaml_matches
        yaml_matches=$(grep -rn --include='*.yaml' "$plugin" "$scripts_dir" 2>/dev/null | grep -v -e '^.*:.*agent_type:' -e '^.*:.*expected_agent:' || true)

        local all_matches=""
        if [[ -n "$sh_matches" ]]; then
            all_matches="$sh_matches"
        fi
        if [[ -n "$yaml_matches" ]]; then
            if [[ -n "$all_matches" ]]; then
                all_matches="$all_matches"$'\n'"$yaml_matches"
            else
                all_matches="$yaml_matches"
            fi
        fi

        if [[ -z "$all_matches" ]]; then
            echo "  PASS: No unguarded '$plugin' references"
            (( PASS++ ))
        else
            local count
            count=$(echo "$all_matches" | wc -l | tr -d ' ')
            echo "  FAIL: Found $count unguarded '$plugin' reference(s):" >&2
            echo "$all_matches" | head -10 >&2
            (( FAIL++ ))
        fi
    done
}

test_scripts_no_unguarded_removed_plugins

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
