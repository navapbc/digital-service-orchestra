#!/usr/bin/env bash
# tests/scripts/test-check-allowlist-correctness.sh — W5
#
# The independent allowlist-correctness gate must (a) PASS on the shipped
# allowlist and (b) FAIL on any allowlist that would let a reviewable/critical
# file skip review (catch-all, code glob, or a critical-file entry).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/ci/check-allowlist-correctness.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-w5.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

# ── T1: the shipped allowlist passes ────────────────────────────────────────
out="$(bash "$CHECK" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "no code/critical file matched" <<<"$out"; then _pass "T1_shipped_allowlist_safe"; else _fail "T1_shipped_allowlist_safe" "rc=$rc out=$out"; fi

# ── T2: a code glob (*.py) is rejected ──────────────────────────────────────
printf 'docs/**\n*.py\n' > "$_W/code.conf"
out="$(ALLOWLIST_OVERRIDE="$_W/code.conf" bash "$CHECK" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "reviewable code file" <<<"$out" && grep -q "app/main.py" <<<"$out"; then _pass "T2_code_glob_rejected"; else _fail "T2_code_glob_rejected" "rc=$rc out=$out"; fi

# ── T3: a catch-all (*) is rejected ─────────────────────────────────────────
printf '*\n' > "$_W/catchall.conf"
out="$(ALLOWLIST_OVERRIDE="$_W/catchall.conf" bash "$CHECK" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "catch-all pattern" <<<"$out"; then _pass "T3_catchall_rejected"; else _fail "T3_catchall_rejected" "rc=$rc out=$out"; fi

# ── T4: a critical-file entry (CLAUDE.md) is rejected ───────────────────────
printf 'docs/**\nCLAUDE.md\n' > "$_W/critical.conf"
out="$(ALLOWLIST_OVERRIDE="$_W/critical.conf" bash "$CHECK" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "critical-must-review file 'CLAUDE.md'" <<<"$out"; then _pass "T4_critical_file_rejected"; else _fail "T4_critical_file_rejected" "rc=$rc out=$out"; fi

# ── T5: a .github/workflows glob is rejected (CI/CD must be reviewed) ────────
printf 'docs/**\n.github/workflows/**\n' > "$_W/wf.conf"
out="$(ALLOWLIST_OVERRIDE="$_W/wf.conf" bash "$CHECK" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q ".github/workflows/ci.yml" <<<"$out"; then _pass "T5_workflows_glob_rejected"; else _fail "T5_workflows_glob_rejected" "rc=$rc out=$out"; fi

# ── T6: a genuinely-inert allowlist passes (no instruction surfaces) ─────────
# story 3783: docs/** is NO LONGER a safe allowlist entry (it is a behavior-bearing
# instruction surface). A safe allowlist contains only genuinely-inert artifacts.
printf '*.png\npackage-lock.json\n.tickets-tracker/**\n' > "$_W/safe.conf"
out="$(ALLOWLIST_OVERRIDE="$_W/safe.conf" bash "$CHECK" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then _pass "T6_inert_allowlist_passes"; else _fail "T6_inert_allowlist_passes" "rc=$rc out=$out"; fi

# ── T7: an allowlist containing docs/** is REJECTED (3783 instruction-surface) ─
# Documentation is a behavior-bearing instruction surface — allowlisting docs/**
# would let an un-reviewed doc edit skip review (an attack vector). The correctness
# check must reject it via the _INSTRUCTION_PROBES set.
printf 'docs/**\n*.png\n' > "$_W/docs.conf"
out="$(ALLOWLIST_OVERRIDE="$_W/docs.conf" bash "$CHECK" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "behavior-bearing instruction surface 'docs" <<<"$out"; then _pass "T7_docs_allowlist_rejected"; else _fail "T7_docs_allowlist_rejected" "rc=$rc out=$out"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
