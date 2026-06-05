#!/usr/bin/env bash
# tests/scripts/test-review-tristate-lib.sh — 3ebb DD1 (tristate gate contract)
#
# Behavioral tests for the review-tristate decidability lattice helper
# (plugins/dso/scripts/lib/review-tristate-lib.sh). The lattice generalizes the
# a85d/precondition-gate.sh exit-78 mode-gate into PASS / FAIL / INDETERMINATE.
#
# LATTICE (LOAD-BEARING, 3ebb DD1):
#   - FAIL is the safe bottom. A genuine review violation (unreviewed SHA)
#     resolves to FAIL and is NEVER retried or downgraded.
#   - When PASS vs INDETERMINATE cannot be distinguished by evidence, resolve to
#     FAIL — never PASS on inferred-benign.
#   - INDETERMINATE ("could not compute the verdict") is retry-able ONLY when the
#     cause is OBSERVABLY transient (5xx / rate-limit / timeout readable from the
#     error). It is NEVER treated as PASS.
#
# EXIT-CODE CONTRACT (docs/contracts/review-tristate-lattice.md):
#   0  PASS            1  FAIL            75 INDETERMINATE    78 PRECONDITION_NOT_MET
#
# Sourced (TRISTATE_LIB_MODE guard) and driven over real inputs; asserts the
# observable verdict string + exit code, never inspects source text.

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/review-tristate-lib.sh"   # shim-exempt: sources the lib under test
# shellcheck disable=SC1090
source "$LIB" >/dev/null 2>&1 || true
PASS=0; FAIL=0
_ok() { echo "PASS: $1"; PASS=$((PASS+1)); }
_no() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

for fn in tristate_classify_verdict tristate_is_transient_error tristate_code_to_name; do
    declare -F "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined after sourcing $LIB"; exit 1; }
done

# ── classify_verdict: <unreviewed_count> <error_count> -> name on stdout, code as rc ──
# T1: no unreviewed, no errors -> PASS (0)
v=$(tristate_classify_verdict 0 0); rc=$?
if [[ "$v" == "PASS" && $rc -eq 0 ]]; then _ok "T1 clean -> PASS/0"; else _no "T1" "got '$v'/$rc"; fi

# T2: a genuine unreviewed SHA -> FAIL (1), even if errors also present (FAIL is the safe bottom)
v=$(tristate_classify_verdict 1 0); rc=$?
if [[ "$v" == "FAIL" && $rc -eq 1 ]]; then _ok "T2 unreviewed -> FAIL/1"; else _no "T2" "got '$v'/$rc"; fi
v=$(tristate_classify_verdict 2 3); rc=$?
if [[ "$v" == "FAIL" && $rc -eq 1 ]]; then _ok "T3 unreviewed+errors -> FAIL/1 (violation dominates)"; else _no "T3" "got '$v'/$rc"; fi

# T4: only errors (could-not-confirm), no genuine unreviewed -> INDETERMINATE (75)
v=$(tristate_classify_verdict 0 1); rc=$?
if [[ "$v" == "INDETERMINATE" && $rc -eq 75 ]]; then _ok "T4 errors-only -> INDETERMINATE/75"; else _no "T4" "got '$v'/$rc"; fi

# ── is_transient_error: returns 0 (retry-able) on observably-transient signatures ──
for msg in "HTTP 503 Service Unavailable" "API rate limit exceeded" "429 Too Many Requests" \
           "gateway timeout" "HTTP 502 Bad Gateway" "connection reset by peer" "i/o timeout (504)"; do
    if tristate_is_transient_error "$msg"; then _ok "T5 transient: '$msg'"; else _no "T5 transient" "'$msg' not detected"; fi
done
# T6: non-transient errors are NOT retry-able (must resolve to FAIL, never silently retried forever)
for msg in "HTTP 404 Not Found" "parse error: unexpected token" "permission denied" "no covering merged PR" "HTTP 401 Unauthorized"; do
    if tristate_is_transient_error "$msg"; then _no "T6 non-transient" "'$msg' wrongly flagged transient"; else _ok "T6 non-transient: '$msg'"; fi
done

# T7: code_to_name round-trips the contract
if [[ "$(tristate_code_to_name 0)" == "PASS" ]]; then _ok "T7 0=PASS"; else _no "T7 0" "$(tristate_code_to_name 0)"; fi
if [[ "$(tristate_code_to_name 1)" == "FAIL" ]]; then _ok "T7 1=FAIL"; else _no "T7 1" "$(tristate_code_to_name 1)"; fi
if [[ "$(tristate_code_to_name 75)" == "INDETERMINATE" ]]; then _ok "T7 75=INDETERMINATE"; else _no "T7 75" "$(tristate_code_to_name 75)"; fi
if [[ "$(tristate_code_to_name 78)" == "PRECONDITION_NOT_MET" ]]; then _ok "T7 78=PRECONDITION_NOT_MET"; else _no "T7 78" "$(tristate_code_to_name 78)"; fi

# ── T8: universal in-channel escalation marker (3ebb DD3) ────────────────────
# An INDETERMINATE verdict routes to /dso:fp-recovery via a standardized,
# greppable marker (no manual git surgery; telemetry-ready).
declare -F tristate_indeterminate_escalation >/dev/null 2>&1 || { echo "FATAL: tristate_indeterminate_escalation not defined"; exit 1; }
out=$(tristate_indeterminate_escalation "review-coverage-invariant" "API 503 mid-walk" "PR#42" 2>&1)
if grep -q "INDETERMINATE_ESCALATION:" <<<"$out" && grep -q "review-coverage-invariant" <<<"$out" && grep -q "/dso:fp-recovery" <<<"$out"; then
    _ok "T8 escalation marker names gate + fp-recovery next action"
else _no "T8 escalation marker" "$out"; fi
# T8b: the marker payload is valid JSON (machine-parseable for routing/telemetry)
mk=$(grep -o 'INDETERMINATE_ESCALATION: .*' <<<"$out" | sed 's/^INDETERMINATE_ESCALATION: //')
if printf '%s' "$mk" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d['gate'] and d['next_action']" 2>/dev/null; then
    _ok "T8b escalation marker is valid JSON with gate + next_action"
else _no "T8b escalation marker JSON" "$mk"; fi
# T8c: a reason containing a double-quote does not break the JSON (sanitized)
out2=$(tristate_indeterminate_escalation "g" 'said "boom"' 2>&1)
mk2=$(grep -o 'INDETERMINATE_ESCALATION: .*' <<<"$out2" | sed 's/^INDETERMINATE_ESCALATION: //')
if printf '%s' "$mk2" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    _ok "T8c escalation marker JSON survives quotes in reason"
else _no "T8c escalation marker JSON quotes" "$mk2"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]]
