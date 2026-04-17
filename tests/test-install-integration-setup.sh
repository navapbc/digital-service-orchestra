#!/usr/bin/env bash
# tests/test-install-integration-setup.sh
# RED test for 2849-aeb1: asserts that INSTALL.md contains a ## Integration Setup
# section with Jira, Figma, and Confluence subsections, and that prior INSTALL.md
# content is preserved.
#
# Verifies that:
#  1. INSTALL.md contains ## Integration Setup section heading
#  2. INSTALL.md contains ### Jira subsection heading
#  3. Jira subsection mentions API token
#  4. Jira subsection mentions user email
#  5. Jira subsection mentions JIRA_URL (env var or phrase "Jira base URL")
#  6. Jira subsection links to the Atlassian API token management doc
#  7. INSTALL.md contains ### Figma subsection heading
#  8. Figma subsection mentions personal access token (or FIGMA_PAT)
#  9. Figma subsection links to the Figma personal access token doc
# 10. INSTALL.md contains ### Confluence subsection heading with placeholder text
#     ("planned" or "not yet")
# 11. Prior content still present: /plugin marketplace add navapbc/digital-service-orchestra
# 12. Prior content: /plugin install dso@digital-service-orchestra
# 13. Prior content: ## Prerequisites
# 14. Prior content: ## Installation
# 15. Prior content: ## Optional Dependencies
# 16. Prior content: /dso:onboarding
#
# This test FAILS (RED) before the Integration Setup section is added to INSTALL.md.
#
# Usage: bash tests/test-install-integration-setup.sh
# Returns: exit 0 if all assertions pass, exit 1 on first failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_MD="${REPO_ROOT}/INSTALL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() {
    echo "  FAIL: $1" >&2
    FAIL=$((FAIL + 1))
    echo ""
    echo "=== Results ==="
    echo "Passed: $PASS"
    echo "Failed: $FAIL"
    echo "VALIDATION FAILED"
    exit 1
}

echo "=== test-install-integration-setup.sh ==="
echo ""

# ── test_install_integration_setup ────────────────────────────────────────────
# Given: INSTALL.md exists at repo root (pre-requisite from prior task a7ec-b085)
# When:  we inspect whether the Integration Setup section has been added
# Then:  all required headings, content references, and prior content are present

echo "--- test_install_integration_setup ---"

# Prerequisite: INSTALL.md must exist for any assertions to proceed
if [ ! -f "$INSTALL_MD" ]; then
    fail "INSTALL.md not found at repo root (${INSTALL_MD})"
fi
pass "INSTALL.md exists at repo root"

# Read content once for subsequent checks
_content="$(cat "$INSTALL_MD")"

# Assertion 1: ## Integration Setup section heading
if ! printf '%s\n' "$_content" | grep -q '^## Integration Setup'; then
    fail "INSTALL.md missing '## Integration Setup' section heading"
fi
pass "INSTALL.md contains '## Integration Setup' heading"

# Assertion 2: ### Jira subsection heading
if ! printf '%s\n' "$_content" | grep -q '^### Jira'; then
    fail "INSTALL.md missing '### Jira' subsection heading"
fi
pass "INSTALL.md contains '### Jira' subsection heading"

# Assertion 3: Jira subsection mentions API token
if ! printf '%s\n' "$_content" | grep -qiE 'API token|api_token|api-token'; then
    fail "INSTALL.md Jira subsection does not mention API token"
fi
pass "INSTALL.md Jira subsection mentions API token"

# Assertion 4: Jira subsection mentions user email
if ! printf '%s\n' "$_content" | grep -qiE 'email|JIRA_USER'; then
    fail "INSTALL.md Jira subsection does not mention user email or JIRA_USER"
fi
pass "INSTALL.md Jira subsection mentions user email or JIRA_USER"

# Assertion 5: Jira subsection mentions JIRA_URL env var or phrase "Jira base URL"
if ! printf '%s\n' "$_content" | grep -qE 'JIRA_URL|Jira base URL|jira.*url|JIRA.*URL'; then
    fail "INSTALL.md Jira subsection does not mention JIRA_URL or 'Jira base URL'"
