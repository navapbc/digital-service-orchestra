#!/usr/bin/env bash
# tests/scripts/test-review-coverage-invariant.sh — TS-1 (P9 reproduction)
#
# Proves the fail-closed coverage invariant: every origin/main..HEAD SHA must be
# proven reviewed (passing review check-run on a covering merged PR), NEVER
# inferred from reachability. Exercises the P9 sub-cases incl. an admin-bypassed
# sub-PR SHA (covering PR merged but its review check FAILED).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECK="$REPO_ROOT/plugins/dso/scripts/ci/review-coverage-invariant.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_WORK="$(mktemp -d "${TMPDIR:-/tmp}/dso-ts1.XXXXXX")"
trap 'rm -rf "$_WORK"' EXIT

# ── Mock gh: serves canned JSON from $DSO_MOCK_DIR; missing file = API error ──
_MOCK_BIN="$_WORK/bin"; mkdir -p "$_MOCK_BIN"
cat > "$_MOCK_BIN/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "api" ]] || { echo "{}"; exit 0; }
path="$2"
case "$path" in
  */commits/*/pulls)      sha="${path%/pulls}"; sha="${sha##*/commits/}"; f="$DSO_MOCK_DIR/pulls_$sha" ;;
  */commits/*/check-runs) sha="${path%/check-runs}"; sha="${sha##*/commits/}"; f="$DSO_MOCK_DIR/checks_$sha" ;;
  *) echo "{}"; exit 0 ;;
esac
if [[ -f "$f" ]]; then cat "$f"; exit 0; else exit 1; fi   # missing -> API error
MOCK
chmod +x "$_MOCK_BIN/gh"

# Build a repo with origin/main at base + N reachable head commits. Echoes the
# repo path; writes the head commit SHAs (oldest→newest) into $2.
_mk_repo() {
    local repo="$1" shafile="$2"; shift 2
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email t@e.st; git -C "$repo" config user.name t
    git -C "$repo" config commit.gpgsign false
    printf 'base\n' > "$repo/base.txt"; git -C "$repo" add base.txt; git -C "$repo" commit -qm base
    git -C "$repo" init -q --bare "$repo/origin.git"
    git -C "$repo" remote add origin "$repo/origin.git"; git -C "$repo" push -q origin main
    : > "$shafile"
    local i=0
    for name in "$@"; do
        i=$((i+1)); printf '%s\n' "$name" > "$repo/f$i.txt"
        git -C "$repo" add "f$i.txt"; git -C "$repo" commit -qm "$name"
        git -C "$repo" rev-parse HEAD >> "$shafile"
    done
}

_reviewed_pulls() { printf '[{"number":%s,"state":"closed","merged_at":"2026-01-01T00:00:00Z","head":{"sha":"%s"},"merge_commit_sha":"m%s"}]' "$1" "$2" "$1"; }
_checks() { printf '{"check_runs":[{"name":"review-sub-pr","conclusion":"%s"}]}' "$1"; }

_run() { # _run <repo> <head> <mockdir> [extra VAR=val ...]
    # `env` applies the trailing VAR=val tokens (incl. those from "$@") as real
    # environment — a bare `"$@" cmd` would treat VAR=val as a command word.
    local repo="$1" head="$2" mock="$3"; shift 3
    ( cd "$repo" && env "PATH=$_MOCK_BIN:$PATH" GH_REPO="test/repo" DSO_HEAD_SHA="$head" \
        DSO_MOCK_DIR="$mock" "$@" bash "$CHECK" ) 2>&1
}

# ── T1: a reviewed SHA passes (covering merged PR + passing review check) ────
r="$_WORK/t1"; mkdir -p "$r"; sf="$_WORK/t1.shas"; md="$_WORK/t1.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "feat-A"
sha="$(sed -n 1p "$sf")"
_reviewed_pulls 10 covA > "$md/pulls_$sha"; _checks success > "$md/checks_covA"
out="$(_run "$r" "$sha" "$md")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "every SHA proven reviewed" <<<"$out"; then _pass "T1_reviewed_sha_passes"; else _fail "T1_reviewed_sha_passes" "rc=$rc out=$out"; fi

# ── T2: admin-bypassed sub-PR (covering PR merged, review check FAILED) blocks (P9c) ──
r="$_WORK/t2"; mkdir -p "$r"; sf="$_WORK/t2.shas"; md="$_WORK/t2.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "feat-B"
sha="$(sed -n 1p "$sf")"
_reviewed_pulls 11 covB > "$md/pulls_$sha"; _checks failure > "$md/checks_covB"
out="$(_run "$r" "$sha" "$md")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "UNREVIEWED ${sha}" <<<"$out"; then _pass "T2_admin_bypassed_subpr_blocks"; else _fail "T2_admin_bypassed_subpr_blocks" "rc=$rc out=$out"; fi

