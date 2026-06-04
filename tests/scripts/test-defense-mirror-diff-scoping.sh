#!/usr/bin/env bash
# tests/scripts/test-defense-mirror-diff-scoping.sh — epic 588e (defense-mirror pollution)
#
# defense_store_list, given the PR net diff (--base-sha/--head-sha), must scope
# mirrored defenses to lines THIS PR actually changed (±5 proximity — the same axis
# runner.py suppression matches on), NOT merely files it touches. This bounds the
# cross-PR / over-time accumulation the file-overlap filter let through.
#
#   M1 a defense citing a CHANGED line -> emitted
#   M2 a defense citing an unchanged line of the same file (>5 away) -> NOT emitted
#   M3 a defense citing a file NOT in the diff -> NOT emitted
#   M4 a defense citing a line within ±5 of a change -> emitted (proximity)
#   M5 a defense citing a line just OUTSIDE ±5 -> NOT emitted (boundary)
#   M6 no --head/--base (diff unavailable) -> file-overlap fallback (today's behavior)

set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
LIB="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"  # shim-exempt: test sources the lib under test

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-defmirror.XXXXXX")"; trap 'rm -rf "$_W"' EXIT
R="$_W/repo"; mkdir -p "$R"

# ── Build a repo: base foo.sh (60 lines) + bar.sh; head changes foo.sh lines 10-12 ──
(
  cd "$R" || exit 1
  git init -q -b main; git config user.email t@e.st; git config user.name t; git config commit.gpgsign false
  python3 -c "open('foo.sh','w').write(chr(10).join('line%d'%i for i in range(1,61))+chr(10))"
  echo "barbase" > bar.sh
  git add -A; git commit -qm base
  python3 -c "
l=open('foo.sh').read().splitlines()
for i in (9,10,11): l[i]='CHANGED%d'%(i+1)
open('foo.sh','w').write(chr(10).join(l)+chr(10))"
  git add -A; git commit -qm head
)
BASE="$(git -C "$R" rev-parse HEAD~1)"
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"

# ── Orphan 'tt' ref with one DEFENSE_RECORD blob per cited line ───────────────
_mk_blob() { # _mk_blob <id> <cited>
  local id="$1" cited="$2"
  local f=".store/${id}-aaaaaaaa-COMMENT.json"
  mkdir -p "$R/.store"
  python3 -c "
import json,sys
rec={'prior_finding_id':sys.argv[1],'defense_type':'x','defense_text':'d','defender':'x','cited_lines':[sys.argv[2]],'severity_history':[{'cycle':1,'severity':'important'}],'ticket_id':'T1'}
open(sys.argv[3],'w').write(json.dumps({'data':{'body':'DEFENSE_RECORD: '+json.dumps(rec)}}))
" "$id" "$cited" "$R/$f"
}
(
  cd "$R" || exit 1
  git checkout -q --orphan tt; git rm -rq --cached . >/dev/null 2>&1 || true; rm -f foo.sh bar.sh
)
_mk_blob 1700000001 "foo.sh:11:c"   # changed line
_mk_blob 1700000002 "foo.sh:50:c"   # unchanged, far
_mk_blob 1700000003 "bar.sh:1:c"    # file not in diff
_mk_blob 1700000004 "foo.sh:16:c"   # 16-12=4 -> within +-5
_mk_blob 1700000005 "foo.sh:18:c"   # 18-12=6 -> just outside +-5
(
  cd "$R" || exit 1
  git add -A .store; git commit -qm "defense blobs"
  git checkout -q main
)

# ── Run the list with the diff; collect which finding_ids were emitted ────────
_emit() { # _emit [extra args...] -> prints emitted prior_finding_ids
  ( cd "$R" || exit 1
    # shellcheck source=/dev/null
    source "$LIB"
    defense_store_list --all-no-pr-filter --ref tt "$@" 2>/dev/null \
      | python3 -c "import json,sys
for ln in sys.stdin:
    ln=ln.strip()
    if ln.startswith('DEFENSE_RECORD: '):
        print(json.loads(ln[len('DEFENSE_RECORD: '):]).get('prior_finding_id',''))" )
}

OUT="$(_emit --head-sha "$HEAD_SHA" --base-sha "$BASE")"
_has() { grep -qx "$1" <<<"$OUT"; }

if   _has 1700000001; then _pass "M1_changed_line_emitted"; else _fail "M1_changed_line_emitted" "out=$OUT"; fi
if ! _has 1700000002; then _pass "M2_far_unchanged_not_emitted"; else _fail "M2_far_unchanged_not_emitted" "line 50 emitted"; fi
if ! _has 1700000003; then _pass "M3_other_file_not_emitted"; else _fail "M3_other_file_not_emitted" "bar.sh emitted"; fi
if   _has 1700000004; then _pass "M4_proximity_within5_emitted"; else _fail "M4_proximity_within5_emitted" "line 16 dropped"; fi
if ! _has 1700000005; then _pass "M5_proximity_outside5_not_emitted"; else _fail "M5_proximity_outside5_not_emitted" "line 18 emitted"; fi

# ── M6: no diff (no head/base) -> file-overlap fallback emits all that touch the file set ──
# With --all-no-pr-filter and no diff, pr_files is empty -> emit-all (today's escape-hatch).
OUT_NODIFF="$(_emit)"
if grep -qx 1700000002 <<<"$OUT_NODIFF" && grep -qx 1700000001 <<<"$OUT_NODIFF"; then _pass "M6_no_diff_file_fallback_emits_all"; else _fail "M6_no_diff_file_fallback_emits_all" "out=$OUT_NODIFF"; fi

echo ""
echo "=== test-defense-mirror-diff-scoping.sh: PASS=$PASS FAIL=$FAIL ==="
[[ $FAIL -eq 0 ]]
