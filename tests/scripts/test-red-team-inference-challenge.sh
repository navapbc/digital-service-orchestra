#!/usr/bin/env bash
# tests/scripts/test-red-team-inference-challenge.sh
# RED tests verifying that plugins/dso/agents/red-team-reviewer.md will have
# an inference-challenge mode section. All tests FAIL until the sections are added.
#
# Story: 18b0-7c5d (inference-challenge mode for red-team-reviewer)
# Testing mode: RED (new behavior — sections don't exist yet)
#
# Usage: bash tests/scripts/test-red-team-inference-challenge.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

AGENT="$REPO_ROOT/plugins/dso/agents/red-team-reviewer.md"

# ---------------------------------------------------------------------------
# test_inference_challenge_mode_section_exists
# Expect: ## Inference-Challenge Mode heading present in agent file
# RED: section does not exist yet
# ---------------------------------------------------------------------------
test_inference_challenge_mode_section_exists() {
    if grep -q '^## Inference-Challenge Mode' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md has '## Inference-Challenge Mode' section" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_output_inference_challenge_section_exists
# Expect: ## Output: INFERENCE_CHALLENGE heading present
# RED: section does not exist yet
# ---------------------------------------------------------------------------
test_output_inference_challenge_section_exists() {
    if grep -q '^## Output: INFERENCE_CHALLENGE' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md has '## Output: INFERENCE_CHALLENGE' section" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_output_inference_skip_section_exists
# Expect: ## Output: INFERENCE_SKIP heading present
# RED: section does not exist yet
# ---------------------------------------------------------------------------
test_output_inference_skip_section_exists() {
    if grep -q '^## Output: INFERENCE_SKIP' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md has '## Output: INFERENCE_SKIP' section" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_sampling_tiers_section_exists
# Expect: ## Sampling Tiers heading present
# RED: section does not exist yet
# ---------------------------------------------------------------------------
test_sampling_tiers_section_exists() {
    if grep -q '^## Sampling Tiers' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md has '## Sampling Tiers' section" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_never_silence_constraint_present
# Expect: agent documents a "never silence" constraint
# RED: constraint not yet documented
# ---------------------------------------------------------------------------
test_never_silence_constraint_present() {
    if grep -qiE 'never silence|never.*silence' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents 'never silence' constraint" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_inference_skip_reason_sampling_documented
# Expect: INFERENCE_SKIP output documents a reason field related to sampling
# RED: not yet documented
# ---------------------------------------------------------------------------
test_inference_skip_reason_sampling_documented() {
    if grep -qE 'reason.*sampling|sampling.*reason' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents reason/sampling field in INFERENCE_SKIP" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_inference_skip_hash_bucket_documented
# Expect: hash_bucket field documented in agent file
# RED: not yet documented
# ---------------------------------------------------------------------------
test_inference_skip_hash_bucket_documented() {
    if grep -q 'hash_bucket' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents hash_bucket field" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_inference_challenge_mode_section_exists
test_output_inference_challenge_section_exists
test_output_inference_skip_section_exists
test_sampling_tiers_section_exists
test_never_silence_constraint_present
test_inference_skip_reason_sampling_documented
test_inference_skip_hash_bucket_documented

print_summary
