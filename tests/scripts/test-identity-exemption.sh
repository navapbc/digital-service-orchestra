#!/usr/bin/env bash
# tests/scripts/test-identity-exemption.sh — ADR-0022 identity-based admin exemption
#
# Drives the PRODUCTION rc_sha_is_reviewed (NOT a reimplementation) via a mock gh,
# asserting BOTH polarities so the test cannot pass while the real merged_by
# extraction is broken (the P-IDENTITY-EXEMPT liveness requirement):
#   I1  covering PR merged by a bypass-actor (merged_by ∈ set) -> reviewed-equiv (0)
#       EVEN WITH NO passing review check-run (it's an admin bypass).
#   I2  covering PR merged by a NON-bypass actor + no passing review -> NOT reviewed
#       (1) — the identity path must not launder a normal un-reviewed merge.
#   I3  same covering PR but a PASSING review check-run -> reviewed (0) regardless of
#       merge actor (the review path still works; identity is additive).

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/review-coverage-lib.sh"  # shim-exempt: test sources the lib under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-idexempt.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
BIN="$_W/bin"; mkdir -p "$BIN"
SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
BYPASS_ID=207596960

# Mock gh: pulls -> one covering merged PR #42 whose merged_by.id = $MOCK_MERGED_BY
# (head=$HEAD). check-runs -> $MOCK_CHECK ('none' = empty, 'passed' = a success).
cat > "$BIN/gh" <<MOCK
#!/usr/bin/env bash
arg="\$*"
# LIST endpoint: the REAL GitHub API does NOT include merged_by here (it is null /
# absent in the simple PR representation). Model that — merged_by is intentionally omitted.
if [[ "\$arg" == *"/commits/$SHA/pulls"* ]]; then
  printf '%s' '[{"number":42,"state":"closed","merged_at":"2026-06-04T00:00:00Z","merge_commit_sha":"zzzzzzz","head":{"sha":"$HEAD"}}]'
  exit 0
fi
# Single-PR GET: merged_by IS populated here. The code calls with --jq '.merged_by.id
# // empty', so when --jq is present emit just the id (the mock does not run jq).
if [[ "\$arg" == *"/pulls/42"* ]]; then
  if [[ "\$arg" == *"--jq"* ]]; then printf '%s' "\${MOCK_MERGED_BY:-}"; else printf '%s' '{"merged_by":{"id":'"\${MOCK_MERGED_BY:-0}"'}}'; fi
  exit 0
fi
if [[ "\$arg" == *"/check-runs"* ]]; then
  if [[ "\${MOCK_CHECK:-none}" == passed ]]; then
    printf '%s' '{"check_runs":[{"name":"llm-review","status":"completed","conclusion":"success"}]}'
  else
    printf '%s' '{"check_runs":[]}'
  fi
  exit 0
fi
echo '[]'; exit 0
MOCK
chmod +x "$BIN/gh"
export DSO_GH_BIN="$BIN/gh"

# shellcheck source=/dev/null
source "$LIB"

# ── I1: bypass-actor merge -> reviewed-equivalent, even with NO passing review ──
out="$(DSO_RULESET_BYPASS_USER_IDS="$BYPASS_ID" MOCK_MERGED_BY="$BYPASS_ID" MOCK_CHECK=none rc_sha_is_reviewed "o/r" "$SHA" 0)"; rc=$?
if [[ $rc -eq 0 && "$out" == admin-merged-by:"$BYPASS_ID":* ]]; then _pass "I1_bypass_merge_is_reviewed_equivalent"; else _fail "I1_bypass_merge_is_reviewed_equivalent" "rc=$rc out=$out"; fi

# ── I2: non-bypass merge + no passing review -> NOT reviewed (no laundering) ────
out="$(DSO_RULESET_BYPASS_USER_IDS="$BYPASS_ID" MOCK_MERGED_BY=999 MOCK_CHECK=none rc_sha_is_reviewed "o/r" "$SHA" 0)"; rc=$?
if [[ $rc -eq 1 ]]; then _pass "I2_nonbypass_no_review_not_exempt"; else _fail "I2_nonbypass_no_review_not_exempt" "rc=$rc out=$out (expected 1=not-reviewed)"; fi

# ── I3: passing review -> reviewed regardless of merge actor (review path intact) ─
out="$(DSO_RULESET_BYPASS_USER_IDS="$BYPASS_ID" MOCK_MERGED_BY=999 MOCK_CHECK=passed rc_sha_is_reviewed "o/r" "$SHA" 0)"; rc=$?
if [[ $rc -eq 0 && "$out" == "42:$HEAD" ]]; then _pass "I3_passing_review_still_reviewed"; else _fail "I3_passing_review_still_reviewed" "rc=$rc out=$out"; fi

echo ""
echo "=== test-identity-exemption.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
