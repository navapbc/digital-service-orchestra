#!/usr/bin/env bash
# RED tests: validate-work staging tests and prompts must use @playwright/cli, not MCP tools.
# All tests are intentionally failing (RED) until the CLI migration is complete.
# Tracked by ticket 313e-f739 (parent: 1989-08eb).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/validate-work/SKILL.md"
STAGING_PROMPT="${REPO_ROOT}/plugins/dso/skills/validate-work/prompts/staging-environment-test.md"
PLAYWRIGHT_VERIFICATION="${REPO_ROOT}/plugins/dso/skills/validate-work/prompts/playwright-verification.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ──────────────────────────────────────────────────────────────────────────────
test_validate_work_no_mcp_tools() {
    SECTION="test_validate_work_no_mcp_tools"
    # Sub-agent 5 (Staging Environment Test) section in SKILL.md must not reference
    # browser_* MCP tool names.

    _sa5_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Extract Sub-Agent 5 block through to next ### heading or end of file
match = re.search(r'(?m)(#### Sub-Agent 5:.*?)(?=^####|^###\s|\Z)', content, re.DOTALL)
if match:
    print(match.group(1))
EOF
    ) || true

    if [ -z "$_sa5_section" ]; then
        fail "SKILL.md missing Sub-Agent 5 section — cannot verify MCP tool absence"
    else
        pass "SKILL.md has Sub-Agent 5 section"
    fi

    # Must NOT contain browser_* MCP tool references
    _mcp_refs=$(echo "$_sa5_section" | grep -oE 'browser_[a-z_]+' | sort -u || true)
    if [ -n "$_mcp_refs" ]; then
        fail "Sub-Agent 5 in SKILL.md references MCP tools (must use @playwright/cli instead): $_mcp_refs"
    else
        pass "Sub-Agent 5 section does not directly reference browser_* MCP tools"
    fi

    # The Step 2b note must not reference browser_snapshot or Playwright MCP.
    _step2b=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

match = re.search(r'(?m)(### Step 2b:.*?)(?=^###\s|\Z)', content, re.DOTALL)
if match:
    print(match.group(1))
EOF
    ) || true

    if grep -qE 'browser_snapshot|browser_run_code|browser_navigate|Playwright MCP' <<< "$_step2b"; then
        fail "SKILL.md Step 2b still references Playwright MCP tools (browser_snapshot etc.) — must be migrated to @playwright/cli"
    else
        pass "SKILL.md Step 2b does not reference Playwright MCP tools"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
