#!/usr/bin/env bash
# tests/docs/test-doc-polyglot-compliance.sh
# RED test for fa27-74aa: documentation polyglot compliance contract.
#
# Verifies that:
# 1. REVIEW-WORKFLOW.md Config Reference section does NOT contain 'make lint-ruff'
#    or 'make lint-mypy' as default values; generic/parameterized references ARE present.
# 2. REVIEW-WORKFLOW.md Step 1 Lint check and Type check items do NOT contain
#    hardcoded 'make lint-ruff'/'make lint-mypy'; DO contain config key references.
# 3. DEPENDENCY-GUIDANCE.md contains an audit tools section with entries for
#    pip-audit --strict, npm audit --audit-level=moderate, bundle-audit check --update.
#
# This test FAILS (RED) on the current codebase because REVIEW-WORKFLOW.md still
# contains 'make lint-ruff'/'make lint-mypy' and DEPENDENCY-GUIDANCE.md has no
# audit tools section.
#
# Usage: bash tests/docs/test-doc-polyglot-compliance.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"
DEPENDENCY_GUIDANCE="$REPO_ROOT/plugins/dso/docs/DEPENDENCY-GUIDANCE.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-doc-polyglot-compliance.sh ==="
echo ""

# ── test_review_workflow_config_ref_generic ───────────────────────────────────
# REVIEW-WORKFLOW.md Config Reference section must NOT specify 'make lint-ruff'
# or 'make lint-mypy' as defaults for commands.lint or commands.type_check.
# Generic/parameterized config key references MUST be present.
echo "--- test_review_workflow_config_ref_generic ---"
_snapshot_fail

# Extract the Config Reference section (lines from "## Config Reference" up to the next "## " heading)
_config_section=$(awk '/^## Config Reference/{found=1; next} found && /^## /{exit} found{print}' "$REVIEW_WORKFLOW" 2>/dev/null || true)

# Assert: commands.lint default must NOT be 'make lint-ruff'
_has_lint_ruff_default=0
if echo "$_config_section" | grep -q 'commands\.lint.*make lint-ruff'; then
    _has_lint_ruff_default=1
fi
assert_eq "test_review_workflow_config_ref_generic: commands.lint default must NOT be 'make lint-ruff'" \
    "0" "$_has_lint_ruff_default"

# Assert: commands.type_check default must NOT be 'make lint-mypy'
_has_mypy_default=0
if echo "$_config_section" | grep -q 'commands\.type_check.*make lint-mypy'; then
    _has_mypy_default=1
fi
assert_eq "test_review_workflow_config_ref_generic: commands.type_check default must NOT be 'make lint-mypy'" \
    "0" "$_has_mypy_default"

# Assert: generic/parameterized config key references ARE present (e.g., commands.lint, commands.type_check)
_has_generic_lint_ref=0
if echo "$_config_section" | grep -qE 'commands\.(lint|type_check)'; then
    _has_generic_lint_ref=1
fi
assert_eq "test_review_workflow_config_ref_generic: Config Reference section must contain generic config key references" \
    "1" "$_has_generic_lint_ref"

assert_pass_if_clean "test_review_workflow_config_ref_generic"

# ── test_review_workflow_commands_generic ─────────────────────────────────────
# REVIEW-WORKFLOW.md Step 1 Lint check and Type check items must NOT contain
# hardcoded 'make lint-ruff'/'make lint-mypy'. They MUST reference config keys
# (e.g., '$commands.lint', 'commands.lint', or 'configured lint command').
echo ""
echo "--- test_review_workflow_commands_generic ---"
_snapshot_fail

# Extract Step 1 section (lines from "## Step 1:" up to next "## Step " heading)
_step1_section=$(awk '/^## Step 1:/{found=1; next} found && /^## Step /{exit} found{print}' "$REVIEW_WORKFLOW" 2>/dev/null || true)

