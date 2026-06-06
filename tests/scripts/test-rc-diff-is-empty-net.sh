#!/usr/bin/env bash
# tests/scripts/test-rc-diff-is-empty-net.sh — c9e9 unit test
#
# Drives the PRODUCTION rc_diff_is_empty_net (review-coverage-lib.sh) over REAL git
# fixtures. This is the SHARED "genuinely-empty net diff" exemption helper, a sibling
# of rc_diff_is_tickets_only, recognizing a review-exempt class distinct from the
# I-1 empty-file-list fail-closed case: a 2+-parent MERGE whose combined (--cc) diff
# is EMPTY (rc==0, zero file entries) carries no net change to review.
#
# SAFETY CRUX (preserve exactly): rc==0 is MANDATORY. Emptiness alone NEVER implies
# "genuinely empty" — an uncomputable diff-tree (bad sha, rc!=0) also produces empty
# output and MUST be ERROR (2), so every caller fails closed on doubt.
#
#   E1 clean 2-parent empty-net merge          -> EXEMPT (0)
#   E2 clean octopus (3-parent) empty-net merge -> EXEMPT (0)
#   E3 evil 2-parent merge (own content in merge) -> NOT exempt (1)
#       NOTE: a CLEAN auto-merge of disjoint, non-conflicting changes has an EMPTY
#       --cc combined diff by definition (--cc only shows paths differing from ALL
#       parents), so it is correctly empty-net/EXEMPT — the not-exempt cases are the
#       merges that introduce OWN content: conflict-resolution (E4) and evil (E3/E6).
#   E4 conflict-resolution merge (own content)  -> NOT exempt (1)
#   E5 single-parent content commit             -> NOT exempt (1)   (not a merge)
#   E6 evil octopus (own content in merge)      -> NOT exempt (1)
#   E7 bogus / unknown SHA                       -> ERROR (2)        (fail closed)

set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/review-coverage-lib.sh"   # shim-exempt: test sources the lib under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-emptynet.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
R="$_W/repo"; mkdir -p "$R"
(
  cd "$R" || exit 1
  git init -q -b main
  git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
  echo base > README.md; git add README.md; git commit -q -m base
  base_sha="$(git rev-parse HEAD)"

  # E1 clean 2-parent empty-net merge: a side branch whose change is identical to
  # what main already has (so the merge introduces NO net change in the combined diff).
  git checkout -q -b e1side "$base_sha"
  echo shared > shared.txt; git add shared.txt; git commit -q -m e1-side
  git checkout -q main
  echo shared > shared.txt; git add shared.txt; git commit -q -m e1-main
  git merge -q --no-ff -m "e1 empty-net merge" e1side || true
  git rev-parse HEAD > "$_W/E1"
  e1_after="$(git rev-parse HEAD)"

  # E2 clean octopus (3-parent) empty-net merge. Two side branches that each add a
  # file ALSO added identically on main before the merge -> combined --cc diff empty.
  git checkout -q -b e2a "$e1_after"
  echo o1 > oct1.txt; git add oct1.txt; git commit -q -m e2a
  git checkout -q -b e2b "$e1_after"
  echo o2 > oct2.txt; git add oct2.txt; git commit -q -m e2b
  git checkout -q main
  echo o1 > oct1.txt; echo o2 > oct2.txt; git add oct1.txt oct2.txt; git commit -q -m e2-main
  git merge -q --no-ff -m "e2 octopus empty-net" e2a e2b || true
  git rev-parse HEAD > "$_W/E2"
  e2_after="$(git rev-parse HEAD)"

  # E3 evil 2-parent merge: a 2-parent merge whose merge commit carries OWN content
  # (a file no parent has) -> --cc combined diff is NON-empty (differs from both
  # parents). A clean auto-merge of disjoint changes would be empty-net by --cc
  # semantics, so the not-exempt case must introduce content IN the merge itself.
  git checkout -q -b e3side "$e2_after"
  echo c3 > content3.txt; git add content3.txt; git commit -q -m e3-side
  git checkout -q main
  echo unrel > unrel3.txt; git add unrel3.txt; git commit -q -m e3-main
  git merge -q --no-ff --no-commit e3side >/dev/null 2>&1 || true
  echo evil3 > evil3.txt; git add -A
  git commit -q -m "e3 evil 2-parent merge"
  git rev-parse HEAD > "$_W/E3"
  e3_after="$(git rev-parse HEAD)"

  # E4 conflict-resolution merge with OWN content: both sides edit the same line
  # differently; the merge commit carries a resolution -> non-empty combined diff.
  echo line > conflict.txt; git add conflict.txt; git commit -q -m e4-seed
  e4_seed="$(git rev-parse HEAD)"
  git checkout -q -b e4side "$e4_seed"
  echo sideval > conflict.txt; git add conflict.txt; git commit -q -m e4-side
  git checkout -q main
  echo mainval > conflict.txt; git add conflict.txt; git commit -q -m e4-main
  git merge -q --no-ff -m "e4 conflict merge" e4side >/dev/null 2>&1 || {
    echo resolved > conflict.txt; git add conflict.txt
    git commit -q --no-edit
  }
  git rev-parse HEAD > "$_W/E4"
  e4_after="$(git rev-parse HEAD)"

  # E5 single-parent content commit (not a merge).
  echo e5 > five.txt; git add five.txt; git commit -q -m e5-single
  git rev-parse HEAD > "$_W/E5"
  e5_after="$(git rev-parse HEAD)"

  # E6 evil octopus: octopus merge that carries OWN content (a file no parent has)
  # -> combined diff non-empty.
  git checkout -q -b e6a "$e5_after"
  echo a6 > e6a.txt; git add e6a.txt; git commit -q -m e6a
  git checkout -q -b e6b "$e5_after"
  echo b6 > e6b.txt; git add e6b.txt; git commit -q -m e6b
  git checkout -q main
  git merge -q --no-ff --no-commit e6a e6b >/dev/null 2>&1 || true
  echo evil > evil6.txt; git add -A
  git commit -q -m "e6 evil octopus"
  git rev-parse HEAD > "$_W/E6"
) || { echo "FIXTURE SETUP FAILED"; exit 1; }

# shellcheck source=/dev/null
source "$LIB"

_verdict() { # _verdict <sha> ; echoes rc
  ( cd "$R" && rc_diff_is_empty_net "$1" >/dev/null 2>&1; echo $? )
}

_assert() { # _assert <name> <got> <want>
    if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1" "rc=$2 want $3"; fi
}
_assert "E1 clean 2-parent empty-net merge -> exempt"   "$(_verdict "$(cat "$_W/E1")")" 0
_assert "E2 clean octopus empty-net merge -> exempt"    "$(_verdict "$(cat "$_W/E2")")" 0
_assert "E3 content merge -> not exempt"                "$(_verdict "$(cat "$_W/E3")")" 1
_assert "E4 conflict-resolution merge -> not exempt"    "$(_verdict "$(cat "$_W/E4")")" 1
_assert "E5 single-parent content commit -> not exempt" "$(_verdict "$(cat "$_W/E5")")" 1
_assert "E6 evil octopus -> not exempt"                 "$(_verdict "$(cat "$_W/E6")")" 1
_assert "E7 bogus SHA -> error (fail closed)"           "$(_verdict "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")" 2

echo ""
echo "=== test-rc-diff-is-empty-net.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