test_staging_prompt_uses_cli() {
    SECTION="test_staging_prompt_uses_cli"
    # staging-environment-test.md must use @playwright/cli commands (npx playwright test,
    # npx playwright screenshot, etc.) and must NOT reference MCP browser_* tools.

    # Check for MCP tool usage — these must be absent after migration
    _mcp_in_staging=$(grep -oE 'browser_[a-z_]+' "$STAGING_PROMPT" | sort -u || true)
    if [ -n "$_mcp_in_staging" ]; then
        fail "staging-environment-test.md references MCP tools (must use @playwright/cli): $_mcp_in_staging"
    else
        pass "staging-environment-test.md does not reference browser_* MCP tools"
    fi

    # Must reference @playwright/cli or npx playwright commands after migration
    if grep -qE '@playwright/cli|npx playwright|playwright test|playwright screenshot' "$STAGING_PROMPT"; then
        pass "staging-environment-test.md references @playwright/cli CLI commands"
    else
        fail "staging-environment-test.md missing @playwright/cli / npx playwright references — CLI migration incomplete"
    fi

    # Pre-flight check: prompt must include a CLI availability check before running tests
    if grep -qiE 'pre.?flight|which playwright|playwright.*--version|command.*playwright|playwright.*installed' "$STAGING_PROMPT"; then
        pass "staging-environment-test.md includes Playwright CLI pre-flight availability check"
    else
        fail "staging-environment-test.md missing CLI pre-flight check (e.g. 'which playwright' or 'playwright --version')"
    fi

    # Output validation: prompt must document how to interpret CLI exit codes / output
    if grep -qiE 'exit.*code|exit_code|PASS.*FAIL|output.*validation|test.*result|passed.*failed' "$STAGING_PROMPT"; then
        pass "staging-environment-test.md documents CLI output validation / exit code interpretation"
    else
        fail "staging-environment-test.md missing CLI output validation section (exit codes or pass/fail parsing)"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
test_playwright_verification_uses_cli() {
    SECTION="test_playwright_verification_uses_cli"
    # validate-work/prompts/playwright-verification.md must use @playwright/cli, not MCP tools.

    # Check for MCP tool usage — must be absent after migration
    _mcp_in_verification=$(grep -oE 'browser_[a-z_]+' "$PLAYWRIGHT_VERIFICATION" | sort -u || true)
    if [ -n "$_mcp_in_verification" ]; then
        fail "playwright-verification.md references MCP tools (must use @playwright/cli): $_mcp_in_verification"
    else
        pass "playwright-verification.md does not reference browser_* MCP tools"
    fi

    # Must reference CLI commands after migration
    if grep -qE '@playwright/cli|npx playwright|playwright test|playwright screenshot' "$PLAYWRIGHT_VERIFICATION"; then
        pass "playwright-verification.md references @playwright/cli CLI commands"
    else
        fail "playwright-verification.md missing @playwright/cli / npx playwright references — CLI migration incomplete"
    fi

    # Tiered approach must still be documented using CLI tiers (not MCP tiers)
    if grep -qiE 'tier|tier.*1|tier.*2|tier.*3|Tier 1|Tier 2|Tier 3' "$PLAYWRIGHT_VERIFICATION"; then
        pass "playwright-verification.md retains tiered approach documentation"
    else
        fail "playwright-verification.md missing tiered verification approach after CLI migration"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
test_preflight_and_validation() {
    SECTION="test_preflight_and_validation"
    # Both prompt files must include: (1) a CLI pre-flight check and (2) output validation guidance.

    # --- staging-environment-test.md ---
    _staging_has_preflight=false
    _staging_has_validation=false

    if grep -qiE 'pre.?flight|which playwright|playwright.*--version|command.*v.*playwright|npx playwright.*--version' "$STAGING_PROMPT"; then
        _staging_has_preflight=true
    fi

    if grep -qiE 'exit.*[0-9]|exit_code|test.*passed|test.*failed|PASS|FAIL|output.*parsed|parse.*output' "$STAGING_PROMPT"; then
        _staging_has_validation=true
    fi

    if $_staging_has_preflight; then
        pass "staging-environment-test.md: CLI pre-flight check present"
    else
        fail "staging-environment-test.md: CLI pre-flight check absent (add 'which playwright' or equivalent)"
    fi

    if $_staging_has_validation; then
        pass "staging-environment-test.md: output validation guidance present"
    else
        fail "staging-environment-test.md: output validation guidance absent (document exit codes or pass/fail parsing)"
    fi

    # --- playwright-verification.md ---
    _verification_has_preflight=false
    _verification_has_validation=false

    if grep -qiE 'pre.?flight|which playwright|playwright.*--version|command.*v.*playwright|npx playwright.*--version' "$PLAYWRIGHT_VERIFICATION"; then
        _verification_has_preflight=true
    fi

    if grep -qiE 'exit.*[0-9]|exit_code|test.*passed|test.*failed|PASS|FAIL|output.*parsed|parse.*output|RESOLVED|STILL_PRESENT' "$PLAYWRIGHT_VERIFICATION"; then
        _verification_has_validation=true
    fi

    if $_verification_has_preflight; then
        pass "playwright-verification.md: CLI pre-flight check present"
    else
        fail "playwright-verification.md: CLI pre-flight check absent (add 'which playwright' or equivalent)"
    fi

    if $_verification_has_validation; then
        pass "playwright-verification.md: output validation guidance present"
    else
        fail "playwright-verification.md: output validation guidance absent"
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Run all test functions
echo "=== test_validate_work_no_mcp_tools ==="
test_validate_work_no_mcp_tools

echo ""
echo "=== test_staging_prompt_uses_cli ==="
test_staging_prompt_uses_cli

echo ""
echo "=== test_playwright_verification_uses_cli ==="
test_playwright_verification_uses_cli

echo ""
echo "=== test_preflight_and_validation ==="
test_preflight_and_validation

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
