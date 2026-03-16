#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-plugin-scaffold.sh
# Verifies the lockpick-workflow plugin scaffold directories and plugin.json exist.
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-plugin-scaffold.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# test_plugin_root_exists
# The lockpick-workflow/ directory must exist at the repo root.
if [[ -d "$PLUGIN_ROOT" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugin_root_exists" "exists" "$actual"

# test_plugin_json_exists
# lockpick-workflow/plugin.json must exist.
if [[ -f "$PLUGIN_ROOT/plugin.json" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugin_json_exists" "exists" "$actual"

# test_plugin_json_is_valid_json
# lockpick-workflow/plugin.json must be valid JSON.
if python3 -m json.tool "$PLUGIN_ROOT/plugin.json" > /dev/null 2>&1; then
    actual="valid"
else
    actual="invalid"
fi
assert_eq "test_plugin_json_is_valid_json" "valid" "$actual"

# test_plugin_subdirs_exist
# All required subdirectories must exist under lockpick-workflow/.
required_dirs=(
    "skills"
    "hooks"
    "hooks/lib"
    "scripts"
    "docs"
    "docs/workflows"
)

for subdir in "${required_dirs[@]}"; do
    if [[ -d "$PLUGIN_ROOT/$subdir" ]]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_plugin_subdirs_exist: $subdir" "exists" "$actual"
done

print_summary
