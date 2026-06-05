#!/usr/bin/env bash
# tests/scripts/test-no-dormant-security-check.sh
#
# Behavioral tests for no-dormant-security-check.sh (epic 588e — the enforce-flip
# prerequisite P8 machine gate). After ADR-0022 the guarded mechanism is the
# IDENTITY-BASED admin exemption: the audit fails CLOSED when no bypass-actor is
# configured (the exemption is dormant) under enforce, and passes once a
# bypass-actor resolves. Asserts only observable verdicts (exit code, ::warning::).
#
#   N1  no bypass-actor + enforce  -> exit 1 (P-IDENTITY-EXEMPT dormant)
#   N2  bypass-actor configured + enforce -> exit 0
#   N3  no bypass-actor + warn     -> exit 0 with ::warning:: (advisory rollout)
#   N4  missing coverage workflow  -> exit 78 (precondition, never a silent pass)
#   N5  P-CONV advisory: convergence-check present but not required -> exit 0 + warning

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY DSO_RULESET_BYPASS_USER_IDS DSO_RULESET_BYPASS_USER_ID
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

REPO_ROOT="$(git rev-parse --show-toplevel)"
AUDIT="$REPO_ROOT/plugins/dso/scripts/ci/no-dormant-security-check.sh"  # shim-exempt: test invokes the script under test by path

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-dormant.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

# Minimal coverage-workflow fixture (only needed now for the precondition + P-CONV).
_COV="$_W/cov.yml"; printf 'jobs:\n  x:\n    steps:\n      - run: true\n' > "$_COV"
_REQ_NO_CONV="$_W/req.txt"; printf 'review-coverage-invariant\n' > "$_REQ_NO_CONV"
# Empty config => no bypass-actor resolves (simulate the dormant case).
_EMPTY_CFG="$_W/empty.conf"; : > "$_EMPTY_CFG"

# ── N1: no bypass-actor + enforce -> blocks (exit 1) ─────────────────────────
out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_COV" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" DSO_BYPASS_CONFIG_FILE="$_EMPTY_CFG" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "P-IDENTITY-EXEMPT" <<<"$out"; then _pass "N1_no_bypass_actor_enforce_blocks"; else _fail "N1_no_bypass_actor_enforce_blocks" "rc=$rc out=$out"; fi

# ── N2: bypass-actor configured + enforce -> passes (exit 0) ─────────────────
out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_COV" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" DSO_RULESET_BYPASS_USER_IDS=207596960 DSO_BYPASS_CONFIG_FILE="$_EMPTY_CFG" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then _pass "N2_bypass_actor_set_passes"; else _fail "N2_bypass_actor_set_passes" "rc=$rc out=$out"; fi

# ── N3: no bypass-actor + warn -> non-blocking (exit 0) + ::warning:: ────────
out="$(DSO_DORMANT_MODE=warn DSO_COVERAGE_YML="$_COV" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" DSO_BYPASS_CONFIG_FILE="$_EMPTY_CFG" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "::warning::" <<<"$out"; then _pass "N3_dormant_warn_nonblocking"; else _fail "N3_dormant_warn_nonblocking" "rc=$rc out=$out"; fi

# ── N4: missing coverage workflow -> precondition (exit 78) ──────────────────
out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_W/does-not-exist.yml" DSO_RULESET_BYPASS_USER_IDS=207596960 bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 78 ]]; then _pass "N4_missing_workflow_precondition"; else _fail "N4_missing_workflow_precondition" "rc=$rc out=$out"; fi

# ── N5: P-CONV advisory — convergence-check present but not required -> warn+pass ─
if [[ -f "$REPO_ROOT/plugins/dso/scripts/ci/review-convergence-check.sh" ]]; then  # shim-exempt: test mirrors the audit's sibling-presence check
    out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_COV" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" DSO_RULESET_BYPASS_USER_IDS=207596960 DSO_BYPASS_CONFIG_FILE="$_EMPTY_CFG" bash "$AUDIT" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]] && grep -q "review-convergence" <<<"$out"; then _pass "N5_convergence_advisory_warns_not_blocks"; else _fail "N5_convergence_advisory_warns_not_blocks" "rc=$rc out=$out"; fi
else
    echo "SKIP: N5_convergence_advisory (review-convergence-check.sh absent)"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
