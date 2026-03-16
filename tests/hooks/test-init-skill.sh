#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-init-skill.sh
# Verifies that the /init skill file exists at lockpick-workflow/skills/init/SKILL.md
# and contains the required content (frontmatter, script references, config defaults).
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-init-skill.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$PLUGIN_ROOT/skills/init/SKILL.md"

echo "=== test-init-skill.sh ==="

# test_init_skill_file_exists
# The SKILL.md must exist at the expected path.
if [[ -f "$SKILL_FILE" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_init_skill_file_exists" "exists" "$actual"

# test_init_skill_frontmatter_name
# Frontmatter must declare: name: init
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^name: init" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_frontmatter_name" "present" "$actual"
fi

# test_init_skill_frontmatter_user_invocable
# Frontmatter must declare: user-invocable: true
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^user-invocable: true" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_frontmatter_user_invocable" "present" "$actual"
fi

# test_init_skill_frontmatter_description
# Frontmatter must declare a description field.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^description:" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_frontmatter_description" "present" "$actual"
fi

# test_init_skill_references_detect_stack
# Must reference detect-stack.sh via ${CLAUDE_PLUGIN_ROOT}.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q 'CLAUDE_PLUGIN_ROOT.*detect-stack' "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_references_detect_stack" "present" "$actual"
fi

# test_init_skill_references_read_config
# Must reference read-config.sh via ${CLAUDE_PLUGIN_ROOT}.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qE 'CLAUDE_PLUGIN_ROOT.*read-config|read-config.*CLAUDE_PLUGIN_ROOT' "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_references_read_config" "present" "$actual"
fi

# test_init_skill_covers_python_poetry
# Must document python-poetry stack defaults.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q 'python-poetry' "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_covers_python_poetry" "present" "$actual"
fi

# test_init_skill_covers_node_npm
# Must document node-npm stack defaults.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q 'node-npm' "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_covers_node_npm" "present" "$actual"
fi

# test_init_skill_covers_unknown_stack_escalation
# Must document escalation path when stack is 'unknown'.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q 'unknown' "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_covers_unknown_stack_escalation" "present" "$actual"
fi

# test_init_skill_references_workflow_config
# Must reference workflow-config.yaml as the output file.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q 'workflow-config.yaml' "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_init_skill_references_workflow_config" "present" "$actual"
fi

print_summary
