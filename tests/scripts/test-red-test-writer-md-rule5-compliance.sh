#!/usr/bin/env bash
# tests/scripts/test-red-test-writer-md-rule5-compliance.sh
# Structural tests for cabc-c177 and f913-1010:
#
#   cabc-c177: dso:red-test-writer generates existence-only or body-text grep
#     assertions for .md instruction files instead of section-heading checks,
#     violating behavioral testing standard Rule 5.
#     Fix: agent guidance must explicitly distinguish section-heading checks
#     (allowed) from existence-only/body-text checks (prohibited) for .md files.
#
#   f913-1010: dso:red-test-writer creates tests but does not append RED marker
#     entries to .test-index. Fix: agent guidance must have an explicit
#     verification gate before emitting TEST_RESULT:written.
#
# Per behavioral testing standard Rule 5: test the structural boundary of
# the instruction file (section headings), not its content.
#
# Usage: bash tests/scripts/test-red-test-writer-md-rule5-compliance.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/red-test-writer.md"

source "$REPO_ROOT/tests/lib/assert.sh"

if [[ ! -f "$AGENT_FILE" ]]; then
    echo "SKIP: red-test-writer.md not found at $AGENT_FILE"
    exit 0
fi

# ============================================================
# test_agent_has_rule5_md_section (cabc-c177)
#
# The agent must have an explicit section addressing Rule 5 for .md
# instruction files. This section teaches the agent that section-heading
# checks (grep -q '^## ') are the correct structural boundary assertion,
# while existence-only and body-text grep assertions are prohibited.
#
# The section heading is the structural contract — testing for it is allowed.
# ============================================================
test_agent_has_rule5_md_section() {
    local found=0
    grep -q '^### Rule 5' "$AGENT_FILE" 2>/dev/null && found=1 || true
    assert_eq "agent has Rule 5 section heading (cabc-c177)" "1" "$found"
}

# ============================================================
# test_agent_allows_section_heading_checks (cabc-c177)
#
# The agent guidance must explicitly identify section-heading grep
# (grep -q '^## ' or grep -q '^### ') as the ALLOWED pattern for .md files.
# This prevents the agent from treating ALL grep assertions on .md files
# as prohibited (the current incorrect over-broad prohibition).
# ============================================================
test_agent_allows_section_heading_checks() {
    local found=0
    grep -q "section.heading\|heading.*grep\|grep.*'\^##\|grep.*\"\^##\|grep.*\^\#" "$AGENT_FILE" 2>/dev/null && found=1 || true
    assert_eq "agent guidance allows section-heading grep for .md files (cabc-c177)" "1" "$found"
}

# ============================================================
# test_agent_prohibits_body_text_grep_on_md (cabc-c177)
#
# The agent must explicitly prohibit body-text phrase checks on .md files.
# The guidance must distinguish "grep for body text" (prohibited) from
# "grep for section heading" (allowed).
# ============================================================
test_agent_prohibits_body_text_grep_on_md() {
    local found=0
    grep -qi "body.text\|phrase.*check\|body.*phrase\|content.*assert" "$AGENT_FILE" 2>/dev/null && found=1 || true
    assert_eq "agent guidance prohibits body-text/phrase grep for .md files (cabc-c177)" "1" "$found"
}

# ============================================================
# test_agent_test_index_gate_before_result (f913-1010)
#
# The agent must verify the .test-index RED marker was written BEFORE
# emitting TEST_RESULT:written. The guidance must have an explicit gate:
# run the verification grep and confirm it produces non-empty output.
# ============================================================
test_agent_test_index_gate_before_result() {
    local found=0
    grep -q 'grep.*\[.*\].*\.test-index\|verify.*marker\|confirm.*marker\|marker.*written\|gate.*test-index\|test-index.*gate' "$AGENT_FILE" 2>/dev/null && found=1 || true
    assert_eq "agent has .test-index marker verification gate before TEST_RESULT:written (f913-1010)" "1" "$found"
}

# ============================================================
# test_agent_test_index_update_is_mandatory (f913-1010)
#
# The guidance must explicitly state that emitting TEST_RESULT:written
# without the .test-index RED marker present will cause a commit block.
# The word "MANDATORY" or equivalent must appear near the .test-index update.
# ============================================================
test_agent_test_index_update_is_mandatory() {
    local found=0
    grep -q 'MANDATORY\|mandatory\|MUST.*test-index\|test-index.*MUST\|Do NOT emit.*test-index\|until.*test-index' "$AGENT_FILE" 2>/dev/null && found=1 || true
    assert_eq "agent guidance marks .test-index update as mandatory (f913-1010)" "1" "$found"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_agent_has_rule5_md_section
test_agent_allows_section_heading_checks
test_agent_prohibits_body_text_grep_on_md
test_agent_test_index_gate_before_result
test_agent_test_index_update_is_mandatory

print_summary
