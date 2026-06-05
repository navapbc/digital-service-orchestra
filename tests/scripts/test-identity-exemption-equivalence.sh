#!/usr/bin/env bash
# tests/scripts/test-identity-exemption-equivalence.sh — ADR-0022 / 0cd7 DD6
#
# SHARED-FIXTURE EQUIVALENCE TEST. The identity-based admin exemption is implemented
# in TWO KEEP-IN-SYNC gates — rc_sha_is_reviewed (review-coverage-lib.sh) and the G3
# loop in verify-session-provenance.sh. The v4 trailer-removal lesson (commit
# 711c3cc9b7) + 0cd7 DD6 warn that two INDEPENDENT per-path tests can both pass while
# the two implementations diverge on a case neither fixture exercises ("the shortcut
# survived in one path after removal from the other"). This test drives BOTH gates
# over the SAME fixtures and asserts they return the IDENTICAL exempt/not verdict —
# the backstop that must exist while the shared helper (0cd7 FAST-FOLLOW) is deferred.
#
# Each scenario = (covering, merged_by, review). Expected exempt/not:
#   E1 covering + bypass-merged + review FAILED -> EXEMPT (admin bypass)         BOTH
#   E2 covering + non-bypass     + review FAILED -> NOT exempt (no launder)      BOTH
#   E3 covering + non-bypass     + review PASSED -> covered (review path)        BOTH
#   E4 no covering PR                            -> NOT covered                  BOTH

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY DSO_RULESET_BYPASS_USER_IDS DSO_RULESET_BYPASS_USER_ID
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/review-coverage-lib.sh"          # shim-exempt: sources the lib under test
VSP="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"        # shim-exempt: invokes the script under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-idequiv.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
BYPASS_ID=314159265
_BIN="$_W/bin"; mkdir -p "$_BIN"

# Shared mock gh, parameterized by env (MOCK_COVERING/MOCK_MERGED_BY/MOCK_CHECK).
# Models the REAL API: the LIST endpoint omits merged_by; /pulls/{n} supplies it.
cat > "$_BIN/gh" <<'GH'
#!/usr/bin/env bash
arg="$*"
if [[ "$arg" == *"/commits/"* && "$arg" == *"/pulls"* ]]; then
  if [[ "${MOCK_COVERING:-yes}" == no ]]; then echo "[]"; exit 0; fi
  printf '%s' '[{"number":50,"state":"closed","merged_at":"2026-06-04T00:00:00Z","merge_commit_sha":"zzmergecommit","head":{"sha":"deadbeefcovhead"}}]'
  exit 0
fi
if [[ "$arg" == *"/pulls/50"* ]]; then
  if [[ "$arg" == *"--jq"* ]]; then printf '%s' "${MOCK_MERGED_BY:-}"; else printf '%s' '{"merged_by":{"id":'"${MOCK_MERGED_BY:-0}"'}}'; fi
  exit 0
fi
if [[ "$arg" == *"/check-runs"* ]]; then
  if [[ "${MOCK_CHECK:-none}" == passed ]]; then printf '%s' '{"check_runs":[{"name":"review-sub-pr","conclusion":"success"}]}'
  else printf '%s' '{"check_runs":[]}'; fi
  exit 0
fi
echo "[]"; exit 0
GH
chmod +x "$_BIN/gh"

# ── lib verdict: run rc_sha_is_reviewed; echo "exempt" iff covered (rc 0) ─────
_lib_verdict() { # _lib_verdict <merged_by> <check> <covering>
    ( DSO_GH_BIN="$_BIN/gh" DSO_RULESET_BYPASS_USER_IDS="$BYPASS_ID" \
      MOCK_MERGED_BY="$1" MOCK_CHECK="$2" MOCK_COVERING="$3" \
      bash -c 'source "'"$LIB"'"; rc_sha_is_reviewed o/r feedfeedfeedfeedfeedfeedfeedfeedfeedfeed 0 >/dev/null 2>&1' \
      && echo exempt || echo not )
}

# ── provenance verdict: run the script over a 1-commit repo; "exempt" iff the
#    feature SHA is NOT in unprovenanced-shas.txt ───────────────────────────────
_prov_verdict() { # _prov_verdict <merged_by> <check> <covering>
    local r ad; r="$(mktemp -d "$_W/repo.XXXXXX")"; ad="$(mktemp -d "$_W/art.XXXXXX")"
    ( cd "$r" || exit 1
      git init -q -b main; git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
      echo base > b.txt; git add b.txt; git commit -q -m base; b="$(git rev-parse HEAD)"
      echo feat > f.txt; git add f.txt; git commit -q -m feat; f="$(git rev-parse HEAD)"
      PATH="$_BIN:$PATH" DSO_REPO_PATH="$r" DSO_BASE_SHA="$b" DSO_SESSION_HEAD="$f" \
        DSO_ARTIFACT_DIR="$ad" DSO_GH_REPO="o/r" GH_RETRY_MAX=1 \
        DSO_RULESET_BYPASS_USER_IDS="$BYPASS_ID" \
        MOCK_MERGED_BY="$1" MOCK_CHECK="$2" MOCK_COVERING="$3" \
        bash "$VSP" >/dev/null 2>&1
      if [[ -f "$ad/unprovenanced-shas.txt" ]] && grep -q "$f" "$ad/unprovenanced-shas.txt"; then echo not; else echo exempt; fi )
}

# ── equivalence over the fixture table ───────────────────────────────────────
# scenario: name  merged_by         check    covering  expected
_run() { # _run <name> <merged_by> <check> <covering> <expected>
    local name="$1" mby="$2" chk="$3" cov="$4" exp="$5" lv pv
    lv="$(_lib_verdict "$mby" "$chk" "$cov")"
    pv="$(_prov_verdict "$mby" "$chk" "$cov")"
    if [[ "$lv" == "$pv" && "$lv" == "$exp" ]]; then _pass "$name (both=$lv)"
    else _fail "$name" "lib=$lv prov=$pv expected=$exp — GATES DISAGREE or wrong"; fi
}

_run "E1_bypass_failed_review_exempt"     "$BYPASS_ID" none   yes exempt
_run "E2_nonbypass_failed_review_notexempt" 999        none   yes not
_run "E3_passed_review_covered"           999          passed yes exempt
_run "E4_no_covering_notcovered"          "$BYPASS_ID" none   no  not

echo ""
echo "=== test-identity-exemption-equivalence.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
