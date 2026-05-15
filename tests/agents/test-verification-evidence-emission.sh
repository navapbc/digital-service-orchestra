#!/usr/bin/env bash
# tests/agents/test-verification-evidence-emission.sh
# RED structural tests: each code-reviewer agent file must mention 'verification_evidence'
# in its finding schema. Tests FAIL until S2 T2 updates the agent files.
#
# Testing Mode: RED
# Becomes GREEN after: S2 T2 (add verification_evidence to all 10 agent files)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

AGENTS_DIR="$PLUGIN_ROOT/plugins/dso/agents"

# --- test_code_reviewer_light_emits_verification_evidence ---
# Fixture: reviewer flags "no error handler found" (absence claim)
# Agent must document verification_evidence in its finding schema.
echo "--- test_code_reviewer_light_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-light.md" 2>/dev/null
assert_eq "test_code_reviewer_light_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_light_emits_verification_evidence"

# --- test_code_reviewer_standard_emits_verification_evidence ---
# Fixture: reviewer flags "missing null check" (absence claim)
echo "--- test_code_reviewer_standard_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-standard.md" 2>/dev/null
assert_eq "test_code_reviewer_standard_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_standard_emits_verification_evidence"

# --- test_code_reviewer_performance_emits_verification_evidence ---
# Fixture: reviewer flags "no index exists" (absence claim)
echo "--- test_code_reviewer_performance_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-performance.md" 2>/dev/null
assert_eq "test_code_reviewer_performance_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_performance_emits_verification_evidence"

# --- test_code_reviewer_deep_arch_emits_verification_evidence ---
# Fixture: reviewer flags "pattern not implemented" (absence claim)
echo "--- test_code_reviewer_deep_arch_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-deep-arch.md" 2>/dev/null
assert_eq "test_code_reviewer_deep_arch_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_deep_arch_emits_verification_evidence"

# --- test_code_reviewer_deep_correctness_emits_verification_evidence ---
# Fixture: reviewer flags "value is absent" (absence claim)
echo "--- test_code_reviewer_deep_correctness_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-deep-correctness.md" 2>/dev/null
assert_eq "test_code_reviewer_deep_correctness_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_deep_correctness_emits_verification_evidence"

# --- test_code_reviewer_deep_hygiene_emits_verification_evidence ---
# Fixture: reviewer flags "never defined" (absence claim)
echo "--- test_code_reviewer_deep_hygiene_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-deep-hygiene.md" 2>/dev/null
assert_eq "test_code_reviewer_deep_hygiene_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_deep_hygiene_emits_verification_evidence"

# --- test_code_reviewer_deep_verification_emits_verification_evidence ---
# Fixture: reviewer flags "does not exist" (absence claim)
echo "--- test_code_reviewer_deep_verification_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-deep-verification.md" 2>/dev/null
assert_eq "test_code_reviewer_deep_verification_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_deep_verification_emits_verification_evidence"

# --- test_code_reviewer_security_red_team_emits_verification_evidence ---
# Fixture: reviewer flags "no validation present" (absence claim)
echo "--- test_code_reviewer_security_red_team_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-security-red-team.md" 2>/dev/null
assert_eq "test_code_reviewer_security_red_team_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_security_red_team_emits_verification_evidence"

# --- test_code_reviewer_security_blue_team_emits_verification_evidence ---
# Fixture: reviewer flags "lacks sanitization" (absence claim)
echo "--- test_code_reviewer_security_blue_team_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-security-blue-team.md" 2>/dev/null
assert_eq "test_code_reviewer_security_blue_team_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_security_blue_team_emits_verification_evidence"

# --- test_code_reviewer_test_quality_emits_verification_evidence ---
# Fixture: reviewer flags "untested path" (absence claim)
echo "--- test_code_reviewer_test_quality_emits_verification_evidence ---"
_snapshot_fail
grep -q "verification_evidence" "$AGENTS_DIR/code-reviewer-test-quality.md" 2>/dev/null
assert_eq "test_code_reviewer_test_quality_emits_verification_evidence: field in schema" "0" "$?"
assert_pass_if_clean "test_code_reviewer_test_quality_emits_verification_evidence"

print_summary
