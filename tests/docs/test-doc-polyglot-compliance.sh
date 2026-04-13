#!/usr/bin/env bash
# tests/docs/test-doc-polyglot-compliance.sh
#
# Polyglot documentation compliance contract tests.
#
# Verifies that multi-stack docs (REVIEW-WORKFLOW.md, DEPENDENCY-GUIDANCE.md)
# use generic/parameterized references rather than hardcoded tool invocations,
# and that DEPENDENCY-GUIDANCE.md includes audit tool entries for all supported
# language stacks.
#
# Observable behavior: docs that follow these contracts are usable across
# Python, JavaScript/TypeScript, and Ruby projects without manual editing.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"
DEPENDENCY_GUIDANCE="$REPO_ROOT/plugins/dso/docs/DEPENDENCY-GUIDANCE.md"

# ---------------------------------------------------------------------------
# test_review_workflow_config_ref_generic
#
# Verifies that the Config Reference section in REVIEW-WORKFLOW.md lists
# commands.lint and commands.type_check without hardcoded default values
# that reference Python-only tools (make lint-ruff / make lint-mypy).
#
# Observable behavior: agents reading this section understand the commands
# are configured per-project, not globally fixed to ruff/mypy.
# ---------------------------------------------------------------------------
echo "=== test_review_workflow_config_ref_generic ==="

config_ref_section="$(python3 - "$REVIEW_WORKFLOW" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Extract the Config Reference section up to the next --- separator
m = re.search(r'## Config Reference.*?(?=\n---)', content, re.DOTALL)
if m:
    print(m.group(0))
PYEOF
)"

# Validate extraction succeeded — empty string means section not found
if [[ -z "$config_ref_section" ]]; then
    (( ++FAIL ))
    printf "FAIL: Config Reference section not found in REVIEW-WORKFLOW.md — cannot validate contents\n" >&2
fi

# commands.lint must NOT default to the hardcoded Python-specific value
if echo "$config_ref_section" | grep -q 'commands\.lint.*default.*make lint-ruff'; then
    (( ++FAIL ))
    printf "FAIL: commands.lint default is not hardcoded to make lint-ruff\n  hardcoded make lint-ruff default found — must use generic reference\n" >&2
else
    (( ++PASS ))
fi

# commands.type_check must NOT default to the hardcoded Python-specific value
if echo "$config_ref_section" | grep -q 'commands\.type_check.*default.*make lint-mypy'; then
    (( ++FAIL ))
    printf "FAIL: commands.type_check default is not hardcoded to make lint-mypy\n  hardcoded make lint-mypy default found — must use generic reference\n" >&2
else
    (( ++PASS ))
fi

# Verify generic/parameterized references ARE present in the config section
if echo "$config_ref_section" | grep -qE '(configured|config|commands\.(lint|type_check))'; then
    assert_eq \
        "Config Reference section contains generic command references" \
        "present" \
        "present"
else
    assert_eq \
        "Config Reference section contains generic command references" \
        "generic command key references" \
        "no generic command references found in Config Reference section"
fi

# ---------------------------------------------------------------------------
# test_review_workflow_commands_generic
#
# Verifies that the Step 1 numbered instructions for Lint and Type check
# reference config keys (e.g., commands.lint, $commands.lint, or 'configured')
# rather than hardcoded make lint-ruff / make lint-mypy invocations.
#
# Observable behavior: agents running Step 1 will substitute the project's
# configured commands, not invoke Python-only tooling on non-Python projects.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_review_workflow_commands_generic ==="

step1_section="$(python3 - "$REVIEW_WORKFLOW" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
# Extract Step 1 section through to Step 2
m = re.search(r'## Step 1:.*?(?=## Step 2:)', content, re.DOTALL)
if m:
    print(m.group(0))
PYEOF
)"

# Validate extraction succeeded — empty string means section not found
if [[ -z "$step1_section" ]]; then
    (( ++FAIL ))
    printf "FAIL: Step 1 section not found in REVIEW-WORKFLOW.md — cannot validate contents\n" >&2
