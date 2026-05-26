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
