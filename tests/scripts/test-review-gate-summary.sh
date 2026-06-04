#!/usr/bin/env bash
# tests/scripts/test-review-gate-summary.sh — 0cd7 DD1/DD2/DD4/DD5
#
# Behavioral test for scripts/ci/review-gate.sh, the single always-runs fail-closed
# CI summary gate (distinct from the local commit-review-gate HOOK tested by
# test-review-gate.sh). Drives the PRODUCTION script with STUB sub-checks
# (overridable script paths) so the aggregation + mode + precondition-mapping logic
# is tested directly, without gh/network. The stubs return the raw rc a real
# sub-check returns AFTER its own internal mode handling (a real sub-check in warn
# mode already returns 0 on a violation; it returns 78 on an unmet precondition
# regardless of mode).
#
#   G1 DD1 BOTH sub-checks always run (even when the first passes)
#   G2 enforce + a sub-check violation (rc=1)            -> gate BLOCKS (exit 1)
#   G3 warn    + a sub-check violation suppressed (rc=0) -> gate exit 0
#   G4 enforce + a sub-check precondition (rc=78)        -> gate FAILS CLOSED (exit 1)
#   G5 warn    + a sub-check precondition (rc=78)        -> gate advisory (exit 0)
#   G6 DD1 second sub-check STILL runs after the first fails (enforce)
#   G7 a MISSING sub-check script                        -> precondition -> enforce blocks
#   G8 invalid mode                                      -> fail closed (exit 1)

set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
REPO_ROOT="$(git rev-parse --show-toplevel)"
GATE="$REPO_ROOT/plugins/dso/scripts/ci/review-gate.sh"          # shim-exempt: invokes the script under test
PRECOND="$REPO_ROOT/plugins/dso/scripts/ci/precondition-gate.sh" # shim-exempt: real precondition mapper

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }
_assert_ec() { # _assert_ec <name> <got> <want>
    if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1" "exit=$2 want $3"; fi
}

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-revgate.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
COV="$_W/cov-stub.sh"; DAN="$_W/dan-stub.sh"
cat > "$COV" <<'S'
#!/usr/bin/env bash
echo "COV_STUB_RAN"
exit "${COV_RC:-0}"
S
cat > "$DAN" <<'S'
#!/usr/bin/env bash
echo "DAN_STUB_RAN"
exit "${DAN_RC:-0}"
S
chmod +x "$COV" "$DAN"

# _gate <mode> <cov_rc> <dan_rc> [cov_path] [dan_path] ; echoes "<exit>|<output>"
_gate() {
    local mode="$1" cov="$2" dan="$3" covp="${4:-$COV}" danp="${5:-$DAN}" out ec
    out="$( DSO_REVIEW_GATE_MODE="$mode" COV_RC="$cov" DAN_RC="$dan" \
            DSO_REVIEW_GATE_COVERAGE_SCRIPT="$covp" \
            DSO_REVIEW_GATE_DANGLING_SCRIPT="$danp" \
            DSO_REVIEW_GATE_PRECOND_SCRIPT="$PRECOND" \
            bash "$GATE" 2>&1 )"
    ec=$?
    printf '%s|%s' "$ec" "$out"
}

# G1: both run, both pass, exit 0
r="$(_gate enforce 0 0)"; ec="${r%%|*}"; out="${r#*|}"
if [[ "$ec" == 0 ]] && grep -q COV_STUB_RAN <<<"$out" && grep -q DAN_STUB_RAN <<<"$out"; then
    _pass "G1 both sub-checks ran + passed (exit 0)"
else _fail "G1" "ec=$ec out=$out"; fi

r="$(_gate enforce 1 0)"; _assert_ec "G2 enforce + violation -> block" "${r%%|*}" 1
r="$(_gate warn 0 0)";    _assert_ec "G3 warn + suppressed violation -> exit 0" "${r%%|*}" 0
r="$(_gate enforce 78 0)"; _assert_ec "G4 enforce + precondition -> fail closed" "${r%%|*}" 1
r="$(_gate warn 78 0)";    _assert_ec "G5 warn + precondition -> advisory" "${r%%|*}" 0

# G6: enforce + coverage fails -> dangling STILL runs (DD1 no short-circuit)
r="$(_gate enforce 1 0)"; ec="${r%%|*}"; out="${r#*|}"
if [[ "$ec" == 1 ]] && grep -q DAN_STUB_RAN <<<"$out"; then
    _pass "G6 second sub-check runs after first fails (DD1)"
else _fail "G6" "ec=$ec out=$out"; fi

r="$(_gate enforce 0 0 "$_W/does-not-exist.sh")"; _assert_ec "G7 missing sub-check -> enforce blocks" "${r%%|*}" 1

# G8: invalid mode -> fail closed
out="$( DSO_REVIEW_GATE_MODE=bogus DSO_REVIEW_GATE_COVERAGE_SCRIPT="$COV" \
        DSO_REVIEW_GATE_DANGLING_SCRIPT="$DAN" DSO_REVIEW_GATE_PRECOND_SCRIPT="$PRECOND" \
        bash "$GATE" 2>&1 )"; ec=$?
_assert_ec "G8 invalid mode -> fail closed" "$ec" 1

echo ""
echo "=== test-review-gate-summary.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
