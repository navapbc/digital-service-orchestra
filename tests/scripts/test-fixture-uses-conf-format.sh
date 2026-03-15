#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-fixture-uses-conf-format.sh
# TDD sentinel: verifies no test file creates workflow-config.yaml fixtures.
# All test fixtures should use the flat .conf format instead.
#
# This test greps lockpick-workflow/tests/ for lines that create
# workflow-config.yaml files (cat > ... or printf ... > ... workflow-config.yaml)
# and fails if any are found. Comments, compat/fallback references, and
# read-only references are excluded.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-fixture-uses-conf-format.sh ==="

# Find lines in test .sh files that create workflow-config.yaml fixtures.
# Exclude: comments (#), .conf references, compat/fallback test files,
# the test-read-config-flat.sh backward-compat test (which intentionally tests .yaml fallback),
# and this file itself.
_snapshot_fail
offenders=$(grep -rn 'workflow-config\.yaml' "$REPO_ROOT/lockpick-workflow/tests/" \
    --include='*.sh' \
    | grep -v '^\s*#\|\.conf\|#.*workflow-config\|fallback\|compat\|backward' \
    | grep -v 'test-fixture-uses-conf-format\.sh' \
    | grep -v 'test-read-config-flat\.sh' \
    | grep -v 'test-read-config\.sh' \
    | grep -v 'test-config-callers-updated\.sh' \
    | grep -v 'test-adr-config-system\.sh' \
    | grep -v 'test-init-skill\.sh' \
    | grep -v 'test-docs-config-refs\.sh' \
    | grep -v 'test-no-yaml-config-refs\.sh' \
    || true)

match_count=0
if [[ -n "$offenders" ]]; then
    match_count=$(echo "$offenders" | wc -l | tr -d ' ')
fi

assert_eq "test_no_yaml_fixture_creation" "0" "$match_count"

if [[ "$match_count" -gt 0 ]]; then
    echo "  Offending lines:"
    echo "$offenders" | head -20
fi

print_summary
