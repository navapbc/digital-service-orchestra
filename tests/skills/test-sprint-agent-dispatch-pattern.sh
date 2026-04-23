#!/usr/bin/env bash
# tests/skills/test-sprint-agent-dispatch-pattern.sh
# Structural test: assert that skill files do NOT use `subagent_type: dso:*` patterns.
#
# Background (bug af02-e276): dso:* labels are agent file identifiers, NOT valid
# subagent_type values. The Agent tool only accepts built-in types (general-purpose,
# Explore, Plan). Skill files must use subagent_type: "general-purpose" with the
# named agent file loaded verbatim as the prompt.
#
# This test verifies the structural boundary for:
#   - plugins/dso/skills/sprint/SKILL.md
#   - plugins/dso/skills/fix-bug/SKILL.md
#   - plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md
#
# Usage: bash tests/skills/test-sprint-agent-dispatch-pattern.sh
# Returns: exit 0 on PASS, non-zero on FAIL

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0
FAIL=0

ok()   { echo "ok - $1"; PASS=$((PASS + 1)); }
fail() { echo "not ok - $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: assert a file does NOT contain `subagent_type: dso:*` patterns,
# excluding lines that are clearly explaining why NOT to use the pattern
# (i.e., lines containing "NOT a valid" or "file identifier" or "only accepts").
# ---------------------------------------------------------------------------
assert_no_invalid_subagent_type() {
    local file="$1"
    local label="$2"

    if [[ ! -f "$REPO_ROOT/$file" ]]; then
        fail "$label: file exists at $file"
        return
    fi

    # Find lines with `subagent_type.*dso:` that are NOT explanatory clarifications
    local bad_lines
    bad_lines=$(grep -n "subagent_type.*dso:" "$REPO_ROOT/$file" 2>/dev/null \
        | grep -v "NOT a valid\|file identifier\|NOT valid\|not a valid\|only accepts" \
        || true)

    if [[ -n "$bad_lines" ]]; then
        fail "$label: contains invalid 'subagent_type: dso:*' dispatch pattern"
        echo "  Found in $file:"
        echo "$bad_lines" | while IFS= read -r line; do
            echo "    $line"
        done
    else
        ok "$label: no invalid 'subagent_type: dso:*' dispatch patterns"
    fi
}

# ---------------------------------------------------------------------------
# Helper: assert a file DOES contain `subagent_type: "general-purpose"` (the
# correct pattern) when it dispatches named agents.
# ---------------------------------------------------------------------------
assert_has_general_purpose() {
    local file="$1"
    local label="$2"

    if [[ ! -f "$REPO_ROOT/$file" ]]; then
        fail "$label: file exists at $file"
        return
    fi

    if grep -q 'subagent_type.*general-purpose' "$REPO_ROOT/$file" 2>/dev/null; then
        ok "$label: uses subagent_type: \"general-purpose\" for named agent dispatch"
    else
        fail "$label: does not reference subagent_type: \"general-purpose\" — correct dispatch pattern missing"
    fi
}

# ---------------------------------------------------------------------------
# Test: sprint/SKILL.md
# ---------------------------------------------------------------------------
SPRINT_FILE="plugins/dso/skills/sprint/SKILL.md"

assert_no_invalid_subagent_type "$SPRINT_FILE" "sprint-SKILL.md: no invalid dso: subagent_type"
assert_has_general_purpose "$SPRINT_FILE" "sprint-SKILL.md: uses general-purpose pattern"

# Sprint SKILL.md must still reference code-reviewer dispatch via REVIEW-WORKFLOW.md,
# not by hardcoding a reviewer agent directly.
if grep -q "Do NOT dispatch any.*dso:code-reviewer" "$REPO_ROOT/$SPRINT_FILE" 2>/dev/null; then
    ok "sprint-SKILL.md: delegates code-reviewer dispatch to REVIEW-WORKFLOW.md"
else
    fail "sprint-SKILL.md: missing code-reviewer delegation guard to REVIEW-WORKFLOW.md"
fi

# ---------------------------------------------------------------------------
# Test: fix-bug/SKILL.md
# ---------------------------------------------------------------------------
FIX_BUG_FILE="plugins/dso/skills/fix-bug/SKILL.md"

assert_no_invalid_subagent_type "$FIX_BUG_FILE" "fix-bug-SKILL.md: no invalid dso: subagent_type"

# ---------------------------------------------------------------------------
# Test: debug-everything/SKILL.md — must not use non-built-in subagent_type values
# Bug af02-e276: line 981 used subagent_type="feature-dev:code-reviewer" which is
# invalid; the Agent tool only accepts built-in types (general-purpose, Explore, Plan).
# ---------------------------------------------------------------------------
DEBUG_FILE="plugins/dso/skills/debug-everything/SKILL.md"

assert_no_invalid_subagent_type "$DEBUG_FILE" "debug-everything-SKILL.md: no invalid dso: subagent_type"

# Also check that debug-everything does not use any non-built-in subagent_type
# in actual dispatch expressions (subagent_type= or subagent_type: assignment lines).
# Valid built-in types: general-purpose, Explore, Plan.
# Lines that merely reference subagent_type as prose (e.g. "select subagent_type via ...")
# are excluded by requiring an = or : assignment separator.
if [[ -f "$REPO_ROOT/$DEBUG_FILE" ]]; then
    bad_subagent=$(grep -n 'subagent_type[=:][^=]' "$REPO_ROOT/$DEBUG_FILE" 2>/dev/null \
        | grep -v '"general-purpose"\|"Explore"\|"Plan"\|NOT a valid\|file identifier\|NOT valid\|not a valid\|only accepts' \
        || true)
    if [[ -n "$bad_subagent" ]]; then
        fail "debug-everything-SKILL.md: uses non-built-in subagent_type value (must be general-purpose/Explore/Plan)"
        echo "  Found:"
        echo "$bad_subagent" | while IFS= read -r line; do echo "    $line"; done
    else
        ok "debug-everything-SKILL.md: all subagent_type dispatch values are valid built-in types"
    fi
fi

# ---------------------------------------------------------------------------
# Test: shared/workflows/epic-scrutiny-pipeline.md
# ---------------------------------------------------------------------------
SCRUTINY_FILE="plugins/dso/skills/shared/workflows/epic-scrutiny-pipeline.md"

assert_no_invalid_subagent_type "$SCRUTINY_FILE" "epic-scrutiny-pipeline.md: no invalid dso: subagent_type"

# ---------------------------------------------------------------------------
# Test: REVIEW-WORKFLOW.md uses general-purpose (canonical pattern reference)
# ---------------------------------------------------------------------------
REVIEW_FILE="plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

if [[ -f "$REPO_ROOT/$REVIEW_FILE" ]]; then
    if grep -q 'subagent_type: "general-purpose"' "$REPO_ROOT/$REVIEW_FILE" 2>/dev/null; then
        ok "REVIEW-WORKFLOW.md: canonical dispatch uses subagent_type: \"general-purpose\""
    else
        fail "REVIEW-WORKFLOW.md: canonical dispatch pattern missing"
    fi
else
    fail "REVIEW-WORKFLOW.md: file exists"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
