#!/usr/bin/env bash
# tests/scripts/test-no-unguarded-plugin-refs.sh
# Regression guard: ensures debug-everything/SKILL.md does not contain
# hard-coded subagent_type references to removed external plugin agents.
#
# These 6 plugin agent types were removed and should be dispatched via
# discover-agents.sh routing categories instead:
#   unit-testing, debugging-toolkit, code-simplifier,
#   backend-api-security, commit-commands, claude-md-management
#
# Usage: bash tests/scripts/test-no-unguarded-plugin-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-no-unguarded-plugin-refs (debug-everything) ==="

SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

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


# ── Test: No unguarded plugin refs in scripts/ ─────────────
# Scans .sh and .yaml files in scripts/ for hard-coded
# references to removed plugin names. Excludes:
#   - plugin-reference-catalog.sh (canonical registry of removed plugins)
#   - discover-agents.sh (routing system itself, references plugin names in docs)
#   - agent-profiles/*.yaml agent_type fields (definitions, not dispatch calls)
# Any other occurrence is considered "unguarded" — it should use a routing
# category from agent-routing.conf instead of a bare plugin name.

test_scripts_no_unguarded_removed_plugins() {
    echo ""
    echo "=== test-no-unguarded-plugin-refs (scripts) ==="

    local scripts_dir="$DSO_PLUGIN_DIR/scripts"
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

# ── Test: No unguarded plugin refs in sprint/SKILL.md and REVIEW-WORKFLOW.md ──
# Ensures sprint/SKILL.md does not use unit-testing:test-automator as a
# subagent_type (should use routing-based resolution via test_write category),
# and REVIEW-WORKFLOW.md does not reference removed plugin names as dispatch
# examples.

test_sprint_review_no_unguarded_removed_plugins() {
    echo ""
    echo "=== test-no-unguarded-plugin-refs (sprint + review-workflow) ==="

    local sprint_file="$DSO_PLUGIN_DIR/skills/sprint/SKILL.md"
    local review_file="$DSO_PLUGIN_DIR/docs/workflows/REVIEW-WORKFLOW.md"
    local removed_plugins=("unit-testing" "debugging-toolkit" "code-simplifier" "backend-api-security" "commit-commands" "claude-md-management")

    # Test: sprint/SKILL.md exists
    echo "Test: sprint/SKILL.md exists"
    if [[ -f "$sprint_file" ]]; then
        echo "  PASS: sprint/SKILL.md exists"
        (( PASS++ ))
    else
        echo "  FAIL: sprint/SKILL.md not found at $sprint_file" >&2
        (( FAIL++ ))
    fi

    # Test: No subagent_type="unit-testing:" in sprint/SKILL.md
    echo "Test: No subagent_type=\"unit-testing:\" in sprint/SKILL.md"
    local sprint_matches
    sprint_matches=$(grep -c 'subagent_type="unit-testing:' "$sprint_file" 2>/dev/null || true)
    if [[ "$sprint_matches" -eq 0 ]]; then
        echo "  PASS: No subagent_type=\"unit-testing:\" references in sprint/SKILL.md"
        (( PASS++ ))
    else
        echo "  FAIL: Found $sprint_matches subagent_type=\"unit-testing:\" reference(s) in sprint/SKILL.md" >&2
        grep -n 'subagent_type="unit-testing:' "$sprint_file" >&2
        (( FAIL++ ))
    fi

    # Test: REVIEW-WORKFLOW.md exists
    echo "Test: REVIEW-WORKFLOW.md exists"
    if [[ -f "$review_file" ]]; then
        echo "  PASS: REVIEW-WORKFLOW.md exists"
        (( PASS++ ))
    else
        echo "  FAIL: REVIEW-WORKFLOW.md not found at $review_file" >&2
        (( FAIL++ ))
    fi

    # Test: No removed plugin dispatch examples in REVIEW-WORKFLOW.md
    for plugin in "${removed_plugins[@]}"; do
        echo "Test: No '${plugin}:' dispatch example in REVIEW-WORKFLOW.md"
        local review_matches
        review_matches=$(grep -c "${plugin}:" "$review_file" 2>/dev/null || true)
        if [[ "$review_matches" -eq 0 ]]; then
            echo "  PASS: No '${plugin}:' references in REVIEW-WORKFLOW.md"
            (( PASS++ ))
        else
            echo "  FAIL: Found $review_matches '${plugin}:' reference(s) in REVIEW-WORKFLOW.md" >&2
            grep -n "${plugin}:" "$review_file" >&2
            (( FAIL++ ))
        fi
    done
}

test_sprint_review_no_unguarded_removed_plugins

# ── Test: No unguarded plugin refs in COMMIT-WORKFLOW.md and TEST-FAILURE-DISPATCH.md ──
# Ensures workflow docs do not hard-code removed plugin agent types as dispatch
# targets. These should use routing category references via discover-agents.sh
# and agent-routing.conf instead. error-debugging:error-detective is exempt
# (core agent, not a removed plugin).

test_workflow_docs_no_unguarded_removed_plugins() {
    echo ""
    echo "=== test-no-unguarded-plugin-refs (commit-workflow + test-failure-dispatch) ==="

    local commit_file="$DSO_PLUGIN_DIR/docs/workflows/COMMIT-WORKFLOW.md"
    local dispatch_file="$DSO_PLUGIN_DIR/docs/workflows/TEST-FAILURE-DISPATCH.md"
    # Only the 3 removed plugins referenced in these docs as dispatch targets
    local removed_dispatch_plugins=("unit-testing" "debugging-toolkit" "code-simplifier")

    # Test: COMMIT-WORKFLOW.md exists
    echo "Test: COMMIT-WORKFLOW.md exists"
    if [[ -f "$commit_file" ]]; then
        echo "  PASS: COMMIT-WORKFLOW.md exists"
        (( PASS++ ))
    else
        echo "  FAIL: COMMIT-WORKFLOW.md not found at $commit_file" >&2
        (( FAIL++ ))
    fi

    # Test: TEST-FAILURE-DISPATCH.md exists
    echo "Test: TEST-FAILURE-DISPATCH.md exists"
    if [[ -f "$dispatch_file" ]]; then
        echo "  PASS: TEST-FAILURE-DISPATCH.md exists"
        (( PASS++ ))
    else
        echo "  FAIL: TEST-FAILURE-DISPATCH.md not found at $dispatch_file" >&2
        (( FAIL++ ))
    fi

    # Test: No removed plugin dispatch targets in COMMIT-WORKFLOW.md
    for plugin in "${removed_dispatch_plugins[@]}"; do
        echo "Test: No '${plugin}:' dispatch target in COMMIT-WORKFLOW.md"
        local commit_matches
        commit_matches=$(grep -c "${plugin}:" "$commit_file" 2>/dev/null || true)
        if [[ "$commit_matches" -eq 0 ]]; then
            echo "  PASS: No '${plugin}:' references in COMMIT-WORKFLOW.md"
            (( PASS++ ))
        else
            echo "  FAIL: Found $commit_matches '${plugin}:' reference(s) in COMMIT-WORKFLOW.md" >&2
            grep -n "${plugin}:" "$commit_file" >&2
            (( FAIL++ ))
        fi
    done

    # Test: No removed plugin dispatch targets in TEST-FAILURE-DISPATCH.md
    for plugin in "${removed_dispatch_plugins[@]}"; do
        echo "Test: No '${plugin}:' dispatch target in TEST-FAILURE-DISPATCH.md"
        local dispatch_matches
        dispatch_matches=$(grep -c "${plugin}:" "$dispatch_file" 2>/dev/null || true)
        if [[ "$dispatch_matches" -eq 0 ]]; then
            echo "  PASS: No '${plugin}:' references in TEST-FAILURE-DISPATCH.md"
            (( PASS++ ))
        else
            echo "  FAIL: Found $dispatch_matches '${plugin}:' reference(s) in TEST-FAILURE-DISPATCH.md" >&2
            grep -n "${plugin}:" "$dispatch_file" >&2
            (( FAIL++ ))
        fi
    done

    # Test: error-debugging:error-detective preserved in COMMIT-WORKFLOW.md
    echo "Test: error-debugging:error-detective preserved in COMMIT-WORKFLOW.md"
    if grep -q 'error-debugging:error-detective' "$commit_file"; then
        echo "  PASS: error-debugging:error-detective present in COMMIT-WORKFLOW.md"
        (( PASS++ ))
    else
        echo "  FAIL: error-debugging:error-detective missing from COMMIT-WORKFLOW.md" >&2
        (( FAIL++ ))
    fi

    # Test: error-debugging:error-detective preserved in TEST-FAILURE-DISPATCH.md
    echo "Test: error-debugging:error-detective preserved in TEST-FAILURE-DISPATCH.md"
    if grep -q 'error-debugging:error-detective' "$dispatch_file"; then
        echo "  PASS: error-debugging:error-detective present in TEST-FAILURE-DISPATCH.md"
        (( PASS++ ))
    else
        echo "  FAIL: error-debugging:error-detective missing from TEST-FAILURE-DISPATCH.md" >&2
        (( FAIL++ ))
    fi

    # Test: Routing system referenced in COMMIT-WORKFLOW.md
    echo "Test: Routing system referenced in COMMIT-WORKFLOW.md"
    if grep -qE 'discover-agents\.sh|routing category|agent-routing\.conf' "$commit_file"; then
        echo "  PASS: Routing system references found in COMMIT-WORKFLOW.md"
        (( PASS++ ))
    else
        echo "  FAIL: No routing system references in COMMIT-WORKFLOW.md" >&2
        (( FAIL++ ))
    fi
}

test_workflow_docs_no_unguarded_removed_plugins

# ── Test: INSTALL.md optional plugins section ────────────────────────────────
# Ensures INSTALL.md documents optional plugins (feature-dev, playwright,
# error-debugging) and does not list removed plugins as requirements.

test_install_doc_optional_plugins_section() {
    echo ""
    echo "=== test-no-unguarded-plugin-refs (install-docs) ==="

    local install_file="$REPO_ROOT/INSTALL.md"
    local removed_plugins=("unit-testing" "debugging-toolkit" "code-simplifier" "backend-api-security" "commit-commands" "claude-md-management")

    # Test: INSTALL.md exists
    echo "Test: INSTALL.md exists"
    if [[ -f "$install_file" ]]; then
        echo "  PASS: INSTALL.md exists"
        (( PASS++ ))
    else
        echo "  FAIL: INSTALL.md not found at $install_file" >&2
        (( FAIL++ ))
        return
    fi

    # Test: Has Optional Plugins section
    echo "Test: INSTALL.md has Optional Plugins section"
    if grep -q 'Optional Plugins' "$install_file"; then
        echo "  PASS: Optional Plugins section found"
        (( PASS++ ))
    else
        echo "  FAIL: Optional Plugins section missing" >&2
        (( FAIL++ ))
    fi

    # Test: Lists feature-dev, playwright, error-debugging as optional
    for plugin in feature-dev playwright error-debugging; do
        echo "Test: INSTALL.md mentions '$plugin'"
        if grep -q "$plugin" "$install_file"; then
            echo "  PASS: '$plugin' found"
            (( PASS++ ))
        else
            echo "  FAIL: '$plugin' missing from INSTALL.md" >&2
            (( FAIL++ ))
        fi
    done

    # Test: No removed plugins listed as requirements
    for plugin in "${removed_plugins[@]}"; do
        echo "Test: '$plugin' not listed as required in INSTALL.md"
        if grep -iE "${plugin}.*(required|must install)" "$install_file" 2>/dev/null; then
            echo "  FAIL: '$plugin' listed as required" >&2
            (( FAIL++ ))
        else
            echo "  PASS: '$plugin' not listed as required"
            (( PASS++ ))
        fi
    done
}

test_install_doc_optional_plugins_section

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
