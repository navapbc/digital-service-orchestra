#!/usr/bin/env bash
# tests/agents/test-code-reviewer-verifier-agent.sh
# RED structural tests for code-reviewer-verifier.md
# Testing Mode: RED — fails until S3 T2 creates the agent file

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

VERIFIER_AGENT="$PLUGIN_ROOT/plugins/dso/agents/code-reviewer-verifier.md"

# test_verifier_agent_file_exists
echo "--- test_verifier_agent_file_exists ---"
_snapshot_fail
_agent_exists="missing"
[[ -f "$VERIFIER_AGENT" ]] && _agent_exists="present"
assert_eq "test_verifier_agent_file_exists: file exists" "present" "$_agent_exists"
assert_pass_if_clean "test_verifier_agent_file_exists"

# test_verifier_ruling_schema_confirm_downgrade_drop
# Ruling field must document all 3 values: confirm, downgrade-to-minor, drop
echo "--- test_verifier_ruling_schema_confirm_downgrade_drop ---"
_snapshot_fail
grep -q "confirm" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_ruling_schema_confirm_downgrade_drop: 'confirm' value present" "0" "$?"
grep -q "downgrade-to-minor" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_ruling_schema_confirm_downgrade_drop: 'downgrade-to-minor' value present" "0" "$?"
grep -q "drop" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_ruling_schema_confirm_downgrade_drop: 'drop' value present" "0" "$?"
assert_pass_if_clean "test_verifier_ruling_schema_confirm_downgrade_drop"

# test_verifier_fingerprint_schema_format
# Fingerprint format: <path>:<line-start>-<line-end>
echo "--- test_verifier_fingerprint_schema_format ---"
_snapshot_fail
grep -q "fingerprint" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_fingerprint_schema_format: 'fingerprint' field documented" "0" "$?"
assert_pass_if_clean "test_verifier_fingerprint_schema_format"

# test_verifier_fingerprint_zero_sentinel
# 0-0 sentinel for missing line anchor
echo "--- test_verifier_fingerprint_zero_sentinel ---"
_snapshot_fail
grep -q "0-0" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_fingerprint_zero_sentinel: '0-0' sentinel documented" "0" "$?"
assert_pass_if_clean "test_verifier_fingerprint_zero_sentinel"

# test_verifier_rubric_defer_on_uncertainty
# Fixture: genuine ambiguity (borderline case) — agent must document defer/uncertain handling
echo "--- test_verifier_rubric_defer_on_uncertainty ---"
_snapshot_fail
grep -qE "defer|uncertain|ambiguous" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_rubric_defer_on_uncertainty: defer/uncertain handling documented" "0" "$?"
assert_pass_if_clean "test_verifier_rubric_defer_on_uncertainty"

# test_verifier_fail_open_on_failure
# verifier_status: failed fail-open behavior documented
echo "--- test_verifier_fail_open_on_failure ---"
_snapshot_fail
grep -q "verifier_status" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_fail_open_on_failure: 'verifier_status' field documented" "0" "$?"
grep -q "failed" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_fail_open_on_failure: 'failed' status value documented" "0" "$?"
assert_pass_if_clean "test_verifier_fail_open_on_failure"

# test_verifier_brainstorm_probe_clear_contradiction
# Fixture: diff shows 'if err != nil { return err }' but finding claims "no error handling found"
# Agent must instruct DROP for clear contradictions
echo "--- test_verifier_brainstorm_probe_clear_contradiction ---"
_snapshot_fail
grep -qiE "contradict|drop.*false|false.*positive" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_brainstorm_probe_clear_contradiction: contradiction handling documented" "0" "$?"
assert_pass_if_clean "test_verifier_brainstorm_probe_clear_contradiction"

# test_verifier_brainstorm_probe_authoritative_tone
# Fixture: finding says "input is never validated" with high certainty, but validate() exists
# Agent must instruct DROP for verifiable false claims
echo "--- test_verifier_brainstorm_probe_authoritative_tone ---"
_snapshot_fail
grep -qiE "authoritative|certainty|verif" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_brainstorm_probe_authoritative_tone: authoritative-tone handling documented" "0" "$?"
assert_pass_if_clean "test_verifier_brainstorm_probe_authoritative_tone"

# test_verifier_brainstorm_probe_genuine_ambiguity_confirms
# Fixture: diff adds a function, unclear if it replaces or supplements validation
# Agent must instruct CONFIRM (let autonomous-resolution loop handle)
echo "--- test_verifier_brainstorm_probe_genuine_ambiguity_confirms ---"
_snapshot_fail
grep -qiE "confirm|genuine.ambiguity|borderline" "$VERIFIER_AGENT" 2>/dev/null
assert_eq "test_verifier_brainstorm_probe_genuine_ambiguity_confirms: confirm-on-ambiguity documented" "0" "$?"
assert_pass_if_clean "test_verifier_brainstorm_probe_genuine_ambiguity_confirms"

print_summary
