#!/usr/bin/env bash
# tests/scripts/test-config-inference-review-validator.sh
# RED tests verifying that inference_review precondition config keys exist in
# dso-config.conf and CONFIGURATION-REFERENCE.md, and that the preconditions
# validator enforces rate_high_stakes=100 (must be exactly 100).
#
# Story: 18b0-7c5d (inference-challenge mode for red-team-reviewer)
# Testing mode: RED (new behavior — config keys and validator rules don't exist yet)
#
# Usage: bash tests/scripts/test-config-inference-review-validator.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

CONFIG="$REPO_ROOT/.claude/dso-config.conf"
CONFIG_REF="$REPO_ROOT/plugins/dso/docs/CONFIGURATION-REFERENCE.md"
PRECONDITIONS_VALIDATOR="$REPO_ROOT/plugins/dso/hooks/lib/preconditions-validator-lib.sh"

# ---------------------------------------------------------------------------
# test_rate_rationale_key_in_config
# Expect: preconditions.inference_review.rate_rationale key in dso-config.conf
# RED: key not yet present
# ---------------------------------------------------------------------------
test_rate_rationale_key_in_config() {
    if grep -q 'preconditions\.inference_review\.rate_rationale' "$CONFIG" 2>/dev/null; then
        actual=present
    else
        actual=missing
    fi
    assert_eq ".claude/dso-config.conf has preconditions.inference_review.rate_rationale key" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_rate_high_stakes_key_in_config
# Expect: preconditions.inference_review.rate_high_stakes key in dso-config.conf
# RED: key not yet present
# ---------------------------------------------------------------------------
test_rate_high_stakes_key_in_config() {
    if grep -q 'preconditions\.inference_review\.rate_high_stakes' "$CONFIG" 2>/dev/null; then
        actual=present
    else
        actual=missing
    fi
    assert_eq ".claude/dso-config.conf has preconditions.inference_review.rate_high_stakes key" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_validator_rejects_high_stakes_below_100
# Expect: preconditions validator exits non-zero when rate_high_stakes=99
# RED: validator doesn't know this rule yet (exits 0 for unknown key)
# ---------------------------------------------------------------------------
test_validator_rejects_high_stakes_below_100() {
    # First check that the preconditions validator exists — if not, fail RED immediately
    if ! test -f "$PRECONDITIONS_VALIDATOR"; then
        assert_eq "preconditions validator rejects rate_high_stakes=99 (validator missing)" \
            "present" "missing"
        return
    fi

    local tmp_config
    tmp_config=$(mktemp /tmp/dso-test-config.XXXXXX)
    printf 'preconditions.inference_review.rate_high_stakes=99\n' > "$tmp_config"

    local exit_code=0
    bash "$PRECONDITIONS_VALIDATOR" "$tmp_config" >/dev/null 2>&1 || exit_code=$?
    rm -f "$tmp_config"

    if [[ "$exit_code" -ne 0 ]]; then
        actual=rejected
    else
        actual=accepted
    fi
    assert_eq "preconditions validator rejects rate_high_stakes=99 (below minimum 100)" \
        "rejected" "$actual"
}

# ---------------------------------------------------------------------------
# test_validator_accepts_high_stakes_100
# Expect: preconditions validator exits zero when rate_high_stakes=100
# RED: validator doesn't know this rule yet
# ---------------------------------------------------------------------------
test_validator_accepts_high_stakes_100() {
    if ! test -f "$PRECONDITIONS_VALIDATOR"; then
        assert_eq "preconditions validator accepts rate_high_stakes=100 (validator missing)" \
            "present" "missing"
        return
    fi

    local tmp_config
    tmp_config=$(mktemp /tmp/dso-test-config.XXXXXX)
    printf 'preconditions.inference_review.rate_high_stakes=100\n' > "$tmp_config"

    local exit_code=0
    bash "$PRECONDITIONS_VALIDATOR" "$tmp_config" >/dev/null 2>&1 || exit_code=$?
    rm -f "$tmp_config"

    if [[ "$exit_code" -eq 0 ]]; then
        actual=accepted
    else
        actual=rejected
    fi
    assert_eq "preconditions validator accepts rate_high_stakes=100" \
        "accepted" "$actual"
}

# ---------------------------------------------------------------------------
# test_validator_rejects_high_stakes_50
# Expect: preconditions validator exits non-zero when rate_high_stakes=50
# RED: validator doesn't know this rule yet
# ---------------------------------------------------------------------------
test_validator_rejects_high_stakes_50() {
    if ! test -f "$PRECONDITIONS_VALIDATOR"; then
        assert_eq "preconditions validator rejects rate_high_stakes=50 (validator missing)" \
            "present" "missing"
        return
    fi

    local tmp_config
    tmp_config=$(mktemp /tmp/dso-test-config.XXXXXX)
    printf 'preconditions.inference_review.rate_high_stakes=50\n' > "$tmp_config"

    local exit_code=0
    bash "$PRECONDITIONS_VALIDATOR" "$tmp_config" >/dev/null 2>&1 || exit_code=$?
    rm -f "$tmp_config"

    if [[ "$exit_code" -ne 0 ]]; then
        actual=rejected
    else
        actual=accepted
    fi
    assert_eq "preconditions validator rejects rate_high_stakes=50 (below minimum 100)" \
        "rejected" "$actual"
}

# ---------------------------------------------------------------------------
# test_validator_accepts_rate_rationale_0
# Expect: preconditions validator exits zero when rate_rationale=0
# RED: validator doesn't know this rule yet
# ---------------------------------------------------------------------------
test_validator_accepts_rate_rationale_0() {
    if ! test -f "$PRECONDITIONS_VALIDATOR"; then
        assert_eq "preconditions validator accepts rate_rationale=0 (validator missing)" \
            "present" "missing"
        return
    fi

    local tmp_config
    tmp_config=$(mktemp /tmp/dso-test-config.XXXXXX)
    printf 'preconditions.inference_review.rate_rationale=0\n' > "$tmp_config"

    local exit_code=0
    bash "$PRECONDITIONS_VALIDATOR" "$tmp_config" >/dev/null 2>&1 || exit_code=$?
    rm -f "$tmp_config"

    if [[ "$exit_code" -eq 0 ]]; then
        actual=accepted
    else
        actual=rejected
    fi
    assert_eq "preconditions validator accepts rate_rationale=0 (zero is valid lower bound)" \
        "accepted" "$actual"
}

# ---------------------------------------------------------------------------
# test_configuration_reference_documents_keys
# Expect: CONFIGURATION-REFERENCE.md documents preconditions.inference_review keys
# RED: not yet documented
# ---------------------------------------------------------------------------
test_configuration_reference_documents_keys() {
    if grep -q 'preconditions\.inference_review' "$CONFIG_REF" 2>/dev/null; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "CONFIGURATION-REFERENCE.md documents preconditions.inference_review keys" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_rate_rationale_key_in_config
test_rate_high_stakes_key_in_config
test_validator_rejects_high_stakes_below_100
test_validator_accepts_high_stakes_100
test_validator_rejects_high_stakes_50
test_validator_accepts_rate_rationale_0
test_configuration_reference_documents_keys

print_summary
