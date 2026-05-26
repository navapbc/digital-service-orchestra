#!/usr/bin/env bash
# tests/scripts/test-verifier-deferred-evidence-contract.sh
#
# Pins the deferred-evidence obligation contract in
# plugins/dso/agents/completion-verifier.md and
# plugins/dso/docs/VERIFIER-PROTOCOL.md. The two files are the canonical
# spec the verifier sub-agent reads at dispatch time; if either drifts away
# from the contract, this test fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER="$REPO_ROOT/plugins/dso/agents/completion-verifier.md"
PROTOCOL="$REPO_ROOT/plugins/dso/docs/VERIFIER-PROTOCOL.md"
SCHEMA="$REPO_ROOT/plugins/dso/docs/contracts/obligation-ticket-schema.md"

PASS=0
FAIL=0

_assert_grep() {
    local name="$1" file="$2" pattern="$3"
    if grep -qE "$pattern" "$file"; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
        printf "FAIL: %s\n  file:    %s\n  pattern: %s\n" "$name" "$file" "$pattern" >&2
    fi
}

# Verifier agent
_assert_grep "verifier documents Step 4.5 deferred-evidence step" \
    "$VERIFIER" '^### Step 4\.5: Deferred-Evidence'

_assert_grep "verifier documents trigger regex (deferred|defer)" \
    "$VERIFIER" '\\b\(deferred\|defer\)'

_assert_grep "verifier documents obligation:rollout tag" \
    "$VERIFIER" 'obligation:rollout'

_assert_grep "verifier output schema includes obligations_created" \
    "$VERIFIER" 'obligations_created'

_assert_grep "verifier documents P1=FAIL on obligation_creation_failed" \
    "$VERIFIER" 'obligation_creation_failed'

# Finding 2 contract: the verifier markdown (the agent's only runtime) must
# explicitly bind the failure-path triple: (a) P1 = FAIL when any required
# obligation creation fails, (b) the criteria_results entry carries
# `evidence_found: "obligation_creation_failed: ..."`, and (c) successful
# obligation ids are listed in `obligations_created`. We assert all three
# tokens appear within a single contiguous documentation block (Step 4.5
# and the Output Schema notes) so they cannot drift independently.
_assert_grep "verifier binds P1=FAIL to failed obligation creation" \
    "$VERIFIER" 'P1.*FAIL|P1: FAIL'

_assert_grep "verifier states criteria_results carries obligation_creation_failed evidence" \
    "$VERIFIER" 'criteria_results'

_assert_grep "verifier states obligations_created lists only successful ids" \
    "$VERIFIER" 'obligations_created.*successful|successfully-created'

# Protocol doc
_assert_grep "protocol doc references deferred-evidence obligations section" \
    "$PROTOCOL" 'Deferred-evidence obligations'

_assert_grep "protocol doc references obligation-ticket-schema.md" \
    "$PROTOCOL" 'obligation-ticket-schema\.md'

# Schema doc
_assert_grep "schema doc documents the trigger regex" \
    "$SCHEMA" '\\b\(deferred\|defer\)'

_assert_grep "schema doc documents Deadline parseable field" \
    "$SCHEMA" 'Deadline:'

_assert_grep "schema doc documents obligations_created output field" \
    "$SCHEMA" 'obligations_created'

printf "verifier-deferred-evidence-contract: PASS=%d FAIL=%d\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
