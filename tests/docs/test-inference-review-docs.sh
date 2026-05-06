#!/usr/bin/env bash
# tests/docs/test-inference-review-docs.sh
# Structural boundary tests for inference-review documentation sections.
# Verifies presence of config keys, contract files, and dispatch parameter
# added by epic c183-ed2a (story ec78-d60d). Per behavioral testing standard
# Rule 5: test the structural boundary, not the content.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-inference-review-docs.sh ==="

CONFIG_REF="$REPO_ROOT/plugins/dso/docs/CONFIGURATION-REFERENCE.md"
PREPLANNING_SKILL="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"
CONTRACTS_DIR="$REPO_ROOT/plugins/dso/docs/contracts"

# ── 1. CONFIGURATION-REFERENCE.md: rate_rationale key section ────────────────

test_config_ref_rate_rationale() {
    local hit
    hit=$(grep -c "preconditions\.inference_review\.rate_rationale" "$CONFIG_REF" || true)
    assert_eq "CONFIGURATION-REFERENCE.md documents preconditions.inference_review.rate_rationale" \
        "1" "$([ "$hit" -gt 0 ] && echo 1 || echo 0)"
}

# ── 2. CONFIGURATION-REFERENCE.md: rate_high_stakes key section ──────────────

test_config_ref_rate_high_stakes() {
    local hit
    hit=$(grep -c "preconditions\.inference_review\.rate_high_stakes" "$CONFIG_REF" || true)
    assert_eq "CONFIGURATION-REFERENCE.md documents preconditions.inference_review.rate_high_stakes" \
        "1" "$([ "$hit" -gt 0 ] && echo 1 || echo 0)"
}

# ── 3. CONFIGURATION-REFERENCE.md: rate_high_stakes default/floor is 100 ─────

test_config_ref_rate_high_stakes_floor_100() {
    # The section must document the floor value of 100.
    # grep -A10 captures the section lines following the heading, where
    # Default and Value rows both reference "100".
    local hit
    hit=$(grep -A10 "preconditions\.inference_review\.rate_high_stakes" "$CONFIG_REF" | grep -c "100" || true)
    assert_eq "CONFIGURATION-REFERENCE.md rate_high_stakes section contains value 100" \
        "1" "$([ "$hit" -gt 0 ] && echo 1 || echo 0)"
}

# ── 4. preplanning/SKILL.md: mode: story_review in Phase E dispatch ──────────

test_preplanning_skill_mode_story_review() {
    local hit
    hit=$(grep -c "mode: story_review" "$PREPLANNING_SKILL" || true)
    assert_eq "preplanning SKILL.md Phase E dispatch contains 'mode: story_review'" \
        "1" "$([ "$hit" -gt 0 ] && echo 1 || echo 0)"
}

# ── 5. Contract: phase1-gate-attestation.md exists ───────────────────────────

test_contract_phase1_gate_attestation_exists() {
    local file="$CONTRACTS_DIR/phase1-gate-attestation.md"
    assert_eq "plugins/dso/docs/contracts/phase1-gate-attestation.md exists" \
        "1" "$([ -f "$file" ] && echo 1 || echo 0)"
}

# ── 6. Contract: inference-recall-result.md exists ───────────────────────────

test_contract_inference_recall_result_exists() {
    local file="$CONTRACTS_DIR/inference-recall-result.md"
    assert_eq "plugins/dso/docs/contracts/inference-recall-result.md exists" \
        "1" "$([ -f "$file" ] && echo 1 || echo 0)"
}

test_config_ref_rate_rationale
test_config_ref_rate_high_stakes
test_config_ref_rate_high_stakes_floor_100
test_preplanning_skill_mode_story_review
test_contract_phase1_gate_attestation_exists
test_contract_inference_recall_result_exists

print_summary
