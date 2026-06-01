#!/usr/bin/env bash
# tests/scripts/test-verify-session-provenance-w4-candidate-type.sh — W4 / Gap-2
#
# A SHA that is the head of a DIFFERENT merged+reviewed PR is VALID provenance
# and must NOT be dropped by the blanket A3a `head == sha` exclusion. A3a is now
# scoped to the self candidate only. The self PR (under review) still cannot
# provide its own provenance.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
VERIFIER="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"

PASS=0; FAIL=0
_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

_W="$(mktemp -d "${TMPDIR:-/tmp}/dso-w4.XXXXXX")"
trap 'rm -rf "$_W"' EXIT

# Mock gh: covering merged PR #888 whose head.sha == the SHA under review, with a
# passing review-sub-pr check. head.sha is echoed dynamically from the path.
_MOCK="$_W/bin"; mkdir -p "$_MOCK"
cat > "$_MOCK/gh" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == "api" ]] || { echo "{}"; exit 0; }
p="$2"
case "$p" in
  */commits/*/pulls)
    sha="${p%/pulls}"; sha="${sha##*/commits/}"
    printf '[{"number":888,"state":"closed","merged_at":"2026-01-01T00:00:00Z","head":{"sha":"%s"},"merge_commit_sha":"zzzmergezzz"}]' "$sha" ;;
  */commits/*/check-runs*)
    echo '{"total_count":1,"check_runs":[{"name":"review-sub-pr","status":"completed","conclusion":"success"}]}' ;;
  *) echo "{}" ;;
esac
MOCK
chmod +x "$_MOCK/gh"

# Fixture repo: base + one commit X (no trailer → goes through the API path).
R="$_W/repo"; mkdir -p "$R"
git -C "$R" init -q -b main
git -C "$R" config user.email t@e.st; git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
printf 'base\n' > "$R/base.txt"; git -C "$R" add base.txt; git -C "$R" commit -qm base
BASE="$(git -C "$R" rev-parse HEAD)"
printf 'change\n' > "$R/x.txt"; git -C "$R" add x.txt; git -C "$R" commit -qm "plain change with no trailer"
X="$(git -C "$R" rev-parse HEAD)"

_run() { # _run [PR_NUMBER]
    local pr="${1:-}"
    ( cd "$R" && env "PATH=$_MOCK:$PATH" DSO_GH_REPO="test/repo" DSO_REPO_PATH="$R" \
        DSO_BASE_SHA="$BASE" DSO_SESSION_HEAD="$X" DSO_UPSTREAM_REF="" \
        ${pr:+PR_NUMBER="$pr"} bash "$VERIFIER" ) >/dev/null 2>&1
}

# ── T1 (the fix): push context — covering merged+reviewed PR with head==X is
#     KEPT → X is provenanced (exit 0). Before W4, A3a dropped it → exit 1. ──
_run; rc=$?
if [[ $rc -eq 0 ]]; then _pass "T1_other_merged_pr_head_eq_sha_is_provenance"; else _fail "T1_other_merged_pr_head_eq_sha_is_provenance" "rc=$rc (expected 0 provenanced)"; fi

# ── T2 (self-exclusion preserved): PR context with PR_NUMBER=888 — the only
#     covering PR is the self PR → excluded → X unprovenanced (exit 1). ──
_run 888; rc=$?
if [[ $rc -eq 1 ]]; then _pass "T2_self_pr_cannot_self_provenance"; else _fail "T2_self_pr_cannot_self_provenance" "rc=$rc (expected 1 unprovenanced)"; fi

echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
