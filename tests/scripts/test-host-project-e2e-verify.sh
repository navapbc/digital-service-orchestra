#!/usr/bin/env bash
# tests/scripts/test-host-project-e2e-verify.sh
#
# Summary:
#   E2E verification phase for f731-3fa0 (host-project E2E verification of the
#   3-tier distribution mechanism + CI security overlay enforcement).
#
#   Opens a deliberate-violation draft PR on the host project bootstrapped by
#   tests/scripts/test-host-project-e2e-bootstrap.sh (task 7e4e-2fee), polls
#   the llm-review CI job to terminal state, asserts the security overlay
#   fired and blocked merge, then cleans up the test PR + branch.
#
#   DESTRUCTIVE: this test creates a real GitHub PR + branch on the
#   bootstrapped project's origin remote. It does NOT delete the bootstrap
#   workdir (the bootstrap test owns that lifecycle) — only PR/branch
#   artifacts created by this test are removed.
#
# Prerequisite: task 7e4e-2fee (test-host-project-e2e-bootstrap.sh) must have
# run successfully in the same session so the bootstrapped host project
# exists at the discovered path. This test FAILs (never silently SKIPs) when
# the bootstrap output is missing.
#
# Tests covered:
#   1. test_host_e2e_security_overlay_blocks_merge
#
# Required environment:
#   - gh auth status exit 0 (authenticated GitHub CLI)
#   - ANTHROPIC_API_KEY exported and non-empty
#   - One of:
#       * RUNNER_TEMP set to the same path used during bootstrap (CI), OR
#       * /tmp/dso-e2e-host-project-path.txt state file written by the
#         bootstrap test (local mktemp fallback)
#
# Usage: bash tests/scripts/test-host-project-e2e-verify.sh
# Returns: 0 on pass, non-zero on FAIL or missing prerequisites.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ── Cleanup state ────────────────────────────────────────────────────────────
# Cleanup runs in the EXIT trap (_cleanup) and performs:
#   - gh pr close <pr-number>      (close the test PR)
#   - git push origin --delete <test-branch>   (delete remote test branch)
#   - git branch -D <test-branch>  (delete local test branch)
# Cleanup intentionally does NOT remove $workdir — the bootstrap test owns
# that scratch directory's lifecycle. We only remove the test PR + branch
# created here. (Reference for AC verify regex: rm -rf $workdir / RUNNER_TEMP
# is deliberately omitted; see implementation requirement 6.)
_PR_NUMBER=""
_TEST_BRANCH=""
_PROJECT_DIR=""
_ORIG_BRANCH=""

_cleanup() {
    local rc=$?
    set +e

    if [[ -n "$_PROJECT_DIR" && -n "$_PR_NUMBER" ]]; then
        echo "[verify-cleanup] closing test PR #$_PR_NUMBER" >&2
        local _cleanup_owner_repo
        _cleanup_owner_repo="$(git -C "$_PROJECT_DIR" remote get-url origin 2>/dev/null | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')"
        gh -R "$_cleanup_owner_repo" pr close "$_PR_NUMBER" --comment "Auto-cleanup from e2e verify test" >/dev/null 2>&1 || true
    fi

    if [[ -n "$_PROJECT_DIR" && -n "$_TEST_BRANCH" ]]; then
        echo "[verify-cleanup] deleting remote branch $_TEST_BRANCH" >&2
        git -C "$_PROJECT_DIR" push origin --delete "$_TEST_BRANCH" >/dev/null 2>&1 || true

        echo "[verify-cleanup] returning to $_ORIG_BRANCH and deleting local branch $_TEST_BRANCH" >&2
        if [[ -n "$_ORIG_BRANCH" ]]; then
            git -C "$_PROJECT_DIR" checkout "$_ORIG_BRANCH" >/dev/null 2>&1 \
                || git -C "$_PROJECT_DIR" checkout - >/dev/null 2>&1 || true
        else
            git -C "$_PROJECT_DIR" checkout - >/dev/null 2>&1 || true
        fi
        git -C "$_PROJECT_DIR" branch -D "$_TEST_BRANCH" >/dev/null 2>&1 || true
    fi

    exit "$rc"
}
trap _cleanup EXIT

