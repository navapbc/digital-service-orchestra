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

# C1 gate inputs: a REAL cleared reviewer-findings.json (0 blocking) + its sha256.
CLEARED="$_W/cleared-findings.json"
printf '%s' '{"findings": [], "summary": "manual FP-recovery review — 0 critical/important/fragile"}' > "$CLEARED"
CLEARED_HASH="$(shasum -a 256 "$CLEARED" | awk '{print $1}')"
# A findings file WITH a blocking finding (for the C1-reject test).
BLOCKING="$_W/blocking-findings.json"
printf '%s' '{"findings": [{"severity":"important","title":"x"}], "summary": "not cleared"}' > "$BLOCKING"
BLOCKING_HASH="$(shasum -a 256 "$BLOCKING" | awk '{print $1}')"
GATE=(--findings "$CLEARED" --reviewer-hash "$CLEARED_HASH")

# ── E1: records HMAC-valid exemptions (with a cleared review) ────────────────
L="$_W/e1.ledger"
out="$(bash "$REC" --shas "$SHA_A $SHA_B" "${GATE[@]}" --reason "phantom race FP" --ledger "$L" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && ael_sha_is_exempt "$L" "$SHA_A" && ael_sha_is_exempt "$L" "$SHA_B"; then _pass "E1_records_exemptions"; else _fail "E1_records_exemptions" "rc=$rc out=$out"; fi

# ── E2: idempotent re-run (no duplicate, no error) ───────────────────────────
before="$(grep -c "$SHA_A" "$L" 2>/dev/null || echo 0)"
out="$(bash "$REC" --shas "$SHA_A" "${GATE[@]}" --reason "phantom race FP" --ledger "$L" 2>&1)"; rc=$?
after="$(grep -c "$SHA_A" "$L" 2>/dev/null || echo 0)"
if [[ $rc -eq 0 ]] && [[ "$before" == "$after" ]]; then _pass "E2_idempotent"; else _fail "E2_idempotent" "rc=$rc before=$before after=$after"; fi

# ── E3: missing --reviewer-hash -> usage error (before the C1 gate) ──────────
out="$(bash "$REC" --shas "$SHA_A" --reason "x" --findings "$CLEARED" --ledger "$_W/e3.ledger" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && [[ ! -f "$_W/e3.ledger" ]]; then _pass "E3_missing_hash_errors"; else _fail "E3_missing_hash_errors" "rc=$rc out=$out"; fi

# ── E4: empty SHA set -> error ───────────────────────────────────────────────
out="$(bash "$REC" --shas "   " "${GATE[@]}" --reason "x" --ledger "$_W/e4.ledger" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]]; then _pass "E4_empty_shaset_errors"; else _fail "E4_empty_shaset_errors" "rc=$rc out=$out"; fi

# ── E5: end-to-end — recorded SHA is exempt per the coverage consult path ────
L5="$_W/e5.ledger"
bash "$REC" --shas "$SHA_A" "${GATE[@]}" --reason "doc nit FP" --ledger "$L5" >/dev/null 2>&1
# A FORGED entry for a different SHA must NOT verify (fail-closed sanity).
printf '%s\t%s\t%s\t%s\t%s\n' "$SHA_B" "Zm9v" "YmFy" "123" "deadbeefforged" >> "$L5"
if ael_sha_is_exempt "$L5" "$SHA_A" && ! ael_sha_is_exempt "$L5" "$SHA_B"; then _pass "E5_recorded_exempt_forged_rejected"; else _fail "E5_recorded_exempt_forged_rejected" "real-exempt or forged-accepted"; fi

# ── E6: malformed SHA is refused (input validation) ─────────────────────────
L6="$_W/e6.ledger"
out="$(bash "$REC" --shas "not-a-sha" "${GATE[@]}" --reason "x" --ledger "$L6" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "malformed SHA" <<<"$out" && [[ ! -f "$L6" ]]; then _pass "E6_malformed_sha_refused"; else _fail "E6_malformed_sha_refused" "rc=$rc out=$out"; fi

# ── C1 gate: an exemption requires a verified, CLEARED review ────────────────
# E7: --reviewer-hash that does NOT match the findings file -> refuse (exit 2).
L7="$_W/e7.ledger"
out="$(bash "$REC" --shas "$SHA_A" --findings "$CLEARED" --reviewer-hash "deadbeefnotthehash" --reason "x" --ledger "$L7" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && grep -qi "does not match" <<<"$out" && [[ ! -f "$L7" ]]; then _pass "C1_hash_mismatch_refused"; else _fail "C1_hash_mismatch_refused" "rc=$rc out=$out"; fi
# E8: findings WITH a blocking finding (review not cleared) -> refuse (exit 2).
L8="$_W/e8.ledger"
out="$(bash "$REC" --shas "$SHA_A" --findings "$BLOCKING" --reviewer-hash "$BLOCKING_HASH" --reason "x" --ledger "$L8" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && grep -qi "NOT cleared" <<<"$out" && [[ ! -f "$L8" ]]; then _pass "C1_blocking_findings_refused"; else _fail "C1_blocking_findings_refused" "rc=$rc out=$out"; fi
# E9: missing findings file -> refuse (exit 2), no exemption.
L9="$_W/e9.ledger"
out="$(bash "$REC" --shas "$SHA_A" --findings "$_W/nonexistent.json" --reviewer-hash "$CLEARED_HASH" --reason "x" --ledger "$L9" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && [[ ! -f "$L9" ]]; then _pass "C1_missing_findings_refused"; else _fail "C1_missing_findings_refused" "rc=$rc out=$out"; fi
# E10: a findings file WITHOUT a 'findings' array -> refuse (exit 2). Prevents
# {"summary": "..."} from passing the gate by defaulting to 0 findings.
NOFIND="$_W/no-findings.json"; printf '%s' '{"summary": "no findings key"}' > "$NOFIND"
NOFIND_HASH="$(shasum -a 256 "$NOFIND" | awk '{print $1}')"; L10="$_W/e10.ledger"
out="$(bash "$REC" --shas "$SHA_A" --findings "$NOFIND" --reviewer-hash "$NOFIND_HASH" --reason "x" --ledger "$L10" 2>&1)"; rc=$?
if [[ $rc -eq 2 ]] && grep -qi "not a valid review" <<<"$out" && [[ ! -f "$L10" ]]; then _pass "C1_no_findings_array_refused"; else _fail "C1_no_findings_array_refused" "rc=$rc out=$out"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
