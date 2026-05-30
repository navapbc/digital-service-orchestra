#!/usr/bin/env bash
# Regression test for PR-R1 (post-audit Finding 3).
#
# gh API shim contract — field-name traceability to verifier code:
#   The shim below returns JSON with field names {"conclusion", "check_runs",
#   "name", "number", "state", "merged_at", "head.sha", "merge_commit_sha"}.
#   These are NOT hypothetical — the production verifier reads exactly these
#   names against real GitHub at:
#     - verify-session-provenance.sh:605  data.get('check_runs', [])
#     - verify-session-provenance.sh:607  r.get('name', '')  (checks 'review-sub-pr')
#     - verify-session-provenance.sh:610  r.get('conclusion')
#     - verify-session-provenance.sh:481  pr.get('state'), pr.get('merged_at')
#     - verify-session-provenance.sh:492  pr.get('head').get('sha')
#     - verify-session-provenance.sh:496  pr.get('merge_commit_sha')
#   The shim documents the contract the verifier already depended on against
#   real GitHub before PR-R1. If GitHub changes the response shape (extremely
#   rare for ruleset-API-adjacent endpoints), BOTH the verifier and the shim
#   need updating in lockstep.
#
# Before PR-R1, verify-session-provenance.sh:362 short-circuited on the
# presence of a `DSO-Story(-Merge):` trailer — accepting the trailer as
# evidence of review without verifying the covering PR's review-sub-pr
# status. PR-R1 removes the shortcut so every commit flows through the
# covering-PR API + G3 review-check verification.
#
# Test strategy: build a fixture commit with a fabricated
# `DSO-Story-Merge: bogus` trailer in a tmp git repo. PATH-shim `gh` so
# the commits/<sha>/pulls endpoint returns a "covering" PR whose
# review-sub-pr check is `failure`. Invoke the verifier and assert the
# commit is marked unprovenanced (under old behavior: provenanced).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VERIFIER="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"
PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# ── Fixture: tmp git repo + fabricated commit ────────────────────────────────
FIX=$(mktemp -d -t dso-pr-r1-XXXXXX)
# shellcheck disable=SC2064  # intentional: bind FIX at trap-set time
trap "rm -rf '$FIX'" EXIT
cd "$FIX" || { _fail "test_fixture_setup" "cannot cd to $FIX"; exit 1; }
git init -q
git config user.email "test@test.local"
git config user.name "test"
git config commit.gpgsign false
echo "base" > base.txt
git add base.txt
git commit -q -m "base"
BASE_SHA=$(git rev-parse HEAD)
# A "main" simulation: BASE_SHA is on origin/main.
git update-ref refs/remotes/origin/main HEAD

# Fabricated commit with a forged trailer pointing at a bogus story PR.
echo "forged content" > forged.txt
git add forged.txt
git commit -q -m "$(printf 'feat: fabricated change\n\nDSO-Story-Merge: bogus-non-existent-story')"
SESSION_HEAD=$(git rev-parse HEAD)

# ── PATH-shim gh to simulate API responses ───────────────────────────────────
SHIM_DIR=$(mktemp -d -t dso-gh-shim-XXXXXX)
# shellcheck disable=SC2064  # intentional: bind SHIM_DIR at trap-set time
trap "rm -rf '$FIX' '$SHIM_DIR'" EXIT
cat > "$SHIM_DIR/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh shim covering the verifier's API calls.
case "$1" in
  api)
    shift
    case "$1" in
      *commits/*/pulls)
        # Return a single covering PR with number 999.
        cat <<'EOF'
[{"number": 999, "state": "closed", "merged_at": "2026-01-01T00:00:00Z",
  "head": {"sha": "deadbeef"}, "merge_commit_sha": "cafef00d"}]
EOF
        ;;
      *pulls/999*)
        cat <<'EOF'
{"number": 999, "head": {"sha": "deadbeef"}}
EOF
        ;;
      *commits/*/check-runs*)
        # The covering PR's review-sub-pr conclusion is FAILURE.
        cat <<'EOF'
{"total_count": 1, "check_runs": [
  {"name": "review-sub-pr", "status": "completed", "conclusion": "failure"}
]}
EOF
        ;;
      *)
        echo "{}" ;;
    esac
    ;;
  *)
    echo "{}" ;;
esac
STUB
chmod +x "$SHIM_DIR/gh"

# ── Invoke the verifier ──────────────────────────────────────────────────────
ARTIFACT_DIR=$(mktemp -d -t dso-art-XXXXXX)
# shellcheck disable=SC2064  # intentional
trap "rm -rf '$FIX' '$SHIM_DIR' '$ARTIFACT_DIR'" EXIT

