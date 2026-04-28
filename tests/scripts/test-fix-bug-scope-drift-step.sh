#!/usr/bin/env bash
# tests/scripts/test-fix-bug-scope-drift-step.sh
# Structural assertion tests for Step 7.1 scope-drift review in fix-bug/SKILL.md.
# Task A (650d-fbc0): tests start RED (Step 7.1 content does not yet exist).
# Task B (cf20-77d5): tests go GREEN after SKILL.md is updated.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Section 1: Step 7.1 exists
# ---------------------------------------------------------------------------
test_step_7_1_exists() {
    if grep -qE 'Step [0-9]+: Scope-Drift Review' "$SKILL_FILE"; then
        pass "test_step_7_1_exists"
    else
        fail "test_step_7_1_exists — 'Step 7.1' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Section 2: scope_drift.enabled config check
# ---------------------------------------------------------------------------
test_scope_drift_enabled_config_check() {
    if grep -q 'scope_drift\.enabled' "$SKILL_FILE"; then
        pass "test_scope_drift_enabled_config_check"
    else
        fail "test_scope_drift_enabled_config_check — 'scope_drift.enabled' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Section 3: hard-fail when agent file is missing
# ---------------------------------------------------------------------------
test_hard_fail_missing_agent() {
    # Accept any of: abort, hard-fail, ABORT near scope-drift-reviewer
    local context
    context=$(grep -i 'scope-drift-reviewer' "$SKILL_FILE" || true)
    if grep -qiE 'abort|hard-fail|ABORT' <<< "$context"; then
        pass "test_hard_fail_missing_agent"
    else
        fail "test_hard_fail_missing_agent — no abort/hard-fail/ABORT found near 'scope-drift-reviewer' in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Section 4: major drift prompts user
# ---------------------------------------------------------------------------
test_major_drift_user_prompt() {
    # Check that major drift and user appear near each other (within 10 lines)
    local tmpfile
    tmpfile=$(mktemp)
    grep -n -iE 'major.drift|major_drift' "$SKILL_FILE" > "$tmpfile" || true
    if [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        fail "test_major_drift_user_prompt — no major drift references found in fix-bug/SKILL.md"
        return
    fi
    # Check if 'user' appears anywhere in the SKILL.md near major drift
    local found=0
    while IFS= read -r line; do
        local lineno
        lineno=$(echo "$line" | cut -d: -f1)
        local start=$(( lineno - 10 ))
        local end=$(( lineno + 10 ))
        [ "$start" -lt 1 ] && start=1
        if sed -n "${start},${end}p" "$SKILL_FILE" | grep -qi 'user'; then
            found=1
            break
        fi
    done < "$tmpfile"
    rm -f "$tmpfile"
    if [ "$found" -eq 1 ]; then
        pass "test_major_drift_user_prompt"
    else
        fail "test_major_drift_user_prompt — 'user' not found near major drift in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Section 5: minor drift emits warning
# ---------------------------------------------------------------------------
test_minor_drift_warning() {
    # Check that minor drift and warning appear near each other (within 10 lines)
    local tmpfile
    tmpfile=$(mktemp)
    grep -n -iE 'minor.drift|minor_drift' "$SKILL_FILE" > "$tmpfile" || true
    if [ ! -s "$tmpfile" ]; then
        rm -f "$tmpfile"
        fail "test_minor_drift_warning — no minor drift references found in fix-bug/SKILL.md"
        return
    fi
    local found=0
    while IFS= read -r line; do
        local lineno
        lineno=$(echo "$line" | cut -d: -f1)
        local start=$(( lineno - 10 ))
        local end=$(( lineno + 10 ))
        [ "$start" -lt 1 ] && start=1
        if sed -n "${start},${end}p" "$SKILL_FILE" | grep -qi 'warning'; then
            found=1
            break
        fi
    done < "$tmpfile"
    rm -f "$tmpfile"
    if [ "$found" -eq 1 ]; then
        pass "test_minor_drift_warning"
    else
        fail "test_minor_drift_warning — 'warning' not found near minor drift in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Section 6: SCOPE_DRIFT_OUTPUT in escalation router section
# ---------------------------------------------------------------------------
test_scope_drift_in_escalation_router() {
    if grep -q 'SCOPE_DRIFT_OUTPUT' "$SKILL_FILE"; then
        pass "test_scope_drift_in_escalation_router"
    else
        fail "test_scope_drift_in_escalation_router — 'SCOPE_DRIFT_OUTPUT' not found in fix-bug/SKILL.md"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_step_7_1_exists
test_scope_drift_enabled_config_check
test_hard_fail_missing_agent
test_major_drift_user_prompt
test_minor_drift_warning
test_scope_drift_in_escalation_router

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
