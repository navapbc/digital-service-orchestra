#!/usr/bin/env bash
# tests/scripts/test-reviewer-agent-review-tier.sh
#
# Behavioral boundary: every compiled code-reviewer agent file must call
# write-reviewer-findings.sh with --review-tier <tier> so that reviewer-findings.json
# contains the review_tier field, allowing record-review.sh to verify tier compliance.
#
# Without --review-tier, record-review.sh prints:
#   WARNING: review_tier missing or empty in reviewer-findings.json
# on every review invocation (Bug f986-c1f1).

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
AGENTS_DIR="$DSO_PLUGIN_DIR/agents"

# ── test harness ──────────────────────────────────────────────────────────────
_PASS=0
_FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $label"
        (( _PASS++ )) || true
    else
        echo "FAIL: $label"
        echo "  expected: '$expected'"
        echo "  actual:   '$actual'"
        (( _FAIL++ )) || true
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "PASS: $label"
        (( _PASS++ )) || true
    else
        echo "FAIL: $label"
        echo "  expected substring: '$needle'"
        echo "  in: '$haystack'"
        (( _FAIL++ )) || true
    fi
}

echo "=== test-reviewer-agent-review-tier.sh ==="

# ── test_compiled_agents_have_review_tier_flag ──────────────────────────────
# Each compiled code-reviewer-*.md agent file must call write-reviewer-findings.sh
# with --review-tier. This ensures the review_tier field is injected into
# reviewer-findings.json, eliminating the "review_tier missing" WARNING.
echo ""
echo "--- test_compiled_agents_have_review_tier_flag ---"

_all_have_tier=1
for agent_file in "$AGENTS_DIR"/code-reviewer-*.md; do
    [[ -f "$agent_file" ]] || continue
    agent_name=$(basename "$agent_file" .md)
    # Check that the write-reviewer-findings.sh invocation includes --review-tier
    if grep -q "write-reviewer-findings\.sh" "$agent_file"; then
        if grep "write-reviewer-findings\.sh" "$agent_file" | grep -q "\-\-review-tier"; then
            echo "PASS: $agent_name has --review-tier in write-reviewer-findings.sh call"
            (( _PASS++ )) || true
        else
            echo "FAIL: $agent_name missing --review-tier in write-reviewer-findings.sh call"
            (( _FAIL++ )) || true
            _all_have_tier=0
        fi
    fi
done

# ── test_reviewer_base_template_has_tier_placeholder ────────────────────────
# The reviewer-base.md template must reference review tier injection so future
# agent rebuilds also include --review-tier.
echo ""
echo "--- test_reviewer_base_template_has_tier_placeholder ---"

BASE_FILE="$DSO_PLUGIN_DIR/docs/workflows/prompts/reviewer-base.md"
_base_has_tier=0
if grep -q "review-tier\|CANONICAL_TIER\|_REVIEW_TIER" "$BASE_FILE" 2>/dev/null; then
    _base_has_tier=1
fi
assert_eq "reviewer-base.md references review tier" "1" "$_base_has_tier"

# ── test_build_review_agents_injects_tier ───────────────────────────────────
# build-review-agents.sh must inject the canonical tier into generated agents.
echo ""
echo "--- test_build_review_agents_injects_tier ---"

BUILD_SCRIPT="$DSO_PLUGIN_DIR/scripts/build-review-agents.sh"
_build_has_tier=0
if grep -q "review-tier\|CANONICAL_TIER\|canonical_tier" "$BUILD_SCRIPT" 2>/dev/null; then
    _build_has_tier=1
fi
assert_eq "build-review-agents.sh handles tier injection" "1" "$_build_has_tier"

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Results: $_PASS passed, $_FAIL failed"
if [[ $_FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
