#!/usr/bin/env bash
# tests/scripts/test-gha-scanner-prompt-contract.sh
#
# Structural-boundary tests for plugins/dso/skills/debug-everything/prompts/gha-scanner.md
# — the GHA scanner sub-agent prompt dispatched by Phase A (initial scan) and
# Bug-Fix Mode Between-Batch Refresh via prompts/gha-dispatch.md.
#
# Per behavioral-testing-standard Rule 5: this test asserts the prompt's
# structural CONTRACT (named error signals, schema field names, config-key
# references), NOT its prose. The deleted tests/skills/test-debug-everything-gha-scanner.sh
# mixed contract assertions (kept) with SKILL.md heading-grep change detectors (removed).
# This file restores the contract-only subset.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCANNER_MD="$REPO_ROOT/plugins/dso/skills/debug-everything/prompts/gha-scanner.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-gha-scanner-prompt-contract.sh ==="

# ── Test 1: prompt file exists and is non-empty ───────────────────────────────
echo "--- test_gha_scanner_prompt_exists ---"
if [[ -s "$SCANNER_MD" ]]; then
    assert_eq "gha-scanner.md exists and is non-empty" "exists" "exists"
else
    assert_eq "gha-scanner.md exists and is non-empty" "exists" "missing"
fi

# ── Test 2: required error signal name present ────────────────────────────────
# 'GHA scan unavailable: workflow run tools not registered' is the error signal
# that gha-dispatch.md Step 0 reads to detect tool-registration failure.
# A regression that drops or renames this signal silently breaks the scanner.
echo "--- test_gha_scanner_unavailable_signal_present ---"
if grep -q "GHA scan unavailable" "$SCANNER_MD"; then
    assert_eq "gha-scanner.md emits 'GHA scan unavailable' error signal" "found" "found"
else
    assert_eq "gha-scanner.md emits 'GHA scan unavailable' error signal" "found" "missing"
fi

# ── Test 3: compact summary schema fields present ─────────────────────────────
# The prompt MUST emit the following fields in its compact-summary JSON, which
# both Phase A and Between-Batch Refresh parse:
#   workflows_checked, tickets_created, failures_already_tracked, new_ticket_ids
# A regression that renames or omits any field breaks the orchestrator's parse.
echo "--- test_gha_scanner_summary_schema_fields ---"
for field in workflows_checked tickets_created failures_already_tracked new_ticket_ids; do
    if grep -qE "${field}" "$SCANNER_MD"; then
        assert_eq "gha-scanner.md schema field '$field' present" "found" "found"
    else
        assert_eq "gha-scanner.md schema field '$field' present" "found" "missing"
    fi
done

# ── Test 4: action_required failure conclusion documented ─────────────────────
echo "--- test_gha_scanner_action_required_present ---"
if grep -q "action_required" "$SCANNER_MD"; then
    assert_eq "gha-scanner.md includes 'action_required' failure conclusion" "found" "found"
else
    assert_eq "gha-scanner.md includes 'action_required' failure conclusion" "found" "missing"
fi

# ── Test 5: gha:<workflow> tag prefix used for dedup ──────────────────────────
echo "--- test_gha_scanner_tag_prefix_present ---"
if grep -q "gha:" "$SCANNER_MD"; then
    assert_eq "gha-scanner.md uses 'gha:' tag prefix" "found" "found"
else
    assert_eq "gha-scanner.md uses 'gha:' tag prefix" "found" "missing"
fi

# ── Test 6: dso shim path used (not bare dso) ─────────────────────────────────
echo "--- test_gha_scanner_uses_dso_shim_path ---"
if grep -q '\.claude/scripts/dso' "$SCANNER_MD"; then
    assert_eq "gha-scanner.md uses .claude/scripts/dso shim path" "found" "found"
else
    assert_eq "gha-scanner.md uses .claude/scripts/dso shim path" "found" "missing"
fi

print_summary
