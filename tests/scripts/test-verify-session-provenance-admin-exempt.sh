#!/usr/bin/env bash
# tests/scripts/test-verify-session-provenance-admin-exempt.sh
#
# Behavioral tests for the IDENTITY-BASED admin exemption in
# verify-session-provenance.sh (ADR-0022, supersedes the HMAC ledger). A commit
# whose covering merged PR was merged by a designated bypass-actor (server-set
# merged_by.id ∈ the configured set) must classify as PROVENANCED (covered), so
# the downstream llm-review dispatcher SKIPs it (no second admin override). The
# check is FAIL-CLOSED: no covering PR, or a covering PR merged by a non-bypass
# actor with no passing review, leaves the commit UNPROVENANCED.
#
#   I1 covering PR merged_by ∈ bypass set      -> covered (NOT unprovenanced),
#      EVEN with no passing review check (it's an admin bypass).
#   I2 no covering PR                          -> unprovenanced (fail-closed baseline)
#   I3 covering PR merged_by ∉ set, no review  -> unprovenanced (no laundering)
#   I4 covering PR merged_by ∉ set, review PASS -> covered (review path intact)

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"  # shim-exempt: test invokes the script under test by path

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/vsp-id.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

BYPASS_ID=207596960

# Mock gh: `commits/<sha>/pulls` returns one covering merged PR #77 with
# merged_by.id=$MOCK_MERGED_BY (unless MOCK_PULLS=empty -> []). check-runs returns a
# success run iff MOCK_CHECK=passed, else empty.
MOCK="$_W/mockbin"; mkdir -p "$MOCK"
cat > "$MOCK/gh" <<'GH'
#!/usr/bin/env bash
arg="$*"
# LIST endpoint (/commits/{sha}/pulls): real API omits merged_by (null/absent).
if [[ "$arg" == *"/commits/"* && "$arg" == *"/pulls"* ]]; then
  if [[ "${MOCK_PULLS:-cover}" == empty ]]; then echo "[]"; exit 0; fi
  printf '%s' '[{"number":77,"state":"closed","merged_at":"2026-06-04T00:00:00Z","merge_commit_sha":"zzzfixedmergecommit","head":{"sha":"deadbeefhead"}}]'
  exit 0
fi
# Single-PR GET (/pulls/77): merged_by present. Code calls with --jq '.merged_by.id'.
if [[ "$arg" == *"/pulls/77"* ]]; then
  if [[ "$arg" == *"--jq"* ]]; then printf '%s' "${MOCK_MERGED_BY:-}"; else printf '%s' '{"merged_by":{"id":'"${MOCK_MERGED_BY:-0}"'}}'; fi
  exit 0
fi
if [[ "$arg" == *"/check-runs"* ]]; then
  if [[ "${MOCK_CHECK:-none}" == passed ]]; then
    printf '%s' '{"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"success"}]}'
  else
    printf '%s' '{"check_runs":[]}'
  fi
  exit 0
fi
echo "[]"; exit 0
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

# Run the verifier; echo "<unprov> <bypass>" — whether FEAT is unprovenanced, and
# whether the bypass-actor status line fired.
# args: <merged_by> <check:none|passed> <pulls:cover|empty> <repo> <base> <feat>
_run() {
    local mb="$1" chk="$2" pulls="$3" repo="$4" base="$5" feat="$6" ad; ad="$(mktemp -d "$_W/art.XXXXXX")"
    PATH="$MOCK:$PATH" DSO_REPO_PATH="$repo" DSO_BASE_SHA="$base" DSO_SESSION_HEAD="$feat" \
      DSO_ARTIFACT_DIR="$ad" DSO_GH_REPO="navapbc/test" GH_RETRY_MAX=1 \
      DSO_RULESET_BYPASS_USER_IDS="$BYPASS_ID" \
      MOCK_MERGED_BY="$mb" MOCK_CHECK="$chk" MOCK_PULLS="$pulls" \
      bash "$SCRIPT" >"$ad/out.txt" 2>&1
    local unprov="absent"; [[ -f "$ad/unprovenanced-shas.txt" ]] && grep -q "$feat" "$ad/unprovenanced-shas.txt" && unprov="yes"
    local bypass="no"; grep -q "merged-by-bypass-actor" "$ad/out.txt" && bypass="yes"
    echo "$unprov $bypass"
}

# ── I1: covering PR merged by bypass-actor -> covered (even w/ no review) ─────
read -r B F R < <(_repo)
read -r unprov bypass < <(_run "$BYPASS_ID" none cover "$R" "$B" "$F")
if [[ "$unprov" != "yes" && "$bypass" == "yes" ]]; then _pass "I1_bypass_merge_covered"; else _fail "I1_bypass_merge_covered" "unprov=$unprov bypass=$bypass"; fi

# ── I2: no covering PR -> unprovenanced (fail-closed baseline) ───────────────
read -r B F R < <(_repo)
read -r unprov bypass < <(_run 0 none empty "$R" "$B" "$F")
if [[ "$unprov" == "yes" && "$bypass" == "no" ]]; then _pass "I2_no_covering_unprovenanced"; else _fail "I2_no_covering_unprovenanced" "unprov=$unprov bypass=$bypass"; fi

# ── I3: covering PR merged by NON-bypass actor, no review -> unprovenanced ────
read -r B F R < <(_repo)
read -r unprov bypass < <(_run 999 none cover "$R" "$B" "$F")
if [[ "$unprov" == "yes" && "$bypass" == "no" ]]; then _pass "I3_nonbypass_no_review_unprovenanced"; else _fail "I3_nonbypass_no_review_unprovenanced" "unprov=$unprov bypass=$bypass"; fi

# ── I4: covering PR merged by NON-bypass actor, review PASSED -> covered ──────
read -r B F R < <(_repo)
read -r unprov bypass < <(_run 999 passed cover "$R" "$B" "$F")
if [[ "$unprov" != "yes" && "$bypass" == "no" ]]; then _pass "I4_passing_review_covered"; else _fail "I4_passing_review_covered" "unprov=$unprov bypass=$bypass"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
