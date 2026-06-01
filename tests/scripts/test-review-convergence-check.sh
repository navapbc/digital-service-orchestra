#!/usr/bin/env bash
# tests/scripts/test-review-convergence-check.sh — W2b/W2c
#
# Convergence detector: a finding flagged → cleared → re-flagged across cycles is
# an oscillation (STALL). A finding flagged then fixed-and-gone converges. The
# cycle cap escalates independently. Finding identity is content-based (cited
# lines), pr_number-free.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/ci/review-convergence-check.sh"
# shellcheck source=../../plugins/dso/scripts/lib/review-finding-identity.sh
source "$REPO_ROOT/plugins/dso/scripts/lib/review-finding-identity.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-w2c.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

_findings() { printf '{"findings":[%s]}' "$1"; }
_f_on() { printf '{"severity":"important","description":"x","cited_lines":["src/foo.py:42"]}'; }   # the finding
_empty() { printf '{"findings":[]}'; }

_run() { # _run <findings-file> <history> <cycle>
    env DSO_CI_REVIEW_FINDINGS_PATH="$1" DSO_CONVERGENCE_HISTORY="$2" DSO_REVIEW_CYCLE="$3" DSO_REVIEW_MAX_CYCLES=4 bash "$CHECK"
}

# ── T0: finding identity is pr_number-free and content-stable ───────────────
fa="$_W/a.json"; _findings "$(_f_on)" > "$fa"
id1="$(compute_finding_ids "$fa")"
# same cited lines, different description prose → same id
printf '{"findings":[{"severity":"minor","description":"TOTALLY DIFFERENT WORDS","cited_lines":["src/foo.py:42"]}]}' > "$_W/b.json"
id2="$(compute_finding_ids "$_W/b.json")"
if [[ -n "$id1" && "$id1" == "$id2" ]]; then _pass "T0_identity_content_stable"; else _fail "T0_identity_content_stable" "id1=$id1 id2=$id2"; fi

# ── T1: cycle 1 flags the finding → converging (records history) ────────────
H="$_W/hist1"; on="$_W/on.json"; _findings "$(_f_on)" > "$on"
out="$(_run "$on" "$H" 1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "decision_record=converging" <<<"$out"; then _pass "T1_cycle1_converging"; else _fail "T1_cycle1_converging" "rc=$rc out=$out"; fi

# ── T2: flag → clear → re-flag = STALL oscillation ──────────────────────────
H="$_W/hist2"; on="$_W/on2.json"; off="$_W/off2.json"
_findings "$(_f_on)" > "$on"; _empty > "$off"
_run "$on"  "$H" 1 >/dev/null      # cycle 1: flagged
_run "$off" "$H" 2 >/dev/null      # cycle 2: cleared
out="$(_run "$on" "$H" 3)"; rc=$?  # cycle 3: re-flagged
if [[ $rc -eq 1 ]] && grep -q "reason=oscillation" <<<"$out"; then _pass "T2_flag_clear_reflag_stalls"; else _fail "T2_flag_clear_reflag_stalls" "rc=$rc out=$out"; fi

# ── T3: flag → still-flagged (no clear between) is NOT oscillation ───────────
H="$_W/hist3"; on="$_W/on3.json"; _findings "$(_f_on)" > "$on"
_run "$on" "$H" 1 >/dev/null
out="$(_run "$on" "$H" 2)"; rc=$?   # present in both 1 and 2, never cleared
if [[ $rc -eq 0 ]]; then _pass "T3_persistent_not_oscillation"; else _fail "T3_persistent_not_oscillation" "rc=$rc out=$out"; fi

# ── T4: flag → cleared and stays gone = converged ───────────────────────────
H="$_W/hist4"; on="$_W/on4.json"; off="$_W/off4.json"
_findings "$(_f_on)" > "$on"; _empty > "$off"
_run "$on"  "$H" 1 >/dev/null
out="$(_run "$off" "$H" 2)"; rc=$?  # cleared, stays gone
if [[ $rc -eq 0 ]] && grep -q "findings=0" <<<"$out"; then _pass "T4_cleared_converges"; else _fail "T4_cleared_converges" "rc=$rc out=$out"; fi

# ── T5: cycle cap exceeded escalates independently ──────────────────────────
H="$_W/hist5"; on="$_W/on5.json"; _findings "$(_f_on)" > "$on"
out="$(env DSO_CI_REVIEW_FINDINGS_PATH="$on" DSO_CONVERGENCE_HISTORY="$H" DSO_REVIEW_CYCLE=5 DSO_REVIEW_MAX_CYCLES=4 bash "$CHECK")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "reason=cycle_cap_exceeded" <<<"$out"; then _pass "T5_cycle_cap_escalates"; else _fail "T5_cycle_cap_escalates" "rc=$rc out=$out"; fi

# ── T6: W2b covered-credit — an id seen-and-cleared in a prior cycle that
#     reappears once is flagged as oscillation (history is the credit ledger). A
#     brand-new id (never in history) on a fresh cycle converges. ──
H="$_W/hist6"; newf="$_W/new6.json"
printf '{"findings":[{"severity":"important","description":"new","cited_lines":["src/new.py:1"]}]}' > "$newf"
out="$(_run "$newf" "$H" 1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "converging" <<<"$out"; then _pass "T6_new_finding_converges"; else _fail "T6_new_finding_converges" "rc=$rc out=$out"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
