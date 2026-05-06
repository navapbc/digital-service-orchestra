#!/usr/bin/env bash
# shellcheck disable=SC2329
# RED tests for Phase 1 Gate attestation contract and SKILL.md preconditions.
# Tests: contract file exists, signal name section, values section, blocking semantics,
# decisions_log write, workflow_completion_checklist reference.
# NOTE: These tests are intentionally RED — contract file and SKILL.md sections
# do not exist yet. They will turn GREEN when the implementation task creates
# plugins/dso/docs/contracts/phase1-gate-attestation.md and updates SKILL.md.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
CONTRACT="${REPO_ROOT}/plugins/dso/docs/contracts/phase1-gate-attestation.md"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_CORPUS=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

source "${REPO_ROOT}/tests/lib/assert.sh"

# ============================================================
# test_attestation_contract_exists
# Verify the contract file exists at the expected path.
# RED: file doesn't exist yet.
# ============================================================
echo "=== test_attestation_contract_exists ==="

if [ -f "$CONTRACT" ]; then
    actual=present
else
    actual=missing
fi
assert_eq "Contract file plugins/dso/docs/contracts/phase1-gate-attestation.md must exist" "present" "$actual"

# ============================================================
# test_attestation_contract_has_signal_name_section
# Grep contract file for signal name or attestation field section header.
# RED: contract file doesn't exist yet; grep will fail.
# ============================================================
echo ""
echo "=== test_attestation_contract_has_signal_name_section ==="

if [ -f "$CONTRACT" ] && grep -qE '^## Signal Name|^## Attestation Field' "$CONTRACT"; then
    actual=present
else
    actual=missing
fi
assert_eq "Contract must have '## Signal Name' or '## Attestation Field' section" "present" "$actual"

# ============================================================
# test_attestation_contract_has_values_section
# Grep contract file for exhausted and open values.
# RED: contract file doesn't exist yet.
# ============================================================
echo ""
echo "=== test_attestation_contract_has_values_section ==="

if [ -f "$CONTRACT" ] && grep -q 'exhausted' "$CONTRACT" && grep -q 'open' "$CONTRACT"; then
    actual=present
else
    actual=missing
fi
assert_eq "Contract must document both 'exhausted' and 'open' attestation values" "present" "$actual"

# ============================================================
# test_attestation_contract_has_blocking_semantics_section
# Grep contract for blocking semantics documentation.
# RED: contract file doesn't exist yet.
# ============================================================
echo ""
echo "=== test_attestation_contract_has_blocking_semantics_section ==="

if [ -f "$CONTRACT" ] && grep -qi 'block' "$CONTRACT"; then
    actual=present
else
    actual=missing
fi
assert_eq "Contract must document blocking semantics" "present" "$actual"

# ============================================================
# test_preconditions_decisions_log_write
# Grep SKILL.md Phase 1 Gate section for decisions_log or PRECONDITIONS write.
# RED: decisions_log write not documented yet.
# ============================================================
echo ""
echo "=== test_preconditions_decisions_log_write ==="

if grep -qiE 'decisions_log|PRECONDITIONS.*decisions|write.*preconditions|preconditions.*write' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "SKILL.md must document decisions_log write in Phase 1 Gate / PRECONDITIONS" "present" "$actual"

# ============================================================
# test_preconditions_affects_fields_workflow_completion
# Grep SKILL.md for workflow_completion_checklist reference.
# RED: workflow_completion_checklist not referenced yet.
# ============================================================
echo ""
echo "=== test_preconditions_affects_fields_workflow_completion ==="

if grep -q 'workflow_completion_checklist' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "SKILL.md must reference workflow_completion_checklist" "present" "$actual"

# ============================================================
print_summary
