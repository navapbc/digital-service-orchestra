#!/usr/bin/env bash
# tests/scripts/test-fp-recovery-record-exemption.sh
#
# Behavioral tests for fp-recovery-record-exemption.sh (epic 588e / 3ebb DD4,
# gap G-B — FP-recovery propagation producer). Proves a cleared (sub-)PR's SHAs
# become reviewed-equivalent in the admin-exemption ledger, so a later coverage
# walk credits them. Asserts observable verdicts (ledger exemption state, exit
# codes), never internals.
#
#   E1  --shas records an HMAC-valid exemption -> each SHA verifies as exempt.
#   E2  idempotent: re-running does not duplicate / does not error.
#   E3  missing --reviewer-hash -> usage error (exit 1).
#   E4  empty SHA set -> error (exit 1), nothing recorded.
#   E5  end-to-end: a recorded SHA is treated as exempt by review-coverage-
#       invariant's own ael_sha_is_exempt (the consult path the producer feeds).

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

REPO_ROOT="$(git rev-parse --show-toplevel)"
REC="$REPO_ROOT/plugins/dso/scripts/ci/fp-recovery-record-exemption.sh"  # shim-exempt: test invokes the script under test by path
LEDGER_LIB="$REPO_ROOT/plugins/dso/scripts/ci/admin-exemption-ledger.sh"  # shim-exempt: test sources the ledger lib to verify exemptions

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-fprec.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

# Fixed signing key for the test environment (same mechanism as the ledger lib).
KEY="$_W/closure-key"; printf 'test-fp-key-0001\n' > "$KEY"
export DSO_ADMIN_EXEMPTION_KEY_FILE="$KEY"

# shellcheck source=/dev/null
source "$LEDGER_LIB"

SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"

# ── E1: --shas records HMAC-valid exemptions ─────────────────────────────────
L="$_W/e1.ledger"
out="$(bash "$REC" --shas "$SHA_A $SHA_B" --reviewer-hash abc123 --reason "phantom race FP" --ledger "$L" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && ael_sha_is_exempt "$L" "$SHA_A" && ael_sha_is_exempt "$L" "$SHA_B"; then _pass "E1_records_exemptions"; else _fail "E1_records_exemptions" "rc=$rc out=$out"; fi

# ── E2: idempotent re-run (no duplicate, no error) ───────────────────────────
before="$(grep -c "$SHA_A" "$L" 2>/dev/null || echo 0)"
out="$(bash "$REC" --shas "$SHA_A" --reviewer-hash abc123 --reason "phantom race FP" --ledger "$L" 2>&1)"; rc=$?
after="$(grep -c "$SHA_A" "$L" 2>/dev/null || echo 0)"
if [[ $rc -eq 0 ]] && [[ "$before" == "$after" ]]; then _pass "E2_idempotent"; else _fail "E2_idempotent" "rc=$rc before=$before after=$after"; fi

# ── E3: missing --reviewer-hash -> usage error ───────────────────────────────
out="$(bash "$REC" --shas "$SHA_A" --reason "x" --ledger "$_W/e3.ledger" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && [[ ! -f "$_W/e3.ledger" ]]; then _pass "E3_missing_hash_errors"; else _fail "E3_missing_hash_errors" "rc=$rc out=$out"; fi

# ── E4: empty SHA set -> error ───────────────────────────────────────────────
out="$(bash "$REC" --shas "   " --reviewer-hash abc123 --reason "x" --ledger "$_W/e4.ledger" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then _pass "E4_empty_shaset_errors"; else _fail "E4_empty_shaset_errors" "rc=$rc out=$out"; fi

# ── E5: end-to-end — recorded SHA is exempt per the coverage consult path ────
L5="$_W/e5.ledger"
bash "$REC" --shas "$SHA_A" --reviewer-hash deadbeef --reason "doc nit FP" --ledger "$L5" >/dev/null 2>&1
# A FORGED entry for a different SHA must NOT verify (fail-closed sanity).
printf '%s\t%s\t%s\t%s\t%s\n' "$SHA_B" "Zm9v" "YmFy" "123" "deadbeefforged" >> "$L5"
if ael_sha_is_exempt "$L5" "$SHA_A" && ! ael_sha_is_exempt "$L5" "$SHA_B"; then _pass "E5_recorded_exempt_forged_rejected"; else _fail "E5_recorded_exempt_forged_rejected" "real-exempt or forged-accepted"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
