#!/usr/bin/env bash
# tests/scripts/test-ci-enforcement-e2e.sh
#
# End-to-end test for CI enforcement via GitHub Ruleset. Verifies the full PR
# lifecycle: conforming PR merges successfully after all required checks pass,
# and a PR with a check failure is blocked from merging by the Ruleset.
#
# This test is OPT-IN and is skipped unless RUN_CI_E2E=1 is set.
# It makes real GitHub API calls and requires a live repository with the
# "DSO CI Enforcement" Ruleset provisioned.
#
# Usage:
#   RUN_CI_E2E=1 CI_E2E_REPO=owner/repo bash tests/scripts/test-ci-enforcement-e2e.sh
# Optional:
#   CI_E2E_TIMEOUT_MINUTES=20  (default: 20)
#   CI_E2E_REQUIRED_CHECKS="check1 check2 ..."  (default: read from .github/required-checks.txt)
#
# Exit codes:
#   0  — all assertions passed (or test was skipped because opt-in flag absent)
#   1  — at least one assertion failed
#   2  — environment problem (gh CLI unavailable, CI_E2E_REPO missing/invalid)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== test-ci-enforcement-e2e.sh ==="

# ── Opt-in gate ───────────────────────────────────────────────────────────────
if [ "${RUN_CI_E2E:-}" != "1" ]; then
    echo "SKIP: RUN_CI_E2E not set to 1. To run this test:"
    echo "  RUN_CI_E2E=1 CI_E2E_REPO=owner/repo bash tests/scripts/test-ci-enforcement-e2e.sh"
    echo ""
    echo "PASSED: 0  FAILED: 0  (skipped)"
    exit 0
fi

# ── Environment prerequisites ─────────────────────────────────────────────────
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found in PATH. Install from https://cli.github.com/" >&2
    exit 2
fi

if [ -z "${CI_E2E_REPO:-}" ]; then
    echo "ERROR: CI_E2E_REPO must be set to owner/repo (e.g., navapbc/my-repo)" >&2
    exit 2
fi

if [[ "$CI_E2E_REPO" != *"/"* ]]; then
    echo "ERROR: CI_E2E_REPO must be in owner/repo format, got: $CI_E2E_REPO" >&2
    exit 2
fi

if ! gh auth status >/dev/null 2>&1 && [ -z "${GH_TOKEN:-}" ]; then
    echo "ERROR: gh is not authenticated. Run 'gh auth login' or set GH_TOKEN." >&2
    exit 2
fi

# ── Configuration ─────────────────────────────────────────────────────────────
TIMEOUT_MINUTES="${CI_E2E_TIMEOUT_MINUTES:-20}"
TIMESTAMP="$(date +%s)"
CONFORMING_BRANCH="e2e-ci-enforcement-${TIMESTAMP}"
FAILING_BRANCH="e2e-ci-enforcement-fail-${TIMESTAMP}"

# ── Cleanup trap ──────────────────────────────────────────────────────────────
CLEANUP_PR_CONFORMING=""
CLEANUP_PR_FAILING=""
CLEANUP_BRANCH_CONFORMING=""
CLEANUP_BRANCH_FAILING=""

cleanup() {
    echo "" >&2
    echo "=== Cleanup ===" >&2
    if [ -n "$CLEANUP_PR_CONFORMING" ]; then
        gh pr close "$CLEANUP_PR_CONFORMING" --repo "$CI_E2E_REPO" 2>/dev/null || true
    fi
    if [ -n "$CLEANUP_PR_FAILING" ]; then
        gh pr close "$CLEANUP_PR_FAILING" --repo "$CI_E2E_REPO" 2>/dev/null || true
    fi
    if [ -n "$CLEANUP_BRANCH_CONFORMING" ]; then
        git push origin --delete "$CLEANUP_BRANCH_CONFORMING" 2>/dev/null || true
    fi
    if [ -n "$CLEANUP_BRANCH_FAILING" ]; then
        git push origin --delete "$CLEANUP_BRANCH_FAILING" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ── Load required check contexts ──────────────────────────────────────────────
_load_required_checks() {
    if [ -n "${CI_E2E_REQUIRED_CHECKS:-}" ]; then
        # shellcheck disable=SC2206
        REQUIRED_CHECKS=($CI_E2E_REQUIRED_CHECKS)
        echo "INFO: Using CI_E2E_REQUIRED_CHECKS (${#REQUIRED_CHECKS[@]} checks)" >&2
        return
    fi

    local checks_file="$REPO_ROOT/.github/required-checks.txt"
    if [ ! -f "$checks_file" ]; then
        echo "WARNING: .github/required-checks.txt not found — poll will skip check verification" >&2
        REQUIRED_CHECKS=()
        return
    fi

    REQUIRED_CHECKS=()
    while IFS= read -r line; do
        # Strip comments and blank lines
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -n "$line" ] && REQUIRED_CHECKS+=("$line")
    done < "$checks_file"
    echo "INFO: Loaded ${#REQUIRED_CHECKS[@]} required checks from $checks_file" >&2
}

