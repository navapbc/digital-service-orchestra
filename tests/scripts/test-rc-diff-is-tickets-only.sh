#!/usr/bin/env bash
# tests/scripts/test-rc-diff-is-tickets-only.sh — 0cd7 DD3 unit test
#
# Drives the PRODUCTION rc_diff_is_tickets_only (review-coverage-lib.sh) over a real
# git fixture. This is the SHARED diff-scoped exemption helper consumed by all three
# coverage gates (DD3). The exemption is TREE evidence ONLY (git diff-tree), never a
# trailer/marker (the v4 fabricated-trailer lesson). Per the 2026-06-03 KEEP amendment
# the ONLY exempt prefix is the event-sourced ticket store (.tickets-tracker/) — the
# version-file COVERAGE exemption was REMOVED.
#
#   T1 commit touching ONLY .tickets-tracker/* -> EXEMPT (0)
#   T2 commit touching ONLY a code path        -> NOT exempt (1)
#   T3 commit MIXING ticket + code             -> NOT exempt (1)   (no launder)
#   T4 EMPTY commit (no file changes)          -> NOT exempt (1)   (I-1 guard)
#   T5 commit touching MULTIPLE ticket paths   -> EXEMPT (0)
#   T6 bogus / unknown SHA                      -> ERROR (2)        (fail closed)
#   T7 clean MERGE commit (no own diff)         -> NOT exempt (1)   (merge handling
#       is the caller's clean-merge concern, NOT the diff-scoped ticket exemption)

set -uo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/lib/review-coverage-lib.sh"   # shim-exempt: test sources the lib under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-ticketsonly.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
R="$_W/repo"; mkdir -p "$R"
(
  cd "$R" || exit 1
  git init -q -b main
  git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
  mkdir -p .tickets-tracker src
  # base
  echo base > README.md; git add README.md; git commit -q -m base
  # T1 ticket-only
  echo a > .tickets-tracker/t1.json; git add .tickets-tracker/t1.json; git commit -q -m t1
  git rev-parse HEAD > "$_W/T1"
  # T2 code-only
  echo x > src/code.sh; git add src/code.sh; git commit -q -m t2
  git rev-parse HEAD > "$_W/T2"
  # T3 mixed
  echo b > .tickets-tracker/t3.json; echo y > src/more.sh; git add .tickets-tracker/t3.json src/more.sh; git commit -q -m t3
  git rev-parse HEAD > "$_W/T3"
  # T4 empty commit
  git commit -q --allow-empty -m t4
  git rev-parse HEAD > "$_W/T4"
  # T5 multiple ticket paths
  echo c > .tickets-tracker/t5a.json; echo d > .tickets-tracker/t5b.json; git add .tickets-tracker/; git commit -q -m t5
  git rev-parse HEAD > "$_W/T5"
  # T7 clean merge: branch off base, make a ticket commit, merge with no own diff
  base_sha="$(git rev-list --max-parents=0 HEAD)"
  git checkout -q -b sidebr "$base_sha"
  mkdir -p .tickets-tracker
  echo m > .tickets-tracker/mb.json; git add .tickets-tracker/mb.json; git commit -q -m sidecommit
  git checkout -q main
  git merge -q --no-ff -m "merge side" sidebr
  git rev-parse HEAD > "$_W/T7"
) || { echo "FIXTURE SETUP FAILED"; exit 1; }

# shellcheck source=/dev/null
source "$LIB"

_verdict() { # _verdict <sha> ; echoes rc
  ( cd "$R" && rc_diff_is_tickets_only "$1" >/dev/null 2>&1; echo $? )
}

_assert() { # _assert <name> <got> <want> <msg>
    if [[ "$2" == "$3" ]]; then _pass "$4"; else _fail "$1" "rc=$2 want $3"; fi
}
_assert T1 "$(_verdict "$(cat "$_W/T1")")" 0 "T1 ticket-only -> exempt"
_assert T2 "$(_verdict "$(cat "$_W/T2")")" 1 "T2 code-only -> not exempt"
_assert T3 "$(_verdict "$(cat "$_W/T3")")" 1 "T3 mixed -> not exempt (no launder)"
_assert T4 "$(_verdict "$(cat "$_W/T4")")" 1 "T4 empty -> not exempt (I-1)"
_assert T5 "$(_verdict "$(cat "$_W/T5")")" 0 "T5 multi-ticket -> exempt"
_assert T6 "$(_verdict "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")" 2 "T6 bogus SHA -> error (fail closed)"
_assert T7 "$(_verdict "$(cat "$_W/T7")")" 1 "T7 clean merge -> not exempt (caller's concern)"

echo ""
echo "=== test-rc-diff-is-tickets-only.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
