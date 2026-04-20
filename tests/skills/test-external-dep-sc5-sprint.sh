#!/usr/bin/env bash
# tests/skills/test-external-dep-sc5-sprint.sh
# Structural boundary tests for sprint SKILL.md manual-pause handshake (task a35f-db8d).
#
# Tests that sprint SKILL.md documents:
#   1. A manual-pause handshake section distinguishing manual:awaiting_user-tagged stories
#   2. The three accepted inputs: done, done <story-id>, and skip
#   3. The verification_command execution clause
#   4. The confirmation-token audit path
#
# This test is RED until story 9e66-3e5d implements the handshake documentation.
#
# Usage: bash tests/skills/test-external-dep-sc5-sprint.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail
# Note: -e intentionally omitted — assert.sh uses arithmetic ((++FAIL)) which exits non-zero under -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-external-dep-sc5-sprint.sh ==="

if [[ ! -f "$SKILL_MD" ]]; then
    echo "FATAL: sprint SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

# Extract Phase 3.5 section content for scoped assertions
_phase35=$(awk 'flag && /^## Phase [0-9]/{exit} /^## Phase 3\.5:/{flag=1} flag' "$SKILL_MD")

# ── test_manual_pause_handshake_section_exists ────────────────────────────────
# Asserts the Phase 3.5 heading and manual:awaiting_user distinction are present
_snapshot_fail
_has=0
if echo "$_phase35" | grep -qiE "manual.pause handshake|manual:awaiting_user"; then
    _has=1
fi
assert_eq "test_manual_pause_handshake_section_exists: Phase 3.5 must contain manual-pause handshake section referencing manual:awaiting_user" "1" "$_has"
assert_pass_if_clean "test_manual_pause_handshake_section_exists"

# ── test_handshake_accepts_done_and_skip_inputs ───────────────────────────────
# Asserts all three accepted inputs are documented: done, done <story-id>, and skip
_snapshot_fail
_has_done_id=0
_has_skip=0
if grep -q "done <story-id>" "$SKILL_MD"; then
    _has_done_id=1
fi
if grep -q "handshake_outcome=skip\|\`skip\`.*mark the story" "$SKILL_MD"; then
    _has_skip=1
fi
_all_inputs=$(( _has_done_id * _has_skip ))
assert_eq "test_handshake_accepts_done_and_skip_inputs: SKILL.md must document done <story-id> and skip as accepted handshake inputs" "1" "$_all_inputs"
assert_pass_if_clean "test_handshake_accepts_done_and_skip_inputs"

# ── test_verification_command_execution_documented ────────────────────────────
# Asserts that the verification_command execution clause appears in Phase 3.5
_snapshot_fail
_has_vc=0
if echo "$_phase35" | grep -q "verification_command"; then
    _has_vc=1
fi
assert_eq "test_verification_command_execution_documented: Phase 3.5 must document the verification_command field/execution clause" "1" "$_has_vc"
assert_pass_if_clean "test_verification_command_execution_documented"

# ── test_confirmation_token_audit_path ───────────────────────────────────────
# Asserts that the confirmation-token audit path is documented in SKILL.md
_snapshot_fail
_has_token=0
if grep -qiE "confirmation.token|audit.token|MANUAL_CONFIRMATION_TOKEN" "$SKILL_MD"; then
    _has_token=1
fi
assert_eq "test_confirmation_token_audit_path: SKILL.md must document the confirmation-token audit path for manual handshake stories" "1" "$_has_token"
assert_pass_if_clean "test_confirmation_token_audit_path"

print_summary
