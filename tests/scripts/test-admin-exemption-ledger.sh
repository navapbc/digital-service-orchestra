#!/usr/bin/env bash
# tests/scripts/test-admin-exemption-ledger.sh — S-11 / A-2
#
# Behavioral tests for the HMAC-signed admin-exemption ledger. Proves:
#   T1: a valid signed entry -> the SHA verifies as exempt (covered).
#   T2: a forged entry (right metadata, garbage HMAC) -> NOT exempt (fail closed).
#   T3: a tampered entry (metadata edited after signing) -> NOT exempt.
#   T4: an entry signed with a DIFFERENT key -> NOT exempt (cross-env forgery).
#   T5: absent SHA / empty ledger -> NOT exempt.
#   T6: end-to-end wiring — review-coverage-invariant treats an HMAC-valid
#       exempt SHA as covered (exit 0), but a forged exemption for the same SHA
#       still BLOCKS (exit 1).
#
# Behavioral standard: each test asserts observable verdicts (exempt / not exempt,
# invariant exit code), never internal call counts.

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY

REPO_ROOT="$(git rev-parse --show-toplevel)"
LEDGER_LIB="$REPO_ROOT/plugins/dso/scripts/ci/admin-exemption-ledger.sh"
INVARIANT="$REPO_ROOT/plugins/dso/scripts/ci/review-coverage-invariant.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dso-ael.XXXXXX")"
trap 'rm -rf "$_WORK"' EXIT

# A fixed signing key for the test environment.
KEY="$_WORK/closure-key"
printf 'test-signing-key-0001\n' > "$KEY"
export DSO_ADMIN_EXEMPTION_KEY_FILE="$KEY"

SHA_OK="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_FORGED="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ── T1: valid signed entry verifies as exempt ────────────────────────────────
L1="$_WORK/t1.ledger"
bash "$LEDGER_LIB" append "$L1" "$SHA_OK" "alice@example.com" "hotfix: prod outage INC-9" 1700000000
if bash "$LEDGER_LIB" verify "$L1" "$SHA_OK" >/dev/null 2>&1; then
    _pass "T1_valid_signed_entry_is_exempt"
else
    _fail "T1_valid_signed_entry_is_exempt" "valid entry did not verify"
fi

# ── T2: forged HMAC (metadata present, signature garbage) -> NOT exempt ───────
L2="$_WORK/t2.ledger"
by_b64="$(printf '%s' "mallory" | base64 | tr -d '\n')"
rsn_b64="$(printf '%s' "i just want in" | base64 | tr -d '\n')"
printf '%s\t%s\t%s\t%s\t%s\n' "$SHA_FORGED" "$by_b64" "$rsn_b64" 1700000000 \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$L2"
if bash "$LEDGER_LIB" verify "$L2" "$SHA_FORGED" >/dev/null 2>&1; then
    _fail "T2_forged_hmac_not_exempt" "forged entry incorrectly verified as exempt"
else
    _pass "T2_forged_hmac_not_exempt"
fi

# ── T3: tampered metadata (sign, then edit the reason) -> NOT exempt ──────────
L3="$_WORK/t3.ledger"
bash "$LEDGER_LIB" append "$L3" "$SHA_OK" "alice@example.com" "small typo fix" 1700000000
# Tamper: replace the base64 reason field with a different value, keep the HMAC.
orig_rsn_b64="$(printf '%s' "small typo fix" | base64 | tr -d '\n')"
evil_rsn_b64="$(printf '%s' "land entire unreviewed feature" | base64 | tr -d '\n')"
python3 - "$L3" "$orig_rsn_b64" "$evil_rsn_b64" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
data = open(path).read().replace(old, new)
open(path, "w").write(data)
PY
if bash "$LEDGER_LIB" verify "$L3" "$SHA_OK" >/dev/null 2>&1; then
    _fail "T3_tampered_metadata_not_exempt" "tampered entry incorrectly verified"
else
    _pass "T3_tampered_metadata_not_exempt"
fi

# ── T4: entry signed with a DIFFERENT key -> NOT exempt under the real key ────
L4="$_WORK/t4.ledger"
OTHERKEY="$_WORK/otherkey"; printf 'attacker-key\n' > "$OTHERKEY"
DSO_ADMIN_EXEMPTION_KEY_FILE="$OTHERKEY" bash "$LEDGER_LIB" append \
    "$L4" "$SHA_OK" "alice@example.com" "signed with wrong key" 1700000000
# Now verify under the real environment key (DSO_ADMIN_EXEMPTION_KEY_FILE=$KEY).
if bash "$LEDGER_LIB" verify "$L4" "$SHA_OK" >/dev/null 2>&1; then
    _fail "T4_wrong_key_not_exempt" "cross-key entry incorrectly verified"
else
    _pass "T4_wrong_key_not_exempt"
fi

# ── T5: absent SHA / empty ledger -> NOT exempt ──────────────────────────────
L5="$_WORK/t5.ledger"; : > "$L5"
if bash "$LEDGER_LIB" verify "$L5" "$SHA_OK" >/dev/null 2>&1; then
    _fail "T5_empty_ledger_not_exempt" "empty ledger reported exempt"
else
    _pass "T5_empty_ledger_not_exempt"
fi

