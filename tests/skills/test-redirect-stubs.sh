#!/usr/bin/env bash
# tests/skills/test-redirect-stubs.sh
# Tests that old skill names redirect users to the replacement skills.
#
# REVIEW-DEFENSE: This test file is intentionally absent from .test-index.
# It validates 3 different source files (project-setup/SKILL.md,
# dev-onboarding/SKILL.md, and design-onboarding/SKILL.md), so there is no
# single source-file-to-test mapping that .test-index supports. Adding it
# would require 3 separate entries each pointing to the same test file, which
# is redundant and fragile. The RED marker mechanism is handled at the test
# level via _snapshot_fail() in each test function.
#
# Validates (3 named assertions):
#   test_project_setup_redirects: plugins/dso/skills/project-setup/SKILL.md contains
#     text directing users to /dso:onboarding (grep for "onboarding" as a redirect destination)
#   test_dev_onboarding_redirects: plugins/dso/skills/dev-onboarding/SKILL.md contains
#     text directing users to /dso:architect-foundation (grep for "architect-foundation")
#   test_design_onboarding_redirects: plugins/dso/skills/design-onboarding/SKILL.md contains
#     text directing users to /dso:onboarding (grep for "onboarding" as a redirect destination)
#
# All tests will FAIL (RED) until the old SKILL.md files are replaced with redirect stubs
# that explicitly name the replacement skill with redirect language.
#
# Usage: bash tests/skills/test-redirect-stubs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

PROJECT_SETUP_SKILL_MD="$DSO_PLUGIN_DIR/skills/project-setup/SKILL.md"
DEV_ONBOARDING_SKILL_MD="$DSO_PLUGIN_DIR/skills/dev-onboarding/SKILL.md"
DESIGN_ONBOARDING_SKILL_MD="$DSO_PLUGIN_DIR/skills/design-onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-redirect-stubs.sh ==="

# test_project_setup_redirects: plugins/dso/skills/project-setup/SKILL.md must contain
# an explicit redirect instruction pointing users to /dso:onboarding.
# A redirect stub uses language like "renamed to /dso:onboarding", "Use /dso:onboarding instead",
# or "redirects to /dso:onboarding" — not merely incidental mentions of "onboarding".
test_project_setup_redirects() {
    _snapshot_fail
    local redirect_found
    redirect_found="missing"
    if grep -qE "renamed to /dso:onboarding|Use /dso:onboarding instead|redirects? to /dso:onboarding|replaced by /dso:onboarding|now /dso:onboarding" "$PROJECT_SETUP_SKILL_MD" 2>/dev/null; then
        redirect_found="found"
    fi
    assert_eq "test_project_setup_redirects" "found" "$redirect_found"
    assert_pass_if_clean "test_project_setup_redirects"
}

# test_dev_onboarding_redirects: plugins/dso/skills/dev-onboarding/SKILL.md must contain
# an explicit redirect instruction pointing users to /dso:architect-foundation.
# A redirect stub uses language like "renamed to /dso:architect-foundation",
# "Use /dso:architect-foundation instead", or "redirects to /dso:architect-foundation".
test_dev_onboarding_redirects() {
    _snapshot_fail
    local redirect_found
    redirect_found="missing"
    if grep -qE "renamed to /dso:architect-foundation|Use /dso:architect-foundation instead|redirects? to /dso:architect-foundation|replaced by /dso:architect-foundation|now /dso:architect-foundation" "$DEV_ONBOARDING_SKILL_MD" 2>/dev/null; then
        redirect_found="found"
    fi
    assert_eq "test_dev_onboarding_redirects" "found" "$redirect_found"
    assert_pass_if_clean "test_dev_onboarding_redirects"
}

# test_design_onboarding_redirects: plugins/dso/skills/design-onboarding/SKILL.md must contain
# an explicit redirect instruction pointing users to /dso:onboarding.
# A redirect stub uses language like "renamed to /dso:onboarding", "Use /dso:onboarding instead",
# or "redirects to /dso:onboarding" — not merely incidental mentions of "onboarding".
test_design_onboarding_redirects() {
    _snapshot_fail
    local redirect_found
    redirect_found="missing"
    if grep -qE "renamed to /dso:onboarding|Use /dso:onboarding instead|redirects? to /dso:onboarding|replaced by /dso:onboarding|now /dso:onboarding" "$DESIGN_ONBOARDING_SKILL_MD" 2>/dev/null; then
        redirect_found="found"
    fi
    assert_eq "test_design_onboarding_redirects" "found" "$redirect_found"
    assert_pass_if_clean "test_design_onboarding_redirects"
}

# Run all 3 test functions — all RED until redirect stubs replace full SKILL.md content
test_project_setup_redirects
test_dev_onboarding_redirects
test_design_onboarding_redirects

print_summary
