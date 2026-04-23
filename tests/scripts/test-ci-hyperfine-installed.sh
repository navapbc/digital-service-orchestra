#!/usr/bin/env bash
# tests/scripts/test-ci-hyperfine-installed.sh
# Verify that .github/workflows/ci.yml includes an "Install hyperfine" step
# and a "Verify hyperfine installed" verification step.
#
# Tests:
#  1. test_ci_has_install_hyperfine_step     — ci.yml contains Install hyperfine step
#  2. test_ci_has_hyperfine_version_check    — ci.yml contains hyperfine --version verification
#
# Usage: bash tests/scripts/test-ci-hyperfine-installed.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ci-hyperfine-installed.sh ==="

# ── test_ci_has_install_hyperfine_step ────────────────────────────────────────
if grep -q "Install hyperfine" "$CI_YML" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_ci_has_install_hyperfine_step" "found" "$actual"

# ── test_ci_has_hyperfine_apt_get_command ─────────────────────────────────────
if grep -q "apt-get install.*hyperfine\|apt-get.*install.*hyperfine" "$CI_YML" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_ci_has_hyperfine_apt_get_command" "found" "$actual"

# ── test_ci_has_hyperfine_version_check ───────────────────────────────────────
if grep -q "hyperfine --version" "$CI_YML" 2>/dev/null; then
    actual="found"
else
    actual="missing"
fi
assert_eq "test_ci_has_hyperfine_version_check" "found" "$actual"

print_summary