# ── T6: end-to-end wiring into review-coverage-invariant ─────────────────────
# Build a repo with one unreviewed head SHA and a mock gh that returns NO covering
# PR (so the SHA is unreviewed). Then: (a) a valid exemption -> invariant passes;
# (b) a forged exemption for the same SHA -> invariant still BLOCKS.
_MOCK_BIN="$_WORK/bin"; mkdir -p "$_MOCK_BIN"
cat > "$_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "api" ]] || { echo "{}"; exit 0; }
case "$2" in
  */commits/*/pulls)      echo '[]'; exit 0 ;;          # no covering PR
  */commits/*/check-runs) echo '{"check_runs":[]}'; exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
MOCK
chmod +x "$_MOCK_BIN/gh"

RP="$_WORK/repo"; mkdir -p "$RP"
git -C "$RP" init -q -b main
git -C "$RP" config user.email t@e.st; git -C "$RP" config user.name t
git -C "$RP" config commit.gpgsign false
printf 'base\n' > "$RP/base.txt"; git -C "$RP" add base.txt; git -C "$RP" commit -qm base
git -C "$RP" init -q --bare "$RP/origin.git"
git -C "$RP" remote add origin "$RP/origin.git"; git -C "$RP" push -q origin main
printf 'feat\n' > "$RP/feat.txt"; git -C "$RP" add feat.txt; git -C "$RP" commit -qm feat
HEAD_SHA="$(git -C "$RP" rev-parse HEAD)"

_run_invariant() { # _run_invariant <ledger>
    ( cd "$RP" && env "PATH=$_MOCK_BIN:$PATH" GH_REPO="test/repo" \
        DSO_HEAD_SHA="$HEAD_SHA" DSO_COVERAGE_INVARIANT_MODE=enforce \
        DSO_ADMIN_EXEMPTION_LEDGER="$1" \
        DSO_ADMIN_EXEMPTION_KEY_FILE="$KEY" \
        bash "$INVARIANT" ) 2>&1
}

# Baseline: no ledger -> the unreviewed head SHA BLOCKS (sanity that the fixture
# really is unreviewed; otherwise T6 would be vacuous).
out="$(_run_invariant "")" ; rc=$?
if [[ $rc -ne 0 ]] && grep -q "UNREVIEWED ${HEAD_SHA}" <<<"$out"; then
    _pass "T6a_baseline_unreviewed_blocks"
else
    _fail "T6a_baseline_unreviewed_blocks" "rc=$rc out=$out"
fi

# (a) valid exemption -> invariant PASSES (SHA treated as covered).
LV="$_WORK/t6valid.ledger"
DSO_ADMIN_EXEMPTION_KEY_FILE="$KEY" bash "$LEDGER_LIB" append \
    "$LV" "$HEAD_SHA" "admin@example.com" "emergency hotfix bypass" 1700000000
out="$(_run_invariant "$LV")"; rc=$?
if [[ $rc -eq 0 ]]; then
    _pass "T6b_valid_exemption_covers_sha"
else
    _fail "T6b_valid_exemption_covers_sha" "rc=$rc out=$out"
fi

# (b) forged exemption for the SAME SHA -> invariant still BLOCKS.
LF="$_WORK/t6forged.ledger"
fby="$(printf '%s' "admin@example.com" | base64 | tr -d '\n')"
frsn="$(printf '%s' "emergency hotfix bypass" | base64 | tr -d '\n')"
printf '%s\t%s\t%s\t%s\t%s\n' "$HEAD_SHA" "$fby" "$frsn" 1700000000 \
    "0000000000000000000000000000000000000000000000000000000000000000" > "$LF"
out="$(_run_invariant "$LF")"; rc=$?
if [[ $rc -ne 0 ]] && grep -q "UNREVIEWED ${HEAD_SHA}" <<<"$out"; then
    _pass "T6c_forged_exemption_still_blocks"
else
    _fail "T6c_forged_exemption_still_blocks" "rc=$rc out=$out"
fi

# ── T7: exempt_by class filter (C2) — provenance honors ONLY fp-recovery ─────
# An entry of a DIFFERENT class is valid (HMAC-signed) and counts with no filter,
# but must NOT count when the caller filters to exempt_by=fp-recovery. An
# fp-recovery entry counts under both.
L7="$_WORK/t7.ledger"
SHA_FP="cccccccccccccccccccccccccccccccccccccccc"
SHA_OTHER="dddddddddddddddddddddddddddddddddddddddd"
bash "$LEDGER_LIB" append "$L7" "$SHA_FP" "fp-recovery" "opus 0 findings" 1700000000
bash "$LEDGER_LIB" append "$L7" "$SHA_OTHER" "some-other-class" "signed but not fp-recovery" 1700000000
# fp-recovery SHA: exempt under no filter AND under fp-recovery filter.
if bash "$LEDGER_LIB" verify "$L7" "$SHA_FP" >/dev/null 2>&1 \
   && bash "$LEDGER_LIB" verify "$L7" "$SHA_FP" "fp-recovery" >/dev/null 2>&1 \
   && bash "$LEDGER_LIB" verify "$L7" "$SHA_OTHER" >/dev/null 2>&1 \
   && ! bash "$LEDGER_LIB" verify "$L7" "$SHA_OTHER" "fp-recovery" >/dev/null 2>&1; then
    _pass "T7_exempt_by_class_filter"
else
    _fail "T7_exempt_by_class_filter" "class filter did not scope to fp-recovery"
fi

echo ""
echo "=== test-admin-exemption-ledger.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
