#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-validate-work-portability.sh
# Portability integration test for the validate-work skill.
#
# Verifies that the skill's config resolution, dispatch logic, and graceful
# degradation all work correctly for a second project (a Node.js/npm stack)
# without any modifications to plugin code.
#
# Tests covered:
#   A. Config resolution — full config: staging.url, staging.deploy_check, staging.test,
#      staging.routes, staging.health_path, ci.integration_workflow, commands.test
#   B. Staging URL absent — staging sub-agents should be SKIPPED per orchestrator logic
#   C. Partial staging config — staging.url present, but deploy_check and test absent
#      → Mode D (generic HTTP) fallback
#   D. .sh vs .md dispatch detection — file extension determines dispatch mode
#   E. CI integration_workflow absent — integration check should be SKIPPED
#   F. Fixture file structure validation
#
# Manual run:
#   bash lockpick-workflow/tests/plugin/test-validate-work-portability.sh
#
# Design note: This test validates config resolution and the dispatch logic
# present in the orchestrator (SKILL.md) and prompt files. It cannot actually
# run sub-agents (that requires Claude). It validates the resolved values and
# verifies that the plugin skill files encode the expected dispatch mechanism,
# proving the skill is portable to any project stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURES_DIR="$PLUGIN_ROOT/tests/fixtures/validate-work-portability"
READ_CONFIG="$PLUGIN_ROOT/scripts/read-config.sh"
SKILL_FILE="$PLUGIN_ROOT/skills/validate-work/SKILL.md"
DEPLOY_CHECK_PROMPT="$PLUGIN_ROOT/skills/validate-work/prompts/staging-deployment-check.md"
STAGING_TEST_PROMPT="$PLUGIN_ROOT/skills/validate-work/prompts/staging-environment-test.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== validate-work portability integration test ==="
echo ""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Reads a config key from the given fixture config file.
# Usage: read_key <config-file-path> <key>
# Returns the value or empty string.
read_key() {
    local config_file="$1"
    local key="$2"
    bash "$READ_CONFIG" "$key" "$config_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Prerequisite: fixture files must exist before any test runs
# ---------------------------------------------------------------------------
echo "--- prerequisite: fixture files exist ---"

assert_eq "workflow-config.conf exists" "true" \
    "$(test -f "$FIXTURES_DIR/workflow-config.conf" && echo true || echo false)"

assert_eq "workflow-config-no-staging.yaml exists" "true" \
    "$(test -f "$FIXTURES_DIR/workflow-config-no-staging.yaml" && echo true || echo false)"

assert_eq "workflow-config-partial-staging.yaml exists" "true" \
    "$(test -f "$FIXTURES_DIR/workflow-config-partial-staging.yaml" && echo true || echo false)"

assert_eq "staging-deploy-check.sh exists" "true" \
    "$(test -f "$FIXTURES_DIR/staging-deploy-check.sh" && echo true || echo false)"

assert_eq "staging-test.md exists" "true" \
    "$(test -f "$FIXTURES_DIR/staging-test.md" && echo true || echo false)"

assert_eq "SKILL.md exists" "true" \
    "$(test -f "$SKILL_FILE" && echo true || echo false)"

assert_eq "staging-deployment-check.md prompt exists" "true" \
    "$(test -f "$DEPLOY_CHECK_PROMPT" && echo true || echo false)"

assert_eq "staging-environment-test.md prompt exists" "true" \
    "$(test -f "$STAGING_TEST_PROMPT" && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test A: Config resolution — full config
# ---------------------------------------------------------------------------
echo ""
echo "--- Test A: config resolution — full config (node-npm stack) ---"

FULL_CONFIG="$FIXTURES_DIR/workflow-config.conf"

STACK=$(read_key "$FULL_CONFIG" "stack")
assert_eq "stack reads as node-npm" "node-npm" "$STACK"

TEST_CMD=$(read_key "$FULL_CONFIG" "commands.test")
assert_eq "commands.test reads as 'npm test'" "npm test" "$TEST_CMD"

STAGING_URL=$(read_key "$FULL_CONFIG" "staging.url")
assert_eq "staging.url reads as expected" \
    "https://staging.my-node-app.example.com" "$STAGING_URL"

STAGING_DEPLOY_CHECK=$(read_key "$FULL_CONFIG" "staging.deploy_check")
assert_eq "staging.deploy_check reads as .sh path" \
    "scripts/staging-deploy-check.sh" "$STAGING_DEPLOY_CHECK"

STAGING_TEST=$(read_key "$FULL_CONFIG" "staging.test")
assert_eq "staging.test reads as .md path" \
    "docs/staging-test.md" "$STAGING_TEST"

STAGING_ROUTES=$(read_key "$FULL_CONFIG" "staging.routes")
assert_eq "staging.routes reads correctly" \
    "/,/api/health,/api/v1/status" "$STAGING_ROUTES"

STAGING_HEALTH_PATH=$(read_key "$FULL_CONFIG" "staging.health_path")
assert_eq "staging.health_path reads correctly" "/api/health" "$STAGING_HEALTH_PATH"

INTEGRATION_WORKFLOW=$(read_key "$FULL_CONFIG" "ci.integration_workflow")
assert_eq "ci.integration_workflow reads correctly" "Integration Tests" "$INTEGRATION_WORKFLOW"

JIRA_PROJECT=$(read_key "$FULL_CONFIG" "jira.project")
assert_eq "jira.project reads correctly" "MNA" "$JIRA_PROJECT"

# ---------------------------------------------------------------------------
# Test B: Staging URL absent — verify orchestrator documents SKIPPED behavior
# ---------------------------------------------------------------------------
echo ""
echo "--- Test B: staging URL absent — verify SKIPPED behavior in orchestrator ---"

NO_STAGING_CONFIG="$FIXTURES_DIR/workflow-config-no-staging.yaml"

# Config should return empty for staging.url
STAGING_URL_ABSENT=$(read_key "$NO_STAGING_CONFIG" "staging.url")
assert_eq "staging.url is empty when staging section absent" "" "$STAGING_URL_ABSENT"

# Verify the orchestrator (SKILL.md) documents the SKIPPED behavior for absent staging URL.
# The SKILL.md must contain the logic: empty STAGING_URL → stagingConfigured = false → SKIPPED.
SKILL_MENTIONS_STAGING_SKIP=$(grep -c "stagingConfigured = false" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents stagingConfigured=false logic" "0" "$SKILL_MENTIONS_STAGING_SKIP"

SKILL_MENTIONS_SKIP_MSG=$(grep -c "SKIPPED (staging not configured)" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents SKIPPED message for absent staging" "0" "$SKILL_MENTIONS_SKIP_MSG"

# Validate the no-staging config still resolves commands correctly
STACK_NO_STAGING=$(read_key "$NO_STAGING_CONFIG" "stack")
assert_eq "stack resolves in no-staging config" "node-npm" "$STACK_NO_STAGING"

TEST_CMD_NO_STAGING=$(read_key "$NO_STAGING_CONFIG" "commands.test")
assert_eq "commands.test resolves in no-staging config" "npm test" "$TEST_CMD_NO_STAGING"

# ---------------------------------------------------------------------------
# Test C: Partial staging config — url present, deploy_check and test absent
# ---------------------------------------------------------------------------
echo ""
echo "--- Test C: partial staging config — url present, deploy_check/test absent ---"

PARTIAL_CONFIG="$FIXTURES_DIR/workflow-config-partial-staging.yaml"

PARTIAL_STAGING_URL=$(read_key "$PARTIAL_CONFIG" "staging.url")
assert_eq "staging.url present in partial config" \
    "https://staging.my-node-app.example.com" "$PARTIAL_STAGING_URL"

PARTIAL_DEPLOY_CHECK=$(read_key "$PARTIAL_CONFIG" "staging.deploy_check")
assert_eq "staging.deploy_check absent in partial config" "" "$PARTIAL_DEPLOY_CHECK"

PARTIAL_STAGING_TEST=$(read_key "$PARTIAL_CONFIG" "staging.test")
assert_eq "staging.test absent in partial config" "" "$PARTIAL_STAGING_TEST"

# Verify the prompts document Mode D (generic HTTP) as the fallback when scripts are absent.
DEPLOY_CHECK_HAS_MODE_D=$(grep -c "Mode D" "$DEPLOY_CHECK_PROMPT" 2>/dev/null || echo "0")
assert_ne "staging-deployment-check.md documents Mode D fallback" "0" "$DEPLOY_CHECK_HAS_MODE_D"

STAGING_TEST_HAS_MODE_D=$(grep -c "Mode D" "$STAGING_TEST_PROMPT" 2>/dev/null || echo "0")
assert_ne "staging-environment-test.md documents Mode D fallback" "0" "$STAGING_TEST_HAS_MODE_D"

# Verify SKILL.md states that absent STAGING_DEPLOY_CHECK falls through to Mode D
SKILL_MENTIONS_MODE_D=$(grep -c "absent.*Mode D\|Mode D.*absent\|absent, Sub-Agent.*Mode D\|absent.*generic" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents absent deploy_check falls through to Mode D" "0" "$SKILL_MENTIONS_MODE_D"

# ---------------------------------------------------------------------------
# Test D: .sh vs .md dispatch detection
# ---------------------------------------------------------------------------
echo ""
echo "--- Test D: .sh vs .md dispatch detection ---"

# Verify the deploy-check fixture has .sh extension
DEPLOY_CHECK_EXT="${STAGING_DEPLOY_CHECK##*.}"
assert_eq "staging.deploy_check from full config has .sh extension" "sh" "$DEPLOY_CHECK_EXT"

# Verify the staging-test fixture has .md extension
STAGING_TEST_EXT="${STAGING_TEST##*.}"
assert_eq "staging.test from full config has .md extension" "md" "$STAGING_TEST_EXT"

# Verify the staging-deployment-check.md prompt documents Mode A (.sh dispatch)
DEPLOY_CHECK_HAS_MODE_A=$(grep -c "Mode A" "$DEPLOY_CHECK_PROMPT" 2>/dev/null || echo "0")
assert_ne "staging-deployment-check.md documents Mode A (.sh dispatch)" "0" "$DEPLOY_CHECK_HAS_MODE_A"

# Verify the staging-deployment-check.md prompt documents Mode B (.md dispatch)
DEPLOY_CHECK_HAS_MODE_B=$(grep -c "Mode B" "$DEPLOY_CHECK_PROMPT" 2>/dev/null || echo "0")
assert_ne "staging-deployment-check.md documents Mode B (.md dispatch)" "0" "$DEPLOY_CHECK_HAS_MODE_B"

# Verify the staging-environment-test.md prompt documents Mode A (.sh dispatch)
STAGING_TEST_HAS_MODE_A=$(grep -c "Mode A" "$STAGING_TEST_PROMPT" 2>/dev/null || echo "0")
assert_ne "staging-environment-test.md documents Mode A (.sh dispatch)" "0" "$STAGING_TEST_HAS_MODE_A"

# Verify the staging-environment-test.md prompt documents Mode B (.md dispatch)
STAGING_TEST_HAS_MODE_B=$(grep -c "Mode B" "$STAGING_TEST_PROMPT" 2>/dev/null || echo "0")
assert_ne "staging-environment-test.md documents Mode B (.md dispatch)" "0" "$STAGING_TEST_HAS_MODE_B"

# Verify the .sh fixture is executable and exits 0
DEPLOY_CHECK_FIXTURE="$FIXTURES_DIR/staging-deploy-check.sh"
assert_eq "staging-deploy-check.sh fixture is executable" "true" \
    "$(test -x "$DEPLOY_CHECK_FIXTURE" && echo true || echo false)"

bash "$DEPLOY_CHECK_FIXTURE"
DEPLOY_CHECK_EXIT=$?
assert_eq "staging-deploy-check.sh fixture exits 0 (healthy)" "0" "$DEPLOY_CHECK_EXIT"

# Verify the .md fixture is readable and contains expected content
STAGING_TEST_FIXTURE="$FIXTURES_DIR/staging-test.md"
STAGING_TEST_HAS_STAGING_URL=$(grep -c "{STAGING_URL}" "$STAGING_TEST_FIXTURE" 2>/dev/null || echo "0")
assert_ne "staging-test.md fixture contains {STAGING_URL} placeholder" "0" "$STAGING_TEST_HAS_STAGING_URL"

# ---------------------------------------------------------------------------
# Test E: CI integration_workflow absent — SKIPPED behavior
# ---------------------------------------------------------------------------
echo ""
echo "--- Test E: CI integration_workflow absent — SKIPPED behavior ---"

# No-staging config also has no ci.integration_workflow
INTEGRATION_ABSENT=$(read_key "$NO_STAGING_CONFIG" "ci.integration_workflow")
assert_eq "ci.integration_workflow absent when not configured" "" "$INTEGRATION_ABSENT"

# Verify the SKILL.md documents the INTEGRATION_WORKFLOW resolution
SKILL_HAS_INTEGRATION_WORKFLOW=$(grep -c "INTEGRATION_WORKFLOW" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md reads ci.integration_workflow from config" "0" "$SKILL_HAS_INTEGRATION_WORKFLOW"

# Verify the CI sub-agent prompt references the integration workflow config value
CI_PROMPT="$PLUGIN_ROOT/skills/validate-work/prompts/ci-status.md"
assert_eq "ci-status.md prompt exists" "true" \
    "$(test -f "$CI_PROMPT" && echo true || echo false)"

CI_PROMPT_HAS_INTEGRATION=$(grep -c "INTEGRATION_WORKFLOW\|integration_workflow" "$CI_PROMPT" 2>/dev/null || echo "0")
assert_ne "ci-status.md prompt references INTEGRATION_WORKFLOW" "0" "$CI_PROMPT_HAS_INTEGRATION"

# ---------------------------------------------------------------------------
# Test F: Fixture config has valid YAML structure
# ---------------------------------------------------------------------------
echo ""
echo "--- Test F: fixture config YAML structure validation ---"

# Verify all required YAML sections are present in full config
assert_eq "full config has staging section" "true" \
    "$(grep -q '^staging:' "$FULL_CONFIG" && echo true || echo false)"

assert_eq "full config has staging.url" "true" \
    "$(grep -q 'url:' "$FULL_CONFIG" && echo true || echo false)"

assert_eq "full config has commands section" "true" \
    "$(grep -q '^commands:' "$FULL_CONFIG" && echo true || echo false)"

assert_eq "full config has ci section" "true" \
    "$(grep -q '^ci:' "$FULL_CONFIG" && echo true || echo false)"

assert_eq "full config has jira section" "true" \
    "$(grep -q '^jira:' "$FULL_CONFIG" && echo true || echo false)"

assert_eq "no-staging config has NO staging section" "false" \
    "$(grep -q '^staging:' "$NO_STAGING_CONFIG" && echo true || echo false)"

assert_eq "partial staging config has staging.url but no deploy_check" "true" \
    "$(grep -q '  url:' "$PARTIAL_CONFIG" && ! grep -q 'deploy_check:' "$PARTIAL_CONFIG" && echo true || echo false)"

# ---------------------------------------------------------------------------
# Test G: SKILL.md documents domain-by-domain report structure
# ---------------------------------------------------------------------------
echo ""
echo "--- Test G: SKILL.md documents domain-by-domain report structure ---"

# Verify the skill documents all 5 validation domains in the final report table
SKILL_HAS_LOCAL_DOMAIN=$(grep -c "Local checks" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents 'Local checks' domain in report" "0" "$SKILL_HAS_LOCAL_DOMAIN"

SKILL_HAS_CI_DOMAIN=$(grep -c "CI workflow" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents 'CI workflow' domain in report" "0" "$SKILL_HAS_CI_DOMAIN"

SKILL_HAS_ISSUES_DOMAIN=$(grep -c "Issue health" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents 'Issue health' domain in report" "0" "$SKILL_HAS_ISSUES_DOMAIN"

SKILL_HAS_STAGING_DEPLOY_DOMAIN=$(grep -c "Staging deploy" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents 'Staging deploy' domain in report" "0" "$SKILL_HAS_STAGING_DEPLOY_DOMAIN"

SKILL_HAS_STAGING_TEST_DOMAIN=$(grep -c "Staging test" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents 'Staging test' domain in report" "0" "$SKILL_HAS_STAGING_TEST_DOMAIN"

SKILL_HAS_OVERALL=$(grep -c "Overall:" "$SKILL_FILE" 2>/dev/null || echo "0")
assert_ne "SKILL.md documents Overall status in report" "0" "$SKILL_HAS_OVERALL"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