# ── T3: no covering PR (reaches main with zero review evidence) blocks ───────
r="$_WORK/t3"; mkdir -p "$r"; sf="$_WORK/t3.shas"; md="$_WORK/t3.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "feat-C"
sha="$(sed -n 1p "$sf")"
printf '[]' > "$md/pulls_$sha"
out="$(_run "$r" "$sha" "$md")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "UNREVIEWED ${sha}" <<<"$out"; then _pass "T3_no_covering_pr_blocks"; else _fail "T3_no_covering_pr_blocks" "rc=$rc out=$out"; fi

# ── T4: API error fails CLOSED (never passes on uncertainty) ────────────────
r="$_WORK/t4"; mkdir -p "$r"; sf="$_WORK/t4.shas"; md="$_WORK/t4.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "feat-D"
sha="$(sed -n 1p "$sf")"
# no pulls fixture -> mock returns API error
out="$(_run "$r" "$sha" "$md")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "FAIL_CLOSED ${sha}" <<<"$out"; then _pass "T4_api_error_fails_closed"; else _fail "T4_api_error_fails_closed" "rc=$rc out=$out"; fi

# ── T5: ledger HIT skips re-verification (perf prefilter; only on a hit) ─────
r="$_WORK/t5"; mkdir -p "$r"; sf="$_WORK/t5.shas"; md="$_WORK/t5.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "feat-E"
sha="$(sed -n 1p "$sf")"
printf '[]' > "$md/pulls_$sha"   # would be UNREVIEWED if checked
ledger="$_WORK/t5.ledger"; printf '%s 99:covE\n' "$sha" > "$ledger"
out="$(_run "$r" "$sha" "$md" DSO_REVIEWED_LEDGER="$ledger")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "ledger_hits=1" <<<"$out"; then _pass "T5_ledger_hit_skips"; else _fail "T5_ledger_hit_skips" "rc=$rc out=$out"; fi

# ── T6: a reviewed run WRITES the ledger (durability) ───────────────────────
r="$_WORK/t6"; mkdir -p "$r"; sf="$_WORK/t6.shas"; md="$_WORK/t6.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "feat-F"
sha="$(sed -n 1p "$sf")"
_reviewed_pulls 12 covF > "$md/pulls_$sha"; _checks success > "$md/checks_covF"
ledger="$_WORK/t6.ledger"
_run "$r" "$sha" "$md" DSO_REVIEWED_LEDGER="$ledger" >/dev/null
if [[ -f "$ledger" ]] && grep -q "^${sha} 12:covF$" "$ledger"; then _pass "T6_reviewed_writes_ledger"; else _fail "T6_reviewed_writes_ledger" "ledger=$(cat "$ledger" 2>/dev/null)"; fi

# ── T7: warn mode logs but does not block (staged rollout) ──────────────────
r="$_WORK/t7"; mkdir -p "$r"; sf="$_WORK/t7.shas"; md="$_WORK/t7.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "feat-G"
sha="$(sed -n 1p "$sf")"
printf '[]' > "$md/pulls_$sha"
out="$(_run "$r" "$sha" "$md" DSO_COVERAGE_INVARIANT_MODE=warn)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "MODE=warn" <<<"$out"; then _pass "T7_warn_mode_does_not_block"; else _fail "T7_warn_mode_does_not_block" "rc=$rc out=$out"; fi

# ── T8: empty range (head == base) passes ───────────────────────────────────
r="$_WORK/t8"; mkdir -p "$r"; sf="$_WORK/t8.shas"; md="$_WORK/t8.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf"   # no head commits
base="$(git -C "$r" rev-parse origin/main)"
out="$(_run "$r" "$base" "$md")"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "no commits in" <<<"$out"; then _pass "T8_empty_range_passes"; else _fail "T8_empty_range_passes" "rc=$rc out=$out"; fi

# ── T9: mixed range — one reviewed, one unreviewed → blocks on the unreviewed ──
r="$_WORK/t9"; mkdir -p "$r"; sf="$_WORK/t9.shas"; md="$_WORK/t9.mock"; mkdir -p "$md"
_mk_repo "$r" "$sf" "ok-commit" "bad-commit"
sha_ok="$(sed -n 1p "$sf")"; sha_bad="$(sed -n 2p "$sf")"; head="$sha_bad"
_reviewed_pulls 20 covOK > "$md/pulls_$sha_ok"; _checks success > "$md/checks_covOK"
printf '[]' > "$md/pulls_$sha_bad"
out="$(_run "$r" "$head" "$md")"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "UNREVIEWED ${sha_bad}" <<<"$out" && grep -q "verified=1" <<<"$out"; then _pass "T9_mixed_blocks_on_unreviewed"; else _fail "T9_mixed_blocks_on_unreviewed" "rc=$rc out=$out"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