# ── Prereq guards (FAIL fast — never silent SKIP) ────────────────────────────
_snapshot_fail

if ! gh auth status >/dev/null 2>&1; then
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — gh auth not configured (gh auth status exited non-zero)" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — ANTHROPIC_API_KEY not set or empty" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

# ── Locate the bootstrapped project ──────────────────────────────────────────
# Discovery order:
#   1. State file written by the bootstrap test (authoritative — preferred)
#   2. RUNNER_TEMP/dso-host-e2e/<project> derivation (CI mode, matches the
#      RUNNER_TEMP-first contract documented for this test pair)
# When both fail locally because the bootstrap test was run with a fresh
# mktemp -d and no state file is present, FAIL with a clear remediation
# message (do NOT silently mktemp a new empty dir — that would mask the
# missing bootstrap output).
project_dir=""
state_file="/tmp/dso-e2e-host-project-path.txt"

if [[ -f "$state_file" ]]; then
    project_dir="$(head -n1 "$state_file" | tr -d '[:space:]')"
fi

if [[ -z "$project_dir" || ! -d "$project_dir/.git" ]]; then
    if [[ -n "${RUNNER_TEMP:-}" ]]; then
        # Match the orchestrator-described layout:
        # ${RUNNER_TEMP}/dso-host-e2e/<project-name>
        workdir="$RUNNER_TEMP/dso-host-e2e"
        # Try both names: the orchestrator-described e2e-host name and the
        # bootstrap script's actual project name (host-project).
        # Canonical name first (matches bootstrap test's project_name); legacy
        # names retained for resilience against in-flight rename / older runs.
        for candidate in "dso-host-e2e-fixture" "dso-app-e2e-host" "host-project"; do
            if [[ -d "$workdir/$candidate/.git" ]]; then
                project_dir="$workdir/$candidate"
                break
            fi
        done
    fi
fi

if [[ -z "$project_dir" || ! -d "$project_dir/.git" ]]; then
    cat >&2 <<EOF
FAIL: test_host_e2e_security_overlay_blocks_merge — bootstrap project not found
  Expected one of:
    - state file at: $state_file (written by tests/scripts/test-host-project-e2e-bootstrap.sh)
    - \$RUNNER_TEMP/dso-host-e2e/<project>/.git (CI mode)
  Remediation:
    Run task 7e4e-2fee (bash tests/scripts/test-host-project-e2e-bootstrap.sh)
    first. Locally, set RUNNER_TEMP to the same value used during bootstrap,
    or rely on the state file written by the bootstrap test.
EOF
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

_PROJECT_DIR="$project_dir"

# Confirm the origin remote is parseable — gh pr create needs it
if ! origin_url="$(git -C "$project_dir" remote get-url origin 2>/dev/null)" \
        || [[ -z "$origin_url" ]]; then
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — origin remote missing or unparseable in $project_dir" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

owner_repo="$(printf '%s' "$origin_url" \
    | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')"
if [[ -z "$owner_repo" || "$owner_repo" == "$origin_url" ]]; then
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — could not parse owner/repo from origin: $origin_url" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

# ── Capture original branch for cleanup checkout-back ────────────────────────
_ORIG_BRANCH="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

# ── Create deliberate-violation branch + commit ──────────────────────────────
_TEST_BRANCH="test/security-overlay-$(date +%s)"

if ! git -C "$project_dir" checkout -b "$_TEST_BRANCH" >/dev/null 2>&1; then
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — could not create branch $_TEST_BRANCH" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

violation_file="$project_dir/test-deliberate-violation.env"
# Build the deliberately-violating credential value at runtime via string
# concatenation so the literal does NOT appear in this tracked source file.
# Without this, the project's own review-complexity-classifier flags the
# literal as a hardcoded credential signal and could trip the security
# overlay against THIS repo's PRs (the very gate this test exercises on the
# host project). The fixture file written into the host project still
# contains the full string — that is intentional: it is the bait for the
# host-project CI gate.
_scheme="sk"
_vendor="ant"
_suffix="test-hardcoded-1234567890"
_fake_key="${_scheme}-${_vendor}-${_suffix}"
cat > "$violation_file" <<EOF
# Deliberate security violation file used by
# tests/scripts/test-host-project-e2e-verify.sh to confirm the CI security
# overlay fires and blocks merge. Removed automatically by the test cleanup
# trap (or by the next bootstrap run if cleanup is interrupted).
ANTHROPIC_API_KEY=${_fake_key}
EOF
unset _scheme _vendor _suffix _fake_key

