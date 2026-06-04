#!/usr/bin/env bash
# tests/scripts/test-dangling-references-sg-matcher.sh
#
# Story 29e7 (CF-8 / E7): sg-based reference matcher for check-dangling-references.sh.
# These tests target the NEW behavior beyond the original 6-case suite:
#   N1  comment-only surviving mention of a removed symbol is NOT a false positive
#   N2  string-literal-only surviving mention is NOT a false positive
#   N3  a real code reference IS still caught (regression guard for the sg path)
#   N4  the git-grep fallback path (sg forced absent) still catches real refs
#   N5  short-symbol guard: a removed very-short symbol is not scanned (no FP)
#   N6  doc/config carrier (.md/.yml) surviving mention of a removed symbol IS caught
#
# N1/N2 are the load-bearing false-positive cases: with the OLD `git grep -nwE`
# reference scan these RED (a comment/string mention green-lit a false dangling
# report); the sg path must report clean.

set -uo pipefail
unset GITHUB_BASE_REF GITHUB_SHA GITHUB_REPOSITORY

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/ci/check-dangling-references.sh"

PASS=0; FAIL=0; SKIP=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }
_skip() { echo "SKIP: $1 ($2)"; SKIP=$((SKIP+1)); }

# N1/N2 assert ast-grep's comment/string-aware FP elimination — meaningful ONLY
# when the REAL ast-grep binary is present. On Linux bare `sg` is shadow-utils
# (a different tool), so detect ast-grep specifically and skip (not fail) the
# FP-elimination cases when it is absent (the git-grep fallback cannot do it).
_HAVE_ASTGREP=0
if command -v ast-grep >/dev/null 2>&1 \
   || { command -v sg >/dev/null 2>&1 && sg --version 2>/dev/null | grep -qi 'ast-grep'; }; then
    _HAVE_ASTGREP=1
fi

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-sg-matcher.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

_newrepo() {
    local r="$1"
    git -C "$r" init -q -b main
    git -C "$r" config user.email t@e.st; git -C "$r" config user.name t
    git -C "$r" config commit.gpgsign false
}
_origin() {
    local r="$1"
    git -C "$r" init -q --bare "$r/origin.git"
    git -C "$r" remote add origin "$r/origin.git"; git -C "$r" push -q origin main
}
_run() { local r="$1"; shift; ( cd "$r" && env DSO_HEAD_SHA="$(git -C "$r" rev-parse HEAD)" "$@" bash "$CHECK" ) 2>&1; }

# ── N1: removed symbol surviving ONLY in a comment → NOT dangling (no FP) ─────
r="$_W/n1"; mkdir -p "$r"; _newrepo "$r"
printf 'compute_total() {\n  echo 1\n}\n' > "$r/lib.sh"
printf '. ./lib.sh\ncompute_total\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm base
_origin "$r"
# head: remove the def AND the call; only a comment mentions it.
printf '# compute_total removed\n' > "$r/lib.sh"
printf '. ./lib.sh\n# compute_total used to be called here\necho done\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm "drop compute_total, comment remains"
out="$(_run "$r")"; rc=$?
if [[ $_HAVE_ASTGREP -eq 0 ]]; then _skip "N1_comment_only_not_false_positive" "ast-grep absent — FP elimination not available"
elif [[ $rc -eq 0 ]] && grep -q "no dangling references" <<<"$out"; then _pass "N1_comment_only_not_false_positive"; else _fail "N1_comment_only_not_false_positive" "rc=$rc out=$out"; fi

# ── N2: removed symbol surviving ONLY in a string literal → NOT dangling ──────
r="$_W/n2"; mkdir -p "$r"; _newrepo "$r"
printf 'def compute_sum(x):\n    return x\n' > "$r/mod.py"
printf 'from mod import compute_sum\ncompute_sum(1)\n' > "$r/app.py"
git -C "$r" add mod.py app.py; git -C "$r" commit -qm base
_origin "$r"
printf '# compute_sum gone\n' > "$r/mod.py"
printf 'msg = "please run compute_sum manually"\nprint(msg)\n' > "$r/app.py"
git -C "$r" add mod.py app.py; git -C "$r" commit -qm "drop compute_sum, only a string mentions it"
out="$(_run "$r")"; rc=$?
if [[ $_HAVE_ASTGREP -eq 0 ]]; then _skip "N2_string_only_not_false_positive" "ast-grep absent — FP elimination not available"
elif [[ $rc -eq 0 ]] && grep -q "no dangling references" <<<"$out"; then _pass "N2_string_only_not_false_positive"; else _fail "N2_string_only_not_false_positive" "rc=$rc out=$out"; fi

