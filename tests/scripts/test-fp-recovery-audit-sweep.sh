#!/usr/bin/env bash
# tests/scripts/test-fp-recovery-audit-sweep.sh — W3d (Goal-6b)
#
# The post-hoc audit sweep must emit a tamper-evident HMAC-signed marker for each
# merged main PR that lacks a passing review check, and emit NONE for a properly
# reviewed PR. The HMAC must verify against the key.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SWEEP="$REPO_ROOT/plugins/dso/scripts/ci/fp-recovery-audit-sweep.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-w3d.XXXXXX")"
trap 'rm -rf "$_W"' EXIT
_MOCK="$_W/bin"; mkdir -p "$_MOCK"

# Mock gh: PR #1 reviewed (llm-review success), PR #2 bypassed (no review check).
cat > "$_MOCK/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "api" ]] || { echo "{}"; exit 0; }
p="$2"
case "$p" in
  *pulls\?state=closed*|*pulls?state=closed*)
    echo '[{"number":1,"merged_at":"2026-01-01T00:00:00Z","merge_commit_sha":"m1","head":{"sha":"h1"}},{"number":2,"merged_at":"2026-01-02T00:00:00Z","merge_commit_sha":"m2","head":{"sha":"h2"}}]' ;;
  */commits/h1/check-runs*)
    echo '{"check_runs":[{"name":"llm-review","conclusion":"success"}]}' ;;
  */commits/h2/check-runs*)
    echo '{"check_runs":[{"name":"Hook Tests","conclusion":"success"}]}' ;;  # no review check → bypassed
  *) echo "{}" ;;
esac
MOCK
chmod +x "$_MOCK/gh"

KEY="test-secret-key-123"
out="$(env "PATH=$_MOCK:$PATH" GH_REPO="test/repo" DSO_AUDIT_HMAC_KEY="$KEY" bash "$SWEEP" 2>"$_W/err")"
rc=$?
err="$(cat "$_W/err")"

# T1: sweep succeeds
if [[ $rc -eq 0 ]]; then _pass "T1_sweep_exits_0"; else _fail "T1_sweep_exits_0" "rc=$rc err=$err"; fi

# T2: a marker is emitted for the bypassed PR #2, and NOT for reviewed PR #1
if grep -q '"pr":2' <<<"$out" && ! grep -q '"pr":1' <<<"$out"; then _pass "T2_marker_only_for_bypassed_pr"; else _fail "T2_marker_only_for_bypassed_pr" "out=$out"; fi

# T3: the marker records review_status=missing
if grep -q '"review_status":"missing"' <<<"$out"; then _pass "T3_records_review_status"; else _fail "T3_records_review_status" "out=$out"; fi

# T4: the HMAC verifies against the key (tamper-evidence is real)
marker="$(grep '"pr":2' <<<"$out" | head -1)"
got_hmac="$(printf '%s' "$marker" | python3 -c "import json,sys;print(json.load(sys.stdin)['hmac_sha256'])")"
merge="$(printf '%s' "$marker" | python3 -c "import json,sys;print(json.load(sys.stdin)['merge_sha'])")"
at="$(printf '%s' "$marker" | python3 -c "import json,sys;print(json.load(sys.stdin)['merged_at'])")"
exp_hmac="$(DSO_AUDIT_HMAC_KEY="$KEY" python3 -c "
import hmac,hashlib,os,sys
print(hmac.new(os.environ['DSO_AUDIT_HMAC_KEY'].encode(), sys.argv[1].encode(), hashlib.sha256).hexdigest())
" "2|${merge}|${at}|missing")"
if [[ "$got_hmac" == "$exp_hmac" && -n "$got_hmac" ]]; then _pass "T4_hmac_verifies"; else _fail "T4_hmac_verifies" "got=$got_hmac exp=$exp_hmac"; fi

# T5: a different key produces a different HMAC (signature is key-bound)
wrong_hmac="$(DSO_AUDIT_HMAC_KEY="other-key" python3 -c "
import hmac,hashlib,os,sys
print(hmac.new(os.environ['DSO_AUDIT_HMAC_KEY'].encode(), sys.argv[1].encode(), hashlib.sha256).hexdigest())
" "2|${merge}|${at}|missing")"
if [[ "$wrong_hmac" != "$got_hmac" ]]; then _pass "T5_hmac_is_key_bound"; else _fail "T5_hmac_is_key_bound" "collision"; fi

# T6: missing HMAC key → precondition (exit 78), never an unsigned marker
env "PATH=$_MOCK:$PATH" GH_REPO="test/repo" bash "$SWEEP" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 78 ]]; then _pass "T6_no_key_precondition"; else _fail "T6_no_key_precondition" "rc=$rc"; fi

# T7: output file gets the marker appended when DSO_AUDIT_OUTPUT is set
of="$_W/markers.jsonl"
env "PATH=$_MOCK:$PATH" GH_REPO="test/repo" DSO_AUDIT_HMAC_KEY="$KEY" DSO_AUDIT_OUTPUT="$of" bash "$SWEEP" >/dev/null 2>&1
if [[ -f "$of" ]] && grep -q '"pr":2' "$of"; then _pass "T7_output_file_appended"; else _fail "T7_output_file_appended" "$(cat "$of" 2>/dev/null)"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