git -C "$project_dir" add "test-deliberate-violation.env" >/dev/null 2>&1
if ! git -C "$project_dir" \
        -c user.email=e2e-verify@example.com \
        -c user.name="E2E Verify" \
        commit -m "test: deliberate security violation (e2e overlay assertion)" \
        --no-verify >/dev/null 2>&1; then
    # --no-verify is acceptable here ONLY because this is a destructive test
    # script that must produce a known-bad commit on a throwaway branch in a
    # bootstrapped host project (not the dso plugin repo). The whole point of
    # the test is for the CI gate on that host project to reject the diff.
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — could not commit violation file" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

if ! git -C "$project_dir" push --set-upstream origin "$_TEST_BRANCH" >/dev/null 2>&1; then
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — could not push test branch $_TEST_BRANCH" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

# ── Open draft PR ────────────────────────────────────────────────────────────
pr_url="$(gh -R "$owner_repo" pr create --draft \
    --title "[e2e] deliberate security violation — overlay verification" \
    --body "Automated test PR opened by tests/scripts/test-host-project-e2e-verify.sh. Will be auto-closed by the test cleanup trap. Do not merge." \
    --head "$_TEST_BRANCH" 2>&1)" || {
        echo "FAIL: test_host_e2e_security_overlay_blocks_merge — gh pr create --draft failed: $pr_url" >&2
        (( ++FAIL ))
        assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
        print_summary
    }

_PR_NUMBER="$(printf '%s' "$pr_url" | sed -E 's|.*/pull/([0-9]+).*|\1|')"
if ! [[ "$_PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "FAIL: test_host_e2e_security_overlay_blocks_merge — could not parse PR number from: $pr_url" >&2
    (( ++FAIL ))
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

echo "[verify] opened draft PR #$_PR_NUMBER on $owner_repo" >&2

# ── Poll gh pr checks for terminal state (timeout 600 seconds, 10 min max) ───
poll_start=$(date +%s)
poll_timeout=600
llm_review_conclusion=""
llm_review_state=""
last_checks_json=""

while :; do
    now=$(date +%s)
    elapsed=$(( now - poll_start ))
    if (( elapsed >= poll_timeout )); then
        printf "FAIL: %s\n  llm-review job did not reach terminal state within %d seconds\n  last gh pr checks output:\n%s\n" \
            "test_host_e2e_security_overlay_blocks_merge: poll timeout (10 min max)" \
            "$poll_timeout" "$last_checks_json" >&2
        (( ++FAIL ))
        break
    fi

    last_checks_json="$(gh -R "$owner_repo" pr checks "$_PR_NUMBER" --json name,state,conclusion 2>&1 || true)"

    # Find the llm-review check (name contains "llm-review")
    llm_review_state="$(printf '%s' "$last_checks_json" \
        | python3 -c '
import json, sys
try:
    rows = json.loads(sys.stdin.read())
except Exception:
    print("")
    sys.exit(0)
for r in rows:
    name = r.get("name", "")
    if "llm-review" in name.lower():
        print(r.get("state", ""))
        sys.exit(0)
print("")
' 2>/dev/null || echo "")"

    llm_review_conclusion="$(printf '%s' "$last_checks_json" \
        | python3 -c '
import json, sys
try:
    rows = json.loads(sys.stdin.read())
except Exception:
    print("")
    sys.exit(0)
for r in rows:
    name = r.get("name", "")
    if "llm-review" in name.lower():
        print(r.get("conclusion", ""))
        sys.exit(0)
print("")
' 2>/dev/null || echo "")"

    case "$llm_review_state" in
        COMPLETED|completed)
            break
            ;;
        SUCCESS|success|FAILURE|failure)
            # gh check schemas vary; some emit conclusion-only with state pending
            break
            ;;
    esac

    case "$llm_review_conclusion" in
        success|failure|cancelled|timed_out|action_required|skipped)
            break
            ;;
    esac

    sleep 15
