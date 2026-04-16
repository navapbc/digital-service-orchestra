#!/usr/bin/env bash
# tests/test-install-doc-contract.sh
# RED test for a7ec-b085: asserts the structural contract of root INSTALL.md
# (marketplace + prereqs + onboarding) and README.md cleanup.
#
# Verifies that:
# 1. INSTALL.md exists at repo root
# 2. INSTALL.md contains required headings: ## Prerequisites, ## Installation, ## Optional Dependencies
# 3. INSTALL.md contains the marketplace add command
# 4. INSTALL.md contains the plugin install command
# 5. INSTALL.md mentions bash 4.0 requirement
# 6. INSTALL.md mentions GNU coreutils
# 7. INSTALL.md mentions Claude Code
# 8. INSTALL.md references brew.sh
# 9. INSTALL.md links to plugins/dso/docs/CONFIGURATION-REFERENCE.md
# 10. INSTALL.md mentions /dso:onboarding with a time unit (minute or hour)
# 11. README.md does NOT contain a bare 'brew install ast-grep' block
#     (or if it does, it points to INSTALL.md)
#
# This test FAILS (RED) before INSTALL.md is created.
#
# Usage: bash tests/test-install-doc-contract.sh
# Returns: exit 0 if all assertions pass, exit 1 on first failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_MD="${REPO_ROOT}/INSTALL.md"
README_MD="${REPO_ROOT}/README.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() {
    echo "  FAIL: $1" >&2
    FAIL=$((FAIL + 1))
    # Print summary before exit so the caller sees counts
    echo ""
    echo "=== Results ==="
    echo "Passed: $PASS"
    echo "Failed: $FAIL"
    echo "VALIDATION FAILED"
    exit 1
}

echo "=== test-install-doc-contract.sh ==="
echo ""

# ── test_install_doc_contract ──────────────────────────────────────────────────
# Given: the root INSTALL.md is created as part of this epic's implementation
# When:  we inspect its structural contract
# Then:  all required sections, commands, and references are present

echo "--- test_install_doc_contract ---"

# Assertion 1: INSTALL.md exists at repo root
if [ ! -f "$INSTALL_MD" ]; then
    fail "INSTALL.md not found at repo root (${INSTALL_MD})"
fi
pass "INSTALL.md exists at repo root"

# Read content once for subsequent checks
_content="$(cat "$INSTALL_MD")"

# Assertion 2a: ## Prerequisites heading
if ! printf '%s\n' "$_content" | grep -q '^## Prerequisites'; then
    fail "INSTALL.md missing '## Prerequisites' heading"
fi
pass "INSTALL.md contains '## Prerequisites' heading"

# Assertion 2b: ## Installation heading
if ! printf '%s\n' "$_content" | grep -q '^## Installation'; then
    fail "INSTALL.md missing '## Installation' heading"
fi
pass "INSTALL.md contains '## Installation' heading"

# Assertion 2c: ## Optional Dependencies heading
if ! printf '%s\n' "$_content" | grep -q '^## Optional Dependencies'; then
    fail "INSTALL.md missing '## Optional Dependencies' heading"
fi
pass "INSTALL.md contains '## Optional Dependencies' heading"

# Assertion 3: marketplace add command
if ! printf '%s\n' "$_content" | grep -q '/plugin marketplace add navapbc/digital-service-orchestra'; then
    fail "INSTALL.md missing '/plugin marketplace add navapbc/digital-service-orchestra' command"
fi
pass "INSTALL.md contains '/plugin marketplace add navapbc/digital-service-orchestra'"

# Assertion 4: plugin install command
if ! printf '%s\n' "$_content" | grep -q '/plugin install dso@digital-service-orchestra'; then
    fail "INSTALL.md missing '/plugin install dso@digital-service-orchestra' command"
fi
pass "INSTALL.md contains '/plugin install dso@digital-service-orchestra'"

# Assertion 5: bash 4.0 requirement
if ! printf '%s\n' "$_content" | grep -qiE 'bash.*(4\.0|4\.x|version 4)|(4\.0|4\.x|version 4).*bash'; then
    fail "INSTALL.md does not mention bash 4.0 requirement"
fi
pass "INSTALL.md mentions bash 4.0 requirement"

# Assertion 6: GNU coreutils
if ! printf '%s\n' "$_content" | grep -qiE 'GNU coreutils|gnu-coreutils|coreutils'; then
    fail "INSTALL.md does not mention GNU coreutils"
fi
pass "INSTALL.md mentions GNU coreutils"

# Assertion 7: Claude Code
if ! printf '%s\n' "$_content" | grep -q 'Claude Code'; then
    fail "INSTALL.md does not mention Claude Code"
fi
pass "INSTALL.md mentions Claude Code"

# Assertion 8: brew.sh reference
if ! printf '%s\n' "$_content" | grep -qE 'brew\.sh|Homebrew|homebrew'; then
    fail "INSTALL.md does not reference brew.sh or Homebrew"
fi
pass "INSTALL.md references brew.sh / Homebrew"

# Assertion 9: link to CONFIGURATION-REFERENCE.md
if ! printf '%s\n' "$_content" | grep -q 'plugins/dso/docs/CONFIGURATION-REFERENCE.md'; then
    fail "INSTALL.md does not link to plugins/dso/docs/CONFIGURATION-REFERENCE.md"
fi
pass "INSTALL.md links to plugins/dso/docs/CONFIGURATION-REFERENCE.md"

# Assertion 10: /dso:onboarding with a time unit (minute or hour)
if ! printf '%s\n' "$_content" | grep -qiE '/dso:onboarding.*(minute|hour|min\b)|(minute|hour|min\b).*/dso:onboarding'; then
    fail "INSTALL.md does not mention /dso:onboarding with a time unit (minute or hour)"
fi
pass "INSTALL.md mentions /dso:onboarding with a time unit"

# ── test_readme_no_bare_ast_grep_block ────────────────────────────────────────
# Given: README.md is present
# When:  we inspect whether it contains a bare 'brew install ast-grep' install block
# Then:  either the pattern is absent, or if present it explicitly points to INSTALL.md
echo ""
echo "--- test_readme_no_bare_ast_grep_block ---"

if [ ! -f "$README_MD" ]; then
    # README.md doesn't exist — no violation possible
    pass "README.md not found — no bare ast-grep block to check"
else
    _readme_content="$(cat "$README_MD")"

    if printf '%s\n' "$_readme_content" | grep -q 'brew install ast-grep'; then
        # The pattern is present — check if the same vicinity references INSTALL.md
        # Extract up to 10 lines of context around the brew install ast-grep line
        _context="$(printf '%s\n' "$_readme_content" | grep -A5 -B5 'brew install ast-grep' || true)"
        if printf '%s\n' "$_context" | grep -q 'INSTALL.md'; then
            pass "README.md 'brew install ast-grep' block is co-located with INSTALL.md reference (acceptable)"
        else
            fail "README.md contains 'brew install ast-grep' without pointing to INSTALL.md — move install instructions to INSTALL.md"
        fi
    else
        pass "README.md does not contain bare 'brew install ast-grep' install block"
    fi
fi

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
