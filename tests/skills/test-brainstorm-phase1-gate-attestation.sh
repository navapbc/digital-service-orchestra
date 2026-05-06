#!/usr/bin/env bash
# shellcheck disable=SC2329
# RED tests for Phase 1 Gate attestation field.
# Tests: attestation field present, exhausted/open values, gate blocks without attestation,
# exhausted state definition, open state lists unresolved questions.
# NOTE: These tests are intentionally RED — SKILL.md sections they check do not exist yet.
# They will turn GREEN when the implementation task adds Phase 1 Gate attestation to SKILL.md.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_CORPUS=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

source "${REPO_ROOT}/tests/lib/assert.sh"

# ============================================================
# test_attestation_field_required
# Grep SKILL.md Phase 1 Gate section for 'attestation' keyword.
# RED: SKILL.md doesn't have attestation field yet.
# ============================================================
echo "=== test_attestation_field_required ==="

if grep -q 'attestation' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "Phase 1 Gate must document an attestation field" "present" "$actual"

# ============================================================
# test_attestation_values_exhausted_and_open
# Grep for both 'exhausted' and 'open' attestation values.
# RED: neither value is documented yet.
# ============================================================
echo ""
echo "=== test_attestation_values_exhausted_and_open ==="

if grep -q 'exhausted' "$SKILL_CORPUS"; then
    actual_exhausted=present
else
    actual_exhausted=missing
fi
assert_eq "Phase 1 Gate attestation must document 'exhausted' value" "present" "$actual_exhausted"

if grep -q 'attestation.*open\|open.*attestation' "$SKILL_CORPUS"; then
    actual_open=present
else
    actual_open=missing
fi
assert_eq "Phase 1 Gate attestation must document 'open' value" "present" "$actual_open"

# ============================================================
# test_gate_blocks_without_attestation
# Grep for pattern indicating gate cannot pass without attestation.
# RED: blocking semantics not documented yet.
# ============================================================
echo ""
echo "=== test_gate_blocks_without_attestation ==="

if grep -qiE 'block.*attestation|attestation.*block|cannot.*pass.*without.*attestation|gate.*requires.*attestation|attestation.*required' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "Phase 1 Gate must document that gate blocks without attestation" "present" "$actual"

# ============================================================
# test_exhausted_state_defined
# Grep for definition of exhausted state (all questions resolved).
# RED: exhausted state definition not present yet.
# ============================================================
echo ""
echo "=== test_exhausted_state_defined ==="

if grep -qiE 'exhausted.*all.*question|all.*question.*resolved.*exhausted|exhausted.*resolved|exhausted.*no.*open|all.*probes.*resolved.*exhausted' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "SKILL.md must define exhausted state as all questions resolved" "present" "$actual"

# ============================================================
# test_open_state_lists_unresolved
# Grep for open attestation listing unresolved questions with blocking_for.
# RED: open state with blocking_for not documented yet.
# ============================================================
echo ""
echo "=== test_open_state_lists_unresolved ==="

if grep -qiE 'open.*blocking_for|blocking_for.*open|unresolved.*blocking_for' "$SKILL_CORPUS"; then
    actual=present
else
    actual=missing
fi
assert_eq "SKILL.md open attestation must list unresolved questions with blocking_for" "present" "$actual"

# ============================================================
print_summary
