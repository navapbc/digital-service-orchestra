#!/usr/bin/env bash
# tests/scripts/test-check-dangling-references.sh — W6 (P2 cross-sub-PR conflict)
#
# A symbol removed/renamed in one change but still referenced at the combined
# HEAD (in an untouched caller or another change's file) is a dangling reference
# that diff-scoped review cannot see. The check must catch it.

set -uo pipefail

# Hermeticity: synthetic fixtures, not a real PR checkout. The check resolves
# origin/$GITHUB_BASE_REF and uses GITHUB_SHA for head resolution; in CI the
# Script Tests job inherits the PR's GITHUB_BASE_REF (e.g. a staged-* base) and
# GITHUB_SHA, neither of which exists in the fixture's origin/main. Clear them.
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/ci/check-dangling-references.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-w6.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

# _newrepo <dir> — init repo with origin/main, return base committed.
_newrepo() {
    local r="$1"
    git -C "$r" init -q -b main
    git -C "$r" config user.email t@e.st; git -C "$r" config user.name t
    git -C "$r" config commit.gpgsign false
}
_origin() { # capture current main as origin/main
    local r="$1"
    git -C "$r" init -q --bare "$r/origin.git"
    git -C "$r" remote add origin "$r/origin.git"; git -C "$r" push -q origin main
}
_run() { local r="$1"; shift; ( cd "$r" && env DSO_HEAD_SHA="$(git -C "$r" rev-parse HEAD)" "$@" bash "$CHECK" ) 2>&1; }

# ── T1: removed symbol still referenced → dangling (exit 1) ──────────────────
r="$_W/t1"; mkdir -p "$r"; _newrepo "$r"
printf 'greet() {\n  echo hi\n}\n' > "$r/lib.sh"
printf '. ./lib.sh\ngreet\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm base
_origin "$r"
# head: remove greet() definition; caller still calls greet
printf '# greet removed\n' > "$r/lib.sh"
git -C "$r" add lib.sh; git -C "$r" commit -qm "drop greet"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "SYMBOL 'greet'" <<<"$out" && grep -q "caller.sh" <<<"$out"; then _pass "T1_dangling_detected"; else _fail "T1_dangling_detected" "rc=$rc out=$out"; fi

# ── T2: renamed with all callers updated → clean (exit 0) ────────────────────
r="$_W/t2"; mkdir -p "$r"; _newrepo "$r"
printf 'greet() {\n  echo hi\n}\n' > "$r/lib.sh"
printf '. ./lib.sh\ngreet\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm base
_origin "$r"
printf 'welcome() {\n  echo hi\n}\n' > "$r/lib.sh"
printf '. ./lib.sh\nwelcome\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm "rename greet->welcome + callers"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "no dangling references" <<<"$out"; then _pass "T2_rename_with_callers_clean"; else _fail "T2_rename_with_callers_clean" "rc=$rc out=$out"; fi

# ── T3: symbol MOVED to another file (still defined at head) → clean ─────────
r="$_W/t3"; mkdir -p "$r"; _newrepo "$r"
printf 'greet() {\n  echo hi\n}\n' > "$r/lib.sh"
printf '. ./lib.sh\ngreet\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm base
_origin "$r"
printf '# moved out\n' > "$r/lib.sh"
printf 'greet() {\n  echo hi\n}\n' > "$r/newlib.sh"
git -C "$r" add lib.sh newlib.sh; git -C "$r" commit -qm "move greet to newlib"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "no dangling references" <<<"$out"; then _pass "T3_moved_symbol_clean"; else _fail "T3_moved_symbol_clean" "rc=$rc out=$out"; fi

# ── T4: warn mode with a dangling ref → exit 0 ──────────────────────────────
r="$_W/t4"; mkdir -p "$r"; _newrepo "$r"
printf 'greet() {\n  echo hi\n}\n' > "$r/lib.sh"
printf '. ./lib.sh\ngreet\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm base
_origin "$r"
printf '# gone\n' > "$r/lib.sh"
git -C "$r" add lib.sh; git -C "$r" commit -qm "drop greet"
out="$(_run "$r" DSO_DANGLING_MODE=warn)"; rc=$?
# warn mode must still DETECT and report the dangling ref (exit 0 + banner is not
# enough — a regression that short-circuits the scan before detecting would pass
# a banner-only assertion). Require the SYMBOL report too.
if [[ $rc -eq 0 ]] && grep -q "MODE=warn" <<<"$out" && grep -q "SYMBOL 'greet'" <<<"$out"; then _pass "T4_warn_mode_detects_but_does_not_block"; else _fail "T4_warn_mode_detects_but_does_not_block" "rc=$rc out=$out"; fi

# ── T5: python def removed but still called → dangling ──────────────────────
r="$_W/t5"; mkdir -p "$r"; _newrepo "$r"
printf 'def parse(x):\n    return x\n' > "$r/mod.py"
printf 'from mod import parse\nparse(1)\n' > "$r/app.py"
git -C "$r" add mod.py app.py; git -C "$r" commit -qm base
_origin "$r"
printf '# parse removed\n' > "$r/mod.py"
git -C "$r" add mod.py; git -C "$r" commit -qm "drop parse"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "SYMBOL 'parse'" <<<"$out" && grep -q "app.py" <<<"$out"; then _pass "T5_python_dangling"; else _fail "T5_python_dangling" "rc=$rc out=$out"; fi

# ── T6: no .sh/.py touched → clean ──────────────────────────────────────────
r="$_W/t6"; mkdir -p "$r"; _newrepo "$r"
printf 'hello\n' > "$r/README.md"
git -C "$r" add README.md; git -C "$r" commit -qm base
_origin "$r"
printf 'hello world\n' > "$r/README.md"
git -C "$r" add README.md; git -C "$r" commit -qm "edit readme"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "no .sh/.py files touched" <<<"$out"; then _pass "T6_no_code_touched_clean"; else _fail "T6_no_code_touched_clean" "rc=$rc out=$out"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