set +e
output=$(PATH="$SHIM_DIR:$PATH" \
    DSO_BASE_SHA="$BASE_SHA" \
    DSO_SESSION_HEAD="$SESSION_HEAD" \
    GH_REPO="test-owner/test-repo" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR" \
    GIT_REPO_PATH="$FIX" \
    bash "$VERIFIER" 2>&1)
exit_code=$?
set -e

# ── Assertions ───────────────────────────────────────────────────────────────
# Before PR-R1: the trailer shortcut marked the commit provenanced and the
#   verifier exited 0 with the fabricated commit in `covered-shas.txt`.
# After PR-R1: the trailer is ignored, the API path returns a covering PR
#   with failing review-sub-pr, and the commit is marked unprovenanced.

# Assert exit code reflects unprovenanced finding.
if [[ $exit_code -ne 0 ]]; then
    _pass "test_fabricated_trailer_no_longer_short_circuits_exit"
else
    _fail "test_fabricated_trailer_no_longer_short_circuits_exit" \
        "expected non-zero exit (unprovenanced), got $exit_code. output=${output:0:400}"
fi

# Assert the unprovenanced SHAs file contains the forged commit.
UNPROV_FILE="$ARTIFACT_DIR/unprovenanced-shas.txt"
if [[ -s "$UNPROV_FILE" ]] && grep -q "$SESSION_HEAD" "$UNPROV_FILE"; then
    _pass "test_fabricated_trailer_lands_in_unprovenanced_shas"
else
    _fail "test_fabricated_trailer_lands_in_unprovenanced_shas" \
        "expected $SESSION_HEAD in $UNPROV_FILE; contents: $(cat "$UNPROV_FILE" 2>/dev/null || echo '<missing>')"
fi

# Belt-and-suspenders: the covered-shas file should NOT contain the forged commit.
COVERED_FILE="$ARTIFACT_DIR/covered-shas.txt"
if [[ -s "$COVERED_FILE" ]] && grep -q "$SESSION_HEAD" "$COVERED_FILE"; then
    _fail "test_fabricated_trailer_not_in_covered_shas" \
        "forged commit $SESSION_HEAD leaked into covered-shas.txt (regression to trailer shortcut)"
else
    _pass "test_fabricated_trailer_not_in_covered_shas"
fi

# ── Happy path: trailered commit WITH valid covering PR → provenanced ────────
# This is the post-PR-R1 equivalent of the legacy tests'
# "trailer present → exit 0" assertion. Under v4, the trailer is no longer
# load-bearing — but a commit whose covering PR has passing review-sub-pr
# IS still correctly classified as provenanced via the API path.

cat > "$SHIM_DIR/gh" <<'STUB2'
#!/usr/bin/env bash
case "$1" in
  api)
    shift
    case "$1" in
      *commits/*/pulls)
        cat <<'EOF'
[{"number": 888, "state": "closed", "merged_at": "2026-01-01T00:00:00Z",
  "head": {"sha": "deadbeef"}, "merge_commit_sha": "cafef00d"}]
EOF
        ;;
      *pulls/888*)
        cat <<'EOF'
{"number": 888, "head": {"sha": "deadbeef"}}
EOF
        ;;
      *commits/*/check-runs*)
        cat <<'EOF'
{"total_count": 1, "check_runs": [
  {"name": "review-sub-pr", "status": "completed", "conclusion": "success"}
]}
EOF
        ;;
      *)
        echo "{}" ;;
    esac
    ;;
  *)
    echo "{}" ;;
esac
STUB2
chmod +x "$SHIM_DIR/gh"

# Wipe artifact dir so we get a fresh classification.
rm -rf "${ARTIFACT_DIR:?}"/*
set +e
output2=$(PATH="$SHIM_DIR:$PATH" \
    DSO_BASE_SHA="$BASE_SHA" \
    DSO_SESSION_HEAD="$SESSION_HEAD" \
    GH_REPO="test-owner/test-repo" \
    DSO_ARTIFACT_DIR="$ARTIFACT_DIR" \
    GIT_REPO_PATH="$FIX" \
    bash "$VERIFIER" 2>&1)
exit_code2=$?
set -e

if [[ $exit_code2 -eq 0 ]]; then
    _pass "test_trailered_commit_with_passing_covering_pr_is_provenanced"
else
    _fail "test_trailered_commit_with_passing_covering_pr_is_provenanced" \
        "expected exit 0 (provenanced via covering PR), got $exit_code2. output=${output2:0:400}"
fi

COVERED_FILE2="$ARTIFACT_DIR/covered-shas.txt"
if [[ -s "$COVERED_FILE2" ]] && grep -q "$SESSION_HEAD" "$COVERED_FILE2"; then
    _pass "test_trailered_commit_with_passing_covering_pr_in_covered_shas"
else
    _fail "test_trailered_commit_with_passing_covering_pr_in_covered_shas" \
        "expected $SESSION_HEAD in $COVERED_FILE2; contents: $(cat "$COVERED_FILE2" 2>/dev/null || echo '<missing>')"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