fi
pass "INSTALL.md Jira subsection mentions JIRA_URL or 'Jira base URL'"

# Assertion 6: Jira subsection links to Atlassian API token management doc
if ! printf '%s\n' "$_content" | grep -q 'support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account'; then
    fail "INSTALL.md Jira subsection missing link to support.atlassian.com API token management doc"
fi
pass "INSTALL.md Jira subsection links to Atlassian API token management doc"

# Assertion 7: ### Figma subsection heading
if ! printf '%s\n' "$_content" | grep -q '^### Figma'; then
    fail "INSTALL.md missing '### Figma' subsection heading"
fi
pass "INSTALL.md contains '### Figma' subsection heading"

# Assertion 8: Figma subsection mentions personal access token or FIGMA_PAT
if ! printf '%s\n' "$_content" | grep -qiE 'personal access token|FIGMA_PAT'; then
    fail "INSTALL.md Figma subsection does not mention personal access token or FIGMA_PAT"
fi
pass "INSTALL.md Figma subsection mentions personal access token or FIGMA_PAT"

# Assertion 9: Figma subsection links to Figma PAT documentation
if ! printf '%s\n' "$_content" | grep -q 'help.figma.com/hc/en-us/articles/8085703771159-Manage-personal-access-tokens'; then
    fail "INSTALL.md Figma subsection missing link to help.figma.com personal access tokens doc"
fi
pass "INSTALL.md Figma subsection links to Figma personal access tokens doc"

# Assertion 10: ### Confluence subsection heading with placeholder text
if ! printf '%s\n' "$_content" | grep -q '^### Confluence'; then
    fail "INSTALL.md missing '### Confluence' subsection heading"
fi
pass "INSTALL.md contains '### Confluence' subsection heading"

# Assertion 10b: Confluence subsection contains placeholder indicating it is not yet implemented
if ! printf '%s\n' "$_content" | grep -qiE 'planned|not yet'; then
    fail "INSTALL.md Confluence subsection does not contain placeholder text ('planned' or 'not yet')"
fi
pass "INSTALL.md Confluence subsection contains placeholder text"

# Assertion 11: Prior content — marketplace add command preserved
if ! printf '%s\n' "$_content" | grep -q '/plugin marketplace add navapbc/digital-service-orchestra'; then
    fail "INSTALL.md is missing prior content: '/plugin marketplace add navapbc/digital-service-orchestra'"
fi
pass "INSTALL.md still contains '/plugin marketplace add navapbc/digital-service-orchestra'"

# Assertion 12: Prior content — plugin install command preserved
if ! printf '%s\n' "$_content" | grep -q '/plugin install dso@digital-service-orchestra'; then
    fail "INSTALL.md is missing prior content: '/plugin install dso@digital-service-orchestra'"
fi
pass "INSTALL.md still contains '/plugin install dso@digital-service-orchestra'"

# Assertion 13: Prior content — ## Prerequisites heading preserved
if ! printf '%s\n' "$_content" | grep -q '^## Prerequisites'; then
    fail "INSTALL.md is missing prior heading: '## Prerequisites'"
fi
pass "INSTALL.md still contains '## Prerequisites' heading"

# Assertion 14: Prior content — ## Installation heading preserved
if ! printf '%s\n' "$_content" | grep -q '^## Installation'; then
    fail "INSTALL.md is missing prior heading: '## Installation'"
fi
pass "INSTALL.md still contains '## Installation' heading"

# Assertion 15: Prior content — ## Optional Dependencies heading preserved
if ! printf '%s\n' "$_content" | grep -q '^## Optional Dependencies'; then
    fail "INSTALL.md is missing prior heading: '## Optional Dependencies'"
fi
pass "INSTALL.md still contains '## Optional Dependencies' heading"

# Assertion 16: Prior content — /dso:onboarding reference preserved
if ! printf '%s\n' "$_content" | grep -q '/dso:onboarding'; then
    fail "INSTALL.md is missing prior content: '/dso:onboarding'"
fi
pass "INSTALL.md still contains '/dso:onboarding'"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "VALIDATION FAILED"
    exit 1
fi
echo "ALL VALIDATIONS PASSED"
exit 0