fi

# Step 1 must NOT contain hardcoded make lint-ruff
if echo "$step1_section" | grep -q 'make lint-ruff'; then
    (( ++FAIL ))
    printf "FAIL: Step 1 Lint check does not hardcode make lint-ruff\n  hardcoded make lint-ruff found in Step 1 — must reference config key\n" >&2
else
    (( ++PASS ))
fi

# Step 1 must NOT contain hardcoded make lint-mypy
if echo "$step1_section" | grep -q 'make lint-mypy'; then
    (( ++FAIL ))
    printf "FAIL: Step 1 Type check does not hardcode make lint-mypy\n  hardcoded make lint-mypy found in Step 1 — must reference config key\n" >&2
else
    (( ++PASS ))
fi

# Step 1 must reference config keys for lint and type_check
lint_key_ref="$(echo "$step1_section" | grep -cE '(commands\.lint|\$commands\.lint|configured lint|lint command)' || true)"
typecheck_key_ref="$(echo "$step1_section" | grep -cE '(commands\.type_check|\$commands\.type_check|configured type.check|type.check command)' || true)"

if [[ "${lint_key_ref:-0}" -gt 0 ]]; then
    assert_eq \
        "Step 1 references commands.lint config key for lint" \
        "present" \
        "present"
else
    assert_eq \
        "Step 1 references commands.lint config key for lint" \
        "config key reference (commands.lint or equivalent)" \
        "no config key reference found for lint in Step 1"
fi

if [[ "${typecheck_key_ref:-0}" -gt 0 ]]; then
    assert_eq \
        "Step 1 references commands.type_check config key for type check" \
        "present" \
        "present"
else
    assert_eq \
        "Step 1 references commands.type_check config key for type check" \
        "config key reference (commands.type_check or equivalent)" \
        "no config key reference found for type_check in Step 1"
fi

# ---------------------------------------------------------------------------
# test_dependency_guidance_audit_tools
#
# Verifies that DEPENDENCY-GUIDANCE.md contains a Security Audit Commands
# section with entries for all three supported language stacks.
#
# Observable behavior: developers on Python, JavaScript/TypeScript, and Ruby
# projects can find the correct audit command for their stack.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_dependency_guidance_audit_tools ==="

dep_guidance_content="$(< "$DEPENDENCY_GUIDANCE")"

# Section heading must exist
if echo "$dep_guidance_content" | grep -qE '(Security Audit Commands|Audit Commands|Audit Tools)'; then
    assert_eq \
        "DEPENDENCY-GUIDANCE.md has Security Audit Commands section" \
        "present" \
        "present"
else
    assert_eq \
        "DEPENDENCY-GUIDANCE.md has Security Audit Commands section" \
        "section heading 'Security Audit Commands' (or equivalent)" \
        "no audit commands section found"
fi

# pip-audit entry with --strict flag
if echo "$dep_guidance_content" | grep -q 'pip-audit --strict'; then
    assert_eq \
        "pip-audit entry with --strict flag present" \
        "present" \
        "present"
else
    assert_eq \
        "pip-audit entry with --strict flag present" \
        "pip-audit --strict" \
        "not found"
fi

# npm audit entry with --audit-level=moderate
if echo "$dep_guidance_content" | grep -q 'npm audit --audit-level=moderate'; then
    assert_eq \
        "npm audit entry with --audit-level=moderate present" \
        "present" \
        "present"
else
    assert_eq \
        "npm audit entry with --audit-level=moderate present" \
        "npm audit --audit-level=moderate" \
        "not found"
fi

# bundle-audit entry with check --update
if echo "$dep_guidance_content" | grep -q 'bundle-audit check --update'; then
    assert_eq \
        "bundle-audit entry with check --update present" \
        "present" \
        "present"
else
    assert_eq \
        "bundle-audit entry with check --update present" \
        "bundle-audit check --update" \
        "not found"
fi

print_summary