REQUIRED_CHECKS=()
_load_required_checks

# ── Poll for check conclusions ─────────────────────────────────────────────────
# Returns 0 when all required checks have a non-empty conclusion, 1 on timeout.
_poll_checks() {
    local repo="$1" sha="$2" label="$3"
    local max_seconds=$(( TIMEOUT_MINUTES * 60 ))
    local elapsed=0
    local interval=30

    echo "INFO: Polling checks for SHA $sha on $repo (timeout: ${TIMEOUT_MINUTES}min)..." >&2

    while [ "$elapsed" -lt "$max_seconds" ]; do
        local runs_json
        runs_json="$(gh api "repos/${repo}/commits/${sha}/check-runs" 2>/dev/null || echo "{}")"

        if [ ${#REQUIRED_CHECKS[@]} -gt 0 ]; then
            local all_done=true
            for check in "${REQUIRED_CHECKS[@]}"; do
                local conclusion
                conclusion="$(echo "$runs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
runs = data.get('check_runs', [])
for r in runs:
    if r.get('name') == '${check}':
        c = r.get('conclusion') or ''
        print(c)
        sys.exit(0)
print('')
" 2>/dev/null || echo "")"
                if [ -z "$conclusion" ]; then
                    all_done=false
                    break
                fi
            done
            if $all_done; then
                echo "INFO: All ${#REQUIRED_CHECKS[@]} required checks have conclusions for $label" >&2
                return 0
            fi
        else
            # No required checks configured — wait for any checks to complete
            local total_count
            total_count="$(echo "$runs_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
runs = data.get('check_runs', [])
done = [r for r in runs if r.get('conclusion')]
print(len(done))
" 2>/dev/null || echo "0")"
            if [ "$total_count" -gt 0 ]; then
                echo "INFO: $total_count checks completed for $label" >&2
                return 0
            fi
        fi

        sleep "$interval"
        elapsed=$(( elapsed + interval ))
        echo "INFO: Still waiting... (${elapsed}s elapsed)" >&2
    done

    echo "ERROR: Timed out waiting for checks on $label after ${TIMEOUT_MINUTES} minutes" >&2
    return 1
}

# ── Test tracking ──────────────────────────────────────────────────────────────
PASSED=0
FAILED=0

_pass() { echo "$1 ... PASS"; PASSED=$(( PASSED + 1 )); }
_fail() { echo "$1 ... FAIL"; FAILED=$(( FAILED + 1 )); }

# ── Phase 1: Conforming PR merges successfully ─────────────────────────────────
echo ""
echo "--- Phase 1: Conforming PR ---"

# Create a conforming change
git checkout -b "$CONFORMING_BRANCH" 2>/dev/null
CLEANUP_BRANCH_CONFORMING="$CONFORMING_BRANCH"

# Touch a safe file in docs/ (won't affect CI correctness checks)
mkdir -p docs
echo "# E2E CI enforcement test run ${TIMESTAMP}" >> docs/e2e-ci-test-marker.md
git add docs/e2e-ci-test-marker.md
git commit -m "chore: E2E CI enforcement test (${TIMESTAMP}) [skip-if-missing]" 2>/dev/null

CONFORMING_SHA="$(git rev-parse HEAD)"
git push origin "$CONFORMING_BRANCH" 2>/dev/null

CONFORMING_PR_URL="$(gh pr create \
    --repo "$CI_E2E_REPO" \
    --base main \
    --head "$CONFORMING_BRANCH" \
    --title "E2E CI enforcement test (conforming) ${TIMESTAMP}" \
    --body "Automated E2E test PR — safe to close" \
    2>/dev/null)"
CLEANUP_PR_CONFORMING="$CONFORMING_PR_URL"

echo "INFO: Created conforming PR: $CONFORMING_PR_URL" >&2

# Poll for check conclusions
if _poll_checks "$CI_E2E_REPO" "$CONFORMING_SHA" "conforming PR"; then
    _pass "test_conforming_checks_complete"

    # Verify each required check has a conclusion
    if [ ${#REQUIRED_CHECKS[@]} -gt 0 ]; then
        RUNS_JSON="$(gh api "repos/${CI_E2E_REPO}/commits/${CONFORMING_SHA}/check-runs" 2>/dev/null || echo "{}")"
        ALL_HAVE_CONCLUSION=true
        for check in "${REQUIRED_CHECKS[@]}"; do
            conclusion="$(echo "$RUNS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for r in data.get('check_runs', []):
    if r.get('name') == '${check}':
        print(r.get('conclusion') or '')
        sys.exit(0)
print('')
" 2>/dev/null || echo "")"
            if [ -z "$conclusion" ]; then
                echo "INFO: check '${check}' has no conclusion" >&2
                ALL_HAVE_CONCLUSION=false
            fi
        done
        if $ALL_HAVE_CONCLUSION; then
            _pass "test_required_checks_have_conclusions"
        else
            _fail "test_required_checks_have_conclusions"
        fi
    fi

    # Attempt merge
    if gh pr merge "$CONFORMING_PR_URL" \
            --repo "$CI_E2E_REPO" \
            --squash \
            --auto 2>/dev/null; then
        _pass "test_conforming_pr_merges"
        CLEANUP_PR_CONFORMING=""  # merged, no cleanup needed
        CLEANUP_BRANCH_CONFORMING=""
    else
        _fail "test_conforming_pr_merges"
    fi
else
    _fail "test_conforming_checks_complete"
    _fail "test_conforming_pr_merges"
fi

# ── Phase 2: Failing PR is blocked by Ruleset ─────────────────────────────────
echo ""
echo "--- Phase 2: Failing PR blocked by Ruleset ---"

git checkout -b "$FAILING_BRANCH" 2>/dev/null || git checkout main && git checkout -b "$FAILING_BRANCH"
CLEANUP_BRANCH_FAILING="$FAILING_BRANCH"

# Introduce a shellcheck error: unused variable with no SC2034 suppress
mkdir -p tests/fixtures
cat > tests/fixtures/e2e-shellcheck-violator-"${TIMESTAMP}".sh <<'SHELLCHECK_VIOLATOR'
#!/usr/bin/env bash
# Intentional ShellCheck violation for E2E CI enforcement test.
# This file is a temporary test fixture and will be removed by PR cleanup.
unused_variable_for_ci_e2e_test="this_will_trigger_SC2034"
echo "done"
SHELLCHECK_VIOLATOR
chmod +x tests/fixtures/e2e-shellcheck-violator-"${TIMESTAMP}".sh

git add tests/fixtures/e2e-shellcheck-violator-"${TIMESTAMP}".sh
git commit -m "test: intentional ShellCheck violation for E2E Ruleset block test (${TIMESTAMP})" 2>/dev/null

FAILING_SHA="$(git rev-parse HEAD)"
git push origin "$FAILING_BRANCH" 2>/dev/null

FAILING_PR_URL="$(gh pr create \
    --repo "$CI_E2E_REPO" \
    --base main \
    --head "$FAILING_BRANCH" \
    --title "E2E CI enforcement test (failing) ${TIMESTAMP}" \
    --body "Automated E2E test PR — intentional failure to verify Ruleset blocks merge" \
    2>/dev/null)"
CLEANUP_PR_FAILING="$FAILING_PR_URL"

echo "INFO: Created failing PR: $FAILING_PR_URL" >&2

# Poll until at least one required check has conclusion=failure
echo "INFO: Waiting for at least one check failure on failing PR..." >&2
MAX_SECS=$(( TIMEOUT_MINUTES * 60 ))
ELAPSED=0
GOT_FAILURE=false
while [ "$ELAPSED" -lt "$MAX_SECS" ]; do
    RUNS_JSON="$(gh api "repos/${CI_E2E_REPO}/commits/${FAILING_SHA}/check-runs" 2>/dev/null || echo "{}")"
    FAILURE_COUNT="$(echo "$RUNS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
count = sum(1 for r in data.get('check_runs', []) if r.get('conclusion') == 'failure')
print(count)
" 2>/dev/null || echo "0")"
    if [ "$FAILURE_COUNT" -gt 0 ]; then
        GOT_FAILURE=true
        echo "INFO: $FAILURE_COUNT check(s) failed — proceeding to merge attempt" >&2
        break
    fi
    sleep 30
    ELAPSED=$(( ELAPSED + 30 ))
    echo "INFO: Waiting for failure... (${ELAPSED}s elapsed)" >&2
done

if $GOT_FAILURE; then
    _pass "test_failing_check_detected"

    # Attempt merge — Ruleset MUST block it
    if gh pr merge "$FAILING_PR_URL" \
            --repo "$CI_E2E_REPO" \
            --squash 2>/dev/null; then
        # Merge succeeded when it should have been blocked — Ruleset not working
        _fail "test_ruleset_blocks_failing_pr"
    else
        _pass "test_ruleset_blocks_failing_pr"
    fi
else
    echo "WARNING: Timed out waiting for a check failure — Ruleset block test inconclusive" >&2
    _fail "test_failing_check_detected"
    _fail "test_ruleset_blocks_failing_pr"
fi

# ── Summary ────────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASSED  FAILED: $FAILED"

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