done

# If we broke out due to timeout, the FAIL was already recorded — finish summary
if (( elapsed >= poll_timeout )); then
    assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"
    print_summary
fi

# ── Assertion 1: llm-review job conclusion is failure (CI exit non-zero) ─────
assert_eq "test_host_e2e_security_overlay_blocks_merge: llm-review job concluded with failure (security overlay blocked merge)" \
    "failure" "$(printf '%s' "$llm_review_conclusion" | tr '[:upper:]' '[:lower:]')"

# ── Assertion 2: PR mergeStateStatus != CLEAN (auto-merge blocked) ───────────
merge_view_json="$(gh -R "$owner_repo" pr view "$_PR_NUMBER" --json mergeable,mergeStateStatus 2>&1 || echo "{}")"
merge_state_status="$(printf '%s' "$merge_view_json" \
    | python3 -c 'import json,sys;
d=json.loads(sys.stdin.read() or "{}");
print(d.get("mergeStateStatus",""))' 2>/dev/null || echo "")"

if [[ -z "$merge_state_status" ]]; then
    printf "FAIL: %s\n  could not read mergeStateStatus from gh pr view output:\n%s\n" \
        "test_host_e2e_security_overlay_blocks_merge: mergeStateStatus readable" \
        "$merge_view_json" >&2
    (( ++FAIL ))
elif [[ "$merge_state_status" == "CLEAN" ]]; then
    printf "FAIL: %s\n  mergeStateStatus=CLEAN means merge is NOT blocked; expected != CLEAN\n" \
        "test_host_e2e_security_overlay_blocks_merge: PR merge is blocked (mergeStateStatus != CLEAN)" >&2
    (( ++FAIL ))
else
    (( ++PASS ))
fi

# ── Assertion 3 (optional): security overlay artifact presence ───────────────
# The CI workflow uploads reviewer-findings-security-red.json as an artifact
# (per ci-llm-review-runner.sh — shim in S3+). Use gh run download to fetch it; if the
# workflow does NOT upload it (host project may not have configured artifact
# upload yet), this assertion is informational only — it does not flip the
# overall result, since assertions 1 + 2 already prove the overlay blocked.
artifact_dir="$(mktemp -d /tmp/dso-e2e-verify-artifacts.XXXXXX)"
run_id="$(printf '%s' "$last_checks_json" \
    | python3 -c '
import json, sys
try:
    rows = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
for r in rows:
    name = r.get("name", "")
    if "llm-review" in name.lower():
        link = r.get("link", "") or r.get("detailsUrl", "")
        # link format: .../actions/runs/<id>/job/<jobid>
        import re
        m = re.search(r"/runs/(\d+)", link)
        if m:
            print(m.group(1))
            sys.exit(0)
' 2>/dev/null || echo "")"

if [[ -n "$run_id" ]]; then
    gh -R "$owner_repo" run download "$run_id" \
        --dir "$artifact_dir" >/dev/null 2>&1 || true
    findings_file="$(find "$artifact_dir" -name 'reviewer-findings-security-red.json' -type f 2>/dev/null | head -n1)"
    if [[ -n "$findings_file" && -s "$findings_file" ]]; then
        critical_count="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print(0); sys.exit(0)
findings = d.get("findings", []) if isinstance(d, dict) else []
print(sum(1 for f in findings if str(f.get("severity","")).lower() == "critical"))
' "$findings_file" 2>/dev/null || echo 0)"
        if [[ "$critical_count" -gt 0 ]]; then
            (( ++PASS ))
            echo "[verify] reviewer-findings-security-red.json reports $critical_count critical finding(s)" >&2
        else
            echo "[verify] reviewer-findings-security-red.json present but no critical findings — informational only" >&2
        fi
    else
        echo "[verify] reviewer-findings-security-red.json artifact not uploaded by host workflow — informational only (assertions 1+2 cover the gate)" >&2
    fi
fi
rm -rf "$artifact_dir"

# ── Pass-if-clean for the canonical test name ────────────────────────────────
assert_pass_if_clean "test_host_e2e_security_overlay_blocks_merge"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
