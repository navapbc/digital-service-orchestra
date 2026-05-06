#!/usr/bin/env bash
# tests/scripts/test-red-team-inference-comment-emission.sh
# RED tests verifying that plugins/dso/agents/red-team-reviewer.md documents
# ticket comment emission for inference-challenge decisions. Tests FAIL until
# the relevant sections are added to the agent file.
#
# Story: 18b0-7c5d (inference-challenge mode for red-team-reviewer)
# Testing mode: RED (new behavior — sections don't exist yet)
#
# Usage: bash tests/scripts/test-red-team-inference-comment-emission.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

AGENT="$REPO_ROOT/plugins/dso/agents/red-team-reviewer.md"

# ---------------------------------------------------------------------------
# test_ticket_comment_emission_section_exists
# Expect: ## Ticket Comment Emission heading present
# RED: section does not exist yet
# ---------------------------------------------------------------------------
test_ticket_comment_emission_section_exists() {
    if grep -q '^## Ticket Comment Emission' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md has '## Ticket Comment Emission' section" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_decision_id_field_documented
# Expect: decision_id field documented in agent file
# RED: not yet documented
# ---------------------------------------------------------------------------
test_decision_id_field_documented() {
    if grep -q 'decision_id' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents decision_id field" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_challenge_type_field_documented
# Expect: challenge_type field documented in agent file
# RED: not yet documented
# ---------------------------------------------------------------------------
test_challenge_type_field_documented() {
    if grep -q 'challenge_type' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents challenge_type field" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_evidence_against_inference_field_documented
# Expect: evidence_against_inference field documented in agent file
# RED: not yet documented
# ---------------------------------------------------------------------------
test_evidence_against_inference_field_documented() {
    if grep -q 'evidence_against_inference' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents evidence_against_inference field" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_user_confirmation_required_field_documented
# Expect: user_confirmation_required field documented in agent file
# RED: not yet documented
# ---------------------------------------------------------------------------
test_user_confirmation_required_field_documented() {
    if grep -q 'user_confirmation_required' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents user_confirmation_required field" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_ticket_comment_cli_referenced
# Expect: .claude/scripts/dso ticket comment CLI referenced in agent file
# RED: not yet referenced
# ---------------------------------------------------------------------------
test_ticket_comment_cli_referenced() {
    if grep -q '\.claude/scripts/dso ticket comment' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md references .claude/scripts/dso ticket comment CLI" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_decision_id_format_referenced
# Expect: decision_id format documented as session_id:content_hash or <session_id>:<content_hash>
# RED: format not yet documented
# ---------------------------------------------------------------------------
test_decision_id_format_referenced() {
    if grep -qE 'session_id.*content_hash|<session_id>:<content_hash>' "$AGENT"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "red-team-reviewer.md documents decision_id format as session_id:content_hash" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_ticket_comment_emission_section_exists
test_decision_id_field_documented
test_challenge_type_field_documented
test_evidence_against_inference_field_documented
test_user_confirmation_required_field_documented
test_ticket_comment_cli_referenced
test_decision_id_format_referenced

print_summary
