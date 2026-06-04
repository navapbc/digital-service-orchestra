#!/usr/bin/env bash
# tests/scripts/test-no-dormant-security-check.sh
#
# Behavioral tests for no-dormant-security-check.sh (epic 588e / 3ebb DD4 — the
# enforce-flip prerequisite P8 machine gate). Proves the audit fails CLOSED when a
# built security check is unwired, and passes once it is wired. Asserts only
# observable verdicts (exit code, ::warning:: emission), never internals.
#
#   D1  coverage workflow WITHOUT DSO_ADMIN_EXEMPTION_LEDGER, enforce -> exit 1
#       (the admin-exemption consult path is dormant — the dead-on-both-ends gap).
#   D2  coverage workflow WITH DSO_ADMIN_EXEMPTION_LEDGER, enforce -> exit 0.
#   D3  dormant config under warn mode -> exit 0 (advisory, non-blocking rollout).
#   D4  missing coverage workflow -> exit 78 (precondition, never a silent pass).
#   D5  P-CONV advisory: wired coverage + convergence-check present but not in
#       required-checks -> exit 0 with a ::warning:: (does not block on the
#       advisory predicate alone).

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

REPO_ROOT="$(git rev-parse --show-toplevel)"
AUDIT="$REPO_ROOT/plugins/dso/scripts/ci/no-dormant-security-check.sh"  # shim-exempt: test invokes the script under test by path

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-dormant.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

# A coverage-workflow fixture missing the admin-exemption env (dormant).
_DORMANT_YML="$_W/dormant.yml"
cat > "$_DORMANT_YML" <<'YML'
      - name: Run coverage invariant
        env:
          DSO_REVIEWED_LEDGER: .review-coverage-ledger
          DSO_COVERAGE_INVARIANT_MODE: warn
        run: true   # fixture: the audit greps the env block, not the run step
YML

# A coverage-workflow fixture WITH the admin-exemption env (wired).
_WIRED_YML="$_W/wired.yml"
cat > "$_WIRED_YML" <<'YML'
      - name: Run coverage invariant
        env:
          DSO_REVIEWED_LEDGER: .review-coverage-ledger
          DSO_ADMIN_EXEMPTION_LEDGER: .admin-exemption-ledger
          DSO_COVERAGE_INVARIANT_MODE: warn
        run: true   # fixture: the audit greps the env block, not the run step
YML

# A coverage-workflow fixture with the key present but EMPTY (fail-open trap).
_EMPTY_YML="$_W/empty.yml"
cat > "$_EMPTY_YML" <<'YML'
      - name: Run coverage invariant
        env:
          DSO_REVIEWED_LEDGER: .review-coverage-ledger
          DSO_ADMIN_EXEMPTION_LEDGER: ""
          DSO_COVERAGE_INVARIANT_MODE: warn
        run: true
YML

# A required-checks fixture WITHOUT review-convergence (to drive the P-CONV advisory).
_REQ_NO_CONV="$_W/required-no-conv.txt"
printf 'review-coverage-invariant\nmerge-pipeline-checks\n' > "$_REQ_NO_CONV"

# ── D1: dormant config + enforce -> blocks (exit 1) ──────────────────────────
out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_DORMANT_YML" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "P-AEL" <<<"$out"; then _pass "D1_dormant_enforce_blocks"; else _fail "D1_dormant_enforce_blocks" "rc=$rc out=$out"; fi

# ── D2: wired config + enforce -> passes (exit 0) ────────────────────────────
out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_WIRED_YML" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then _pass "D2_wired_enforce_passes"; else _fail "D2_wired_enforce_passes" "rc=$rc out=$out"; fi

# ── D6: key present but EMPTY value + enforce -> blocks (fail-open trap) ──────
# A bare/empty DSO_ADMIN_EXEMPTION_LEDGER passes the script's `[[ -n ]]` guard as
# unset, so the audit must NOT report it wired (else it fails OPEN).
out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_EMPTY_YML" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "P-AEL" <<<"$out"; then _pass "D6_empty_value_is_dormant"; else _fail "D6_empty_value_is_dormant" "rc=$rc out=$out"; fi

# ── D3: dormant config + warn -> non-blocking (exit 0) ───────────────────────
out="$(DSO_DORMANT_MODE=warn DSO_COVERAGE_YML="$_DORMANT_YML" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "::warning::" <<<"$out"; then _pass "D3_dormant_warn_nonblocking"; else _fail "D3_dormant_warn_nonblocking" "rc=$rc out=$out"; fi

# ── D4: missing coverage workflow -> precondition (exit 78) ───────────────────
out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_W/does-not-exist.yml" bash "$AUDIT" 2>&1)"; rc=$?
if [[ $rc -eq 78 ]]; then _pass "D4_missing_workflow_precondition"; else _fail "D4_missing_workflow_precondition" "rc=$rc out=$out"; fi

# ── D5: P-CONV advisory — wired AEL but convergence-check unwired -> warn+pass ─
# Only meaningful when the real convergence-check script exists in the tree.
if [[ -f "$REPO_ROOT/plugins/dso/scripts/ci/review-convergence-check.sh" ]]; then  # shim-exempt: test mirrors the audit's sibling-presence check
    out="$(DSO_DORMANT_MODE=enforce DSO_COVERAGE_YML="$_WIRED_YML" DSO_REQUIRED_CHECKS_FILE="$_REQ_NO_CONV" bash "$AUDIT" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]] && grep -q "review-convergence" <<<"$out"; then _pass "D5_convergence_advisory_warns_not_blocks"; else _fail "D5_convergence_advisory_warns_not_blocks" "rc=$rc out=$out"; fi
else
    echo "SKIP: D5_convergence_advisory (review-convergence-check.sh absent)"
fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
