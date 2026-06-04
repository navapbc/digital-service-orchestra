#!/usr/bin/env bash
# tests/scripts/test-verify-session-provenance-admin-exempt.sh
#
# Behavioral tests for the admin-exemption ledger consult in
# verify-session-provenance.sh (epic 588e / 3ebb DD4 unit 5). An HMAC-valid
# fp-recovery exemption for a commit must classify it as PROVENANCED (covered),
# so the downstream llm-review dispatcher SKIPs it (no second admin override).
# The consult is ADDITIVE and FAIL-CLOSED: no ledger, no key, a forged entry, or
# a non-fp-recovery class all leave the commit UNPROVENANCED (covering-PR lookup).
#
#   A1 valid fp-recovery exemption -> covered (NOT in unprovenanced-shas.txt)
#   A2 no ledger configured        -> unprovenanced (fail-closed baseline)
#   A3 forged HMAC entry           -> unprovenanced (fail-closed)
#   A4 exempt_by != fp-recovery    -> unprovenanced (C2 class filter)

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"  # shim-exempt: test invokes the script under test by path
LEDGER_LIB="$REPO_ROOT/plugins/dso/scripts/ci/admin-exemption-ledger.sh"  # shim-exempt: test signs ledger entries via the lib

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/vsp-ael.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

KEY="$_W/closure-key"; printf 'vsp-test-key-1\n' > "$KEY"
export DSO_ADMIN_EXEMPTION_KEY_FILE="$KEY"

# Mock gh: every `gh api` returns [] (no covering PR) so a non-exempt commit is
# unprovenanced — isolating the admin-exemption path as the only thing that can
# make the feature commit provenanced.
MOCK="$_W/mockbin"; mkdir -p "$MOCK"
cat > "$MOCK/gh" <<'GH'
#!/usr/bin/env bash
case "$1" in
  api) echo "[]"; exit 0 ;;
  *) echo "{}"; exit 0 ;;
esac
GH
chmod +x "$MOCK/gh"

# Build a fresh fake repo (base + one untrailered feature commit); echo "base feat repo".
_repo() {
    local r; r="$(mktemp -d "$_W/repo.XXXXXX")"
    ( cd "$r" || exit 1
      git init -q -b main; git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
      echo base > base.txt; git add base.txt; git commit -q -m base
      local b; b="$(git rev-parse HEAD)"
      echo feat > feat.txt; git add feat.txt; git commit -q -m "feature (untrailered)"
      echo "$b $(git rev-parse HEAD) $r" )
}

# Run the verifier; echo whether FEATURE_SHA is in unprovenanced-shas.txt + the status line.
# args: <ledger-or-empty> <repo> <base> <feat>
_run() {
    local ledger="$1" repo="$2" base="$3" feat="$4" ad; ad="$(mktemp -d "$_W/art.XXXXXX")"
    PATH="$MOCK:$PATH" DSO_REPO_PATH="$repo" DSO_BASE_SHA="$base" DSO_SESSION_HEAD="$feat" \
      DSO_ARTIFACT_DIR="$ad" DSO_GH_REPO="navapbc/test" GH_RETRY_MAX=1 \
      DSO_ADMIN_EXEMPTION_LEDGER="$ledger" \
      bash "$SCRIPT" >"$ad/out.txt" 2>&1
    local unprov="absent"; [[ -f "$ad/unprovenanced-shas.txt" ]] && grep -q "$feat" "$ad/unprovenanced-shas.txt" && unprov="yes"
    local exempt="no"; grep -q "status=ADMIN_EXEMPT" "$ad/out.txt" && exempt="yes"
    echo "$unprov $exempt"
}

# ── A1: valid fp-recovery exemption -> covered (not unprovenanced) ────────────
read -r B F R < <(_repo)
L="$_W/a1.ledger"; bash "$LEDGER_LIB" append "$L" "$F" "fp-recovery" "opus 0 findings" 1700000000
read -r unprov exempt < <(_run "$L" "$R" "$B" "$F")
if [[ "$unprov" == "absent" || "$unprov" == "no" ]] && [[ "$exempt" == "yes" ]]; then _pass "A1_fp_recovery_exemption_covered"; else _fail "A1_fp_recovery_exemption_covered" "unprov=$unprov exempt=$exempt"; fi

# ── A2: no ledger -> unprovenanced (fail-closed baseline) ────────────────────
read -r B F R < <(_repo)
read -r unprov exempt < <(_run "" "$R" "$B" "$F")
if [[ "$unprov" == "yes" ]] && [[ "$exempt" == "no" ]]; then _pass "A2_no_ledger_unprovenanced"; else _fail "A2_no_ledger_unprovenanced" "unprov=$unprov exempt=$exempt"; fi

# ── A3: forged HMAC entry -> unprovenanced (fail-closed) ─────────────────────
read -r B F R < <(_repo)
L="$_W/a3.ledger"
printf '%s\t%s\t%s\t%s\t%s\n' "$F" "$(printf fp-recovery|base64|tr -d '\n')" "$(printf x|base64|tr -d '\n')" 1700000000 "deadbeefforgedmac" > "$L"
read -r unprov exempt < <(_run "$L" "$R" "$B" "$F")
if [[ "$unprov" == "yes" ]] && [[ "$exempt" == "no" ]]; then _pass "A3_forged_unprovenanced"; else _fail "A3_forged_unprovenanced" "unprov=$unprov exempt=$exempt"; fi

# ── A4: exempt_by != fp-recovery -> unprovenanced (C2 class filter) ──────────
read -r B F R < <(_repo)
L="$_W/a4.ledger"; bash "$LEDGER_LIB" append "$L" "$F" "some-other-class" "signed but wrong class" 1700000000
read -r unprov exempt < <(_run "$L" "$R" "$B" "$F")
if [[ "$unprov" == "yes" ]] && [[ "$exempt" == "no" ]]; then _pass "A4_other_class_unprovenanced"; else _fail "A4_other_class_unprovenanced" "unprov=$unprov exempt=$exempt"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
