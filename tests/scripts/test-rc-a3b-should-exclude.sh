#!/usr/bin/env bash
# tests/scripts/test-rc-a3b-should-exclude.sh — bug 374f unit test
#
# Drives the PRODUCTION rc_a3b_should_exclude (review-coverage-lib.sh) over REAL git
# fixtures. This is the SHARED A3b self-merge decision: BOTH Goal-1 covering-PR filters
# route through it (review-coverage-lib.sh::rc_sha_is_reviewed AND the G3 routine in
# verify-session-provenance.sh), so the A3b semantics cannot diverge between them.
#
# SEMANTICS (preserve exactly):
#   - mcs_match==0 (covering PR's merge_commit_sha != sha)         -> KEEP (1)
#   - mcs_match==1 AND sha is a 1-parent commit (rebase/squash tip) -> KEEP (1)
#       (patch-identical to reviewed content; G3 still verifies the review passed)
#   - mcs_match==1 AND sha is a >=2-parent genuine merge node       -> EXCLUDE (0)
#   - mcs_match==1 AND topology UNKNOWN (absent / 0-parent boundary) -> EXCLUDE (0)
#       FAIL-CLOSED: only a PROVEN 1-parent tip is kept.
#
# This is the divergence-guard the panel (epic 588e) required: the single shared
# decision is unit-tested here; rc_sha_is_reviewed's T14/T15 and the vsp suites
# exercise it through each caller.

set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/review-coverage-lib.sh"   # shim-exempt: test sources the lib under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-a3b.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
R="$_W/repo"; mkdir -p "$R"
(
  cd "$R" || exit 1
  git init -q -b main
  git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
  echo base > README.md; git add README.md; git commit -q -m base

  # A 1-parent commit (rebase/squash tip class).
  echo tip > tip.txt; git add tip.txt; git commit -q -m "1-parent tip"
  git rev-parse HEAD > "$_W/ONE"

  # A genuine 2-parent merge node.
  git checkout -q -b side HEAD~1
  echo s > side.txt; git add side.txt; git commit -q -m side
  git checkout -q main
  git merge -q --no-ff -m "2-parent merge node" side
  git rev-parse HEAD > "$_W/TWO"
) || { echo "FIXTURE SETUP FAILED"; exit 1; }

# shellcheck source=/dev/null
source "$LIB"

_verdict() { ( cd "$R" && rc_a3b_should_exclude "$1" "$2" >/dev/null 2>&1; echo $? ); }
_assert() { if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1" "rc=$2 want $3"; fi; }

ONE="$(cat "$_W/ONE")"; TWO="$(cat "$_W/TWO")"

# mcs_match==0 -> always KEEP (1), regardless of topology.
_assert "no-merge-match (1-parent) -> keep"        "$(_verdict "$ONE" 0)" 1
_assert "no-merge-match (2-parent) -> keep"        "$(_verdict "$TWO" 0)" 1
# mcs_match==1 -> decide on parent count.
_assert "self-merge match + 1-parent tip -> keep"  "$(_verdict "$ONE" 1)" 1
_assert "self-merge match + 2-parent node -> EXCLUDE" "$(_verdict "$TWO" 1)" 0
# Fail-closed: unknown topology (absent SHA reports empty parent count) -> EXCLUDE.
_assert "self-merge match + absent SHA -> EXCLUDE (fail closed)" \
    "$(_verdict "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 1)" 0
# Default mcs_match (missing arg -> 0) -> keep.
_assert "missing mcs_match arg defaults to keep"   "$( cd "$R" && rc_a3b_should_exclude "$ONE" >/dev/null 2>&1; echo $? )" 1

echo ""
echo "=== test-rc-a3b-should-exclude.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