# ── N3: real code reference still caught via sg path (true positive) ──────────
r="$_W/n3"; mkdir -p "$r"; _newrepo "$r"
printf 'def compute_sum(x):\n    return x\n' > "$r/mod.py"
printf 'from mod import compute_sum\nresult = compute_sum(2)\n' > "$r/app.py"
git -C "$r" add mod.py app.py; git -C "$r" commit -qm base
_origin "$r"
printf '# compute_sum gone\n' > "$r/mod.py"
git -C "$r" add mod.py; git -C "$r" commit -qm "drop compute_sum, real call remains"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "SYMBOL 'compute_sum'" <<<"$out" && grep -q "app.py" <<<"$out"; then _pass "N3_real_ref_caught_sg"; else _fail "N3_real_ref_caught_sg" "rc=$rc out=$out"; fi

# ── N4: git-grep FALLBACK path (sg forced absent) still catches a real ref ───
r="$_W/n4"; mkdir -p "$r"; _newrepo "$r"
printf 'greet_user() { echo hi; }\n' > "$r/lib.sh"
printf '. ./lib.sh\ngreet_user\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm base
_origin "$r"
printf '# greet_user gone\n' > "$r/lib.sh"
git -C "$r" add lib.sh; git -C "$r" commit -qm "drop greet_user"
out="$(_run "$r" DSO_DANGLING_FORCE_NO_SG=1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "SYMBOL 'greet_user'" <<<"$out" && grep -q "caller.sh" <<<"$out"; then _pass "N4_fallback_path_catches_real_ref"; else _fail "N4_fallback_path_catches_real_ref" "rc=$rc out=$out"; fi

# ── N5: short-symbol guard — a removed 2-char symbol is not scanned (no FP) ───
# `id` is below the default min-len(3); even though a surviving textual call
# remains, the guard suppresses it (short identifiers are coincidence-dominated).
r="$_W/n5"; mkdir -p "$r"; _newrepo "$r"
printf 'id() { echo 1; }\n' > "$r/lib.sh"
printf '. ./lib.sh\nid\n' > "$r/caller.sh"
git -C "$r" add lib.sh caller.sh; git -C "$r" commit -qm base
_origin "$r"
printf '# id gone\n' > "$r/lib.sh"
git -C "$r" add lib.sh; git -C "$r" commit -qm "drop id"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "no dangling references" <<<"$out"; then _pass "N5_short_symbol_guard_suppresses"; else _fail "N5_short_symbol_guard_suppresses" "rc=$rc out=$out"; fi

# ── N6: doc/config carrier — surviving mention in .md AND .yml IS caught ──────
r="$_W/n6"; mkdir -p "$r"; _newrepo "$r"
printf 'run_pipeline() { echo go; }\n' > "$r/lib.sh"
printf 'See run_pipeline for details.\n' > "$r/README.md"
printf 'steps:\n  - run_pipeline\n' > "$r/ci.yml"
git -C "$r" add lib.sh README.md ci.yml; git -C "$r" commit -qm base
_origin "$r"
printf '# run_pipeline gone\n' > "$r/lib.sh"
git -C "$r" add lib.sh; git -C "$r" commit -qm "drop run_pipeline, docs still reference it"
out="$(_run "$r")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "SYMBOL 'run_pipeline'" <<<"$out" && grep -q "README.md" <<<"$out" && grep -q "ci.yml" <<<"$out"; then _pass "N6_doc_config_reference_caught"; else _fail "N6_doc_config_reference_caught" "rc=$rc out=$out"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL  SKIPPED: $SKIP"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