# Assert: Step 1 Lint check item must NOT hardcode 'make lint-ruff'
_step1_has_lint_ruff=0
if echo "$_step1_section" | grep -qE '\*\*Lint check\*\*.*make lint-ruff|Lint check.*make lint-ruff'; then
    _step1_has_lint_ruff=1
fi
assert_eq "test_review_workflow_commands_generic: Step 1 Lint check must NOT hardcode 'make lint-ruff'" \
    "0" "$_step1_has_lint_ruff"

# Assert: Step 1 Type check item must NOT hardcode 'make lint-mypy'
_step1_has_type_mypy=0
if echo "$_step1_section" | grep -qE '\*\*Type check\*\*.*make lint-mypy|Type check.*make lint-mypy'; then
    _step1_has_type_mypy=1
fi
assert_eq "test_review_workflow_commands_generic: Step 1 Type check must NOT hardcode 'make lint-mypy'" \
    "0" "$_step1_has_type_mypy"

# Assert: Step 1 must reference config keys for lint and type-check
_step1_has_config_refs=0
if echo "$_step1_section" | grep -qE 'commands\.(lint|type_check)|\$\{?commands\.(lint|type_check)|configured.*lint|configured.*type_check|lint command.*config|type_check command.*config'; then
    _step1_has_config_refs=1
fi
assert_eq "test_review_workflow_commands_generic: Step 1 must reference config keys for lint/type-check" \
    "1" "$_step1_has_config_refs"

assert_pass_if_clean "test_review_workflow_commands_generic"

# ── test_dependency_guidance_audit_tools ─────────────────────────────────────
# DEPENDENCY-GUIDANCE.md must contain a Security Audit Commands section (or
# equivalent heading). The section must include entries for all three tools:
#   (a) pip-audit with 'pip-audit --strict'
#   (b) npm audit with 'npm audit --audit-level=moderate'
#   (c) bundle-audit with 'bundle-audit check --update'
echo ""
echo "--- test_dependency_guidance_audit_tools ---"
_snapshot_fail

# Assert: audit tools heading exists
_has_audit_section=0
if grep -qiE '^#.*[Ss]ecurity [Aa]udit|^#.*[Aa]udit [Cc]ommand|^#.*[Aa]udit [Tt]ool' "$DEPENDENCY_GUIDANCE" 2>/dev/null; then
    _has_audit_section=1
fi
assert_eq "test_dependency_guidance_audit_tools: DEPENDENCY-GUIDANCE.md must contain a Security Audit Commands section" \
    "1" "$_has_audit_section"

# Extract audit section content for tool-specific assertions
_audit_section=$(awk '/^#.*[Ss]ecurity [Aa]udit|^#.*[Aa]udit [Cc]ommand|^#.*[Aa]udit [Tt]ool/{found=1; next} found && /^# /{exit} found{print}' "$DEPENDENCY_GUIDANCE" 2>/dev/null || true)

# Assert: pip-audit --strict is present
_has_pip_audit=0
if grep -q 'pip-audit --strict' "$DEPENDENCY_GUIDANCE" 2>/dev/null; then
    _has_pip_audit=1
fi
assert_eq "test_dependency_guidance_audit_tools: must contain 'pip-audit --strict'" \
    "1" "$_has_pip_audit"

# Assert: npm audit --audit-level=moderate is present
_has_npm_audit=0
if grep -q 'npm audit --audit-level=moderate' "$DEPENDENCY_GUIDANCE" 2>/dev/null; then
    _has_npm_audit=1
fi
assert_eq "test_dependency_guidance_audit_tools: must contain 'npm audit --audit-level=moderate'" \
    "1" "$_has_npm_audit"

# Assert: bundle-audit check --update is present
_has_bundle_audit=0
if grep -q 'bundle-audit check --update' "$DEPENDENCY_GUIDANCE" 2>/dev/null; then
    _has_bundle_audit=1
fi
assert_eq "test_dependency_guidance_audit_tools: must contain 'bundle-audit check --update'" \
    "1" "$_has_bundle_audit"

assert_pass_if_clean "test_dependency_guidance_audit_tools"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
