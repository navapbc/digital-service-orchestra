#!/usr/bin/env bash
# tests/scripts/test-review-coverage-backoff.sh — story 7b77 (CF-6) DD2/DD3
#
# Behavioral tests for the coverage-invariant gh retry/backoff CLASSIFIER. The
# coverage invariant must NOT wedge the team on a single transient blip: a
# transient error (5xx / rate-limit / timeout) is retried with bounded backoff
# before blocking; a config error (auth/scope) blocks IMMEDIATELY (retry won't
# help). Asserts observable behavior (return code class + call count), never
# internal sleep timing (backoff delay forced to 0 in tests).
#
#   K1  classifier: 503 / 429 / "rate limit" / timeout -> "transient"
#   K2  classifier: "Bad credentials" / scope / bare 404 -> "config"
#   K3  backoff: a transient-then-success sequence -> returns 0 (retried, recovered)
#   K4  backoff: persistent transient -> bounded retries then non-zero (block),
#       and it actually retried (call count == max)
#   K5  backoff: config error -> blocks on the FIRST call (NO retry: call count == 1)

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/review-coverage-lib.sh"  # shim-exempt: test sources the lib under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-rcbackoff.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
export GH_RETRY_MAX=3 GH_BACKOFF_INITIAL=0   # bound + no real sleep

# shellcheck source=/dev/null
source "$LIB"

# A mock gh that emits a scripted error/success and records each invocation.
# $MOCK_BEHAVIOR: 'fail_then_ok:<n>:<errtext>' (fail n times w/ errtext then ok)
#                 'always:<errtext>' (always fail with errtext)
CALLS="$_W/calls"; : > "$CALLS"
_mockbin="$_W/bin"; mkdir -p "$_mockbin"
cat > "$_mockbin/gh" <<MOCK
#!/usr/bin/env bash
echo x >> "$CALLS"
n=\$(wc -l < "$CALLS" | tr -d ' ')
case "\${MOCK_BEHAVIOR%%:*}" in
  fail_then_ok)
    lim=\$(echo "\$MOCK_BEHAVIOR" | cut -d: -f2)
    err=\$(echo "\$MOCK_BEHAVIOR" | cut -d: -f3-)
    if (( n <= lim )); then echo "\$err" >&2; exit 1; fi
    echo '{"ok":true}'; exit 0 ;;
  always)
    err=\$(echo "\$MOCK_BEHAVIOR" | cut -d: -f2-)
    echo "\$err" >&2; exit 1 ;;
esac
echo '{}'; exit 0
MOCK
chmod +x "$_mockbin/gh"
export DSO_GH_BIN="$_mockbin/gh"

# ── K1: classifier transient ─────────────────────────────────────────────────
ok=1
for e in "HTTP 503 Service Unavailable" "API rate limit exceeded" "429 Too Many Requests" "request timed out"; do
    [[ "$(_rc_classify_gh_error "$e")" == "transient" ]] || ok=0
done
if [[ $ok -eq 1 ]]; then _pass "K1_classifier_transient"; else _fail "K1_classifier_transient" "a transient pattern misclassified"; fi

# ── K2: classifier config ────────────────────────────────────────────────────
ok=1
for e in "Bad credentials (401)" "token is missing the 'repo' scope" "HTTP 404 Not Found"; do
    [[ "$(_rc_classify_gh_error "$e")" == "config" ]] || ok=0
done
if [[ $ok -eq 1 ]]; then _pass "K2_classifier_config"; else _fail "K2_classifier_config" "a config pattern misclassified"; fi

# ── K3: transient-then-success -> 0 ──────────────────────────────────────────
: > "$CALLS"
out="$(MOCK_BEHAVIOR='fail_then_ok:2:HTTP 503 oops' _rc_gh_with_backoff api repos/x/y/commits/z/pulls)"; rc=$?
if [[ $rc -eq 0 && "$out" == *'"ok":true'* ]]; then _pass "K3_transient_then_success"; else _fail "K3_transient_then_success" "rc=$rc out=$out"; fi

# ── K4: persistent transient -> bounded retries then block, count==max ────────
: > "$CALLS"
MOCK_BEHAVIOR='always:HTTP 503 down' _rc_gh_with_backoff api repos/x/y/commits/z/pulls >/dev/null 2>&1; rc=$?
calls=$(wc -l < "$CALLS" | tr -d ' ')
if [[ $rc -ne 0 && "$calls" -eq "$GH_RETRY_MAX" ]]; then _pass "K4_persistent_transient_bounded"; else _fail "K4_persistent_transient_bounded" "rc=$rc calls=$calls max=$GH_RETRY_MAX"; fi

# ── K5: config error -> block on FIRST call (no retry) ────────────────────────
: > "$CALLS"
MOCK_BEHAVIOR='always:Bad credentials' _rc_gh_with_backoff api repos/x/y/commits/z/pulls >/dev/null 2>&1; rc=$?
calls=$(wc -l < "$CALLS" | tr -d ' ')
if [[ $rc -ne 0 && "$calls" -eq 1 ]]; then _pass "K5_config_blocks_immediately"; else _fail "K5_config_blocks_immediately" "rc=$rc calls=$calls (expected 1 — no retry)"; fi

echo ""
echo "=== test-review-coverage-backoff.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
