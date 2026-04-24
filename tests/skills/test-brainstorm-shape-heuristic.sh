#!/usr/bin/env bash
# tests/skills/test-brainstorm-shape-heuristic.sh
# Behavioral tests for classify-sc-shape.sh — SC shape heuristic.
#
# Tests verify that classify-sc-shape.sh classifies success criteria text
# into "external-outcome" (deployed systems, third-party integrations, user-
# visible results) or "pure-code" (test coverage, API contracts, internal
# assertions) by printing the shape label to stdout and exiting 0.
#
# ALL tests are RED until plugins/dso/scripts/classify-sc-shape.sh is created
# (task 1a43-a73f). This is intentional — tests must fail before implementation.
#
# Usage: bash tests/skills/test-brainstorm-shape-heuristic.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$(git rev-parse --show-toplevel)/plugins/dso/scripts/brainstorm/classify-sc-shape.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# test_external_sc_returns_external_outcome  [RED marker boundary]
# SC describes a production deployment with a public URL.
# → classify-sc-shape.sh must print "external-outcome" and exit 0.
# ---------------------------------------------------------------------------
_exit_code=0
_result=$(echo 'the feature is deployed to production and accessible at https://app.example.com' \
    | bash "$SCRIPT" 2>/dev/null) || _exit_code=$?

assert_eq "test_external_sc_returns_external_outcome:stdout" "external-outcome" "$_result"
assert_eq "test_external_sc_returns_external_outcome:exit"   "0"                "$_exit_code"

# ---------------------------------------------------------------------------
# test_pure_code_sc_returns_pure_code
# SC describes unit-test passage with coverage metrics.
# → classify-sc-shape.sh must print "pure-code" and exit 0.
# ---------------------------------------------------------------------------
_exit_code=0
_result=$(echo 'all unit tests pass with 100% branch coverage' \
    | bash "$SCRIPT" 2>/dev/null) || _exit_code=$?

assert_eq "test_pure_code_sc_returns_pure_code:stdout" "pure-code" "$_result"
assert_eq "test_pure_code_sc_returns_pure_code:exit"   "0"         "$_exit_code"

# ---------------------------------------------------------------------------
# test_third_party_sc_returns_external_outcome
# SC describes a third-party service (Stripe) configured and processing live events.
# → classify-sc-shape.sh must print "external-outcome" and exit 0.
# ---------------------------------------------------------------------------
_exit_code=0
_result=$(echo 'Stripe webhook is configured and processing live payments' \
    | bash "$SCRIPT" 2>/dev/null) || _exit_code=$?

assert_eq "test_third_party_sc_returns_external_outcome:stdout" "external-outcome" "$_result"
assert_eq "test_third_party_sc_returns_external_outcome:exit"   "0"                "$_exit_code"

# ---------------------------------------------------------------------------
# test_internal_api_sc_returns_pure_code
# SC describes an internal API contract (HTTP response code + payload shape).
# → classify-sc-shape.sh must print "pure-code" and exit 0.
# ---------------------------------------------------------------------------
_exit_code=0
_result=$(echo 'the API endpoint returns 200 with a correctly structured JSON response' \
    | bash "$SCRIPT" 2>/dev/null) || _exit_code=$?

assert_eq "test_internal_api_sc_returns_pure_code:stdout" "pure-code" "$_result"
assert_eq "test_internal_api_sc_returns_pure_code:exit"   "0"         "$_exit_code"

print_summary
