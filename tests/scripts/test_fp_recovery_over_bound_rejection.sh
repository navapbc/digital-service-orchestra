#!/usr/bin/env bash
# tests/scripts/test_fp_recovery_over_bound_rejection.sh
# Behavioral tests for OVER_BOUND rejection in the fp-recovery skill.
#
# Verifies that the fp-recovery pre-check script:
#   - Exits non-zero when the PR's CI output contains an OVER_BOUND marker
#   - Emits the canonical rejection message
#   - Passes (exits 0) for PRs with FP-suspected status (no OVER_BOUND marker)
#
# DD coverage: DD5 — /dso:fp-recovery rejects PRs with OVER_BOUND status.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/check-fp-recovery-eligibility.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# --- test_over_bound_rejected ---
# Given a simulated PR CI output containing the OVER_BOUND marker,
# the eligibility check must exit non-zero and emit the rejection message.
test_over_bound_rejected() {
    if [[ ! -x "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  at:       %s:%s\n  expected: %s to exist and be executable\n  actual:   file not found or not executable\n" \
            "over_bound_pr_rejected" "${BASH_SOURCE[0]}" "${LINENO}" "$CHECK_SCRIPT" >&2
        return
    fi

    # Simulate a PR CI output log containing the OVER_BOUND marker (as emitted by
    # llm-review-dispatch-or-skip.sh exit-3 path).
    local tmpdir
    tmpdir=$(mktemp -d)
    local ci_log="$tmpdir/pr-ci-output.txt"
    cat > "$ci_log" <<'EOF'
CONCLUSION: skipped
OVER_BOUND: acknowledged non-provenanced commits present.
Routed to admin/FP-recovery for review.
EOF

    local output exit_code
    output=$(DSO_CI_LOG="$ci_log" bash "$CHECK_SCRIPT" 2>&1) || true
    exit_code=$(DSO_CI_LOG="$ci_log" bash "$CHECK_SCRIPT" 2>&1; echo "$?") || true
    # Re-run cleanly to capture exit code
    DSO_CI_LOG="$ci_log" bash "$CHECK_SCRIPT" >/dev/null 2>&1
    exit_code=$?

    # Must exit non-zero
    assert_ne "over_bound_pr_rejected: exits non-zero" "0" "$exit_code"

    # Must emit the canonical rejection message
    local has_message
    has_message=$(DSO_CI_LOG="$ci_log" bash "$CHECK_SCRIPT" 2>&1 | grep -c "OVER_BOUND PRs are not eligible for FP-recovery" || echo 0)
    assert_ne "over_bound_pr_rejected: emits rejection message" "0" "$has_message"

    rm -rf "$tmpdir"
}

# --- test_fp_suspected_allowed ---
# Given a PR with no OVER_BOUND marker in the CI output (normal FP-suspected path),
# the eligibility check must exit 0 (allow fp-recovery to proceed).
test_fp_suspected_allowed() {
    if [[ ! -x "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  at:       %s:%s\n  expected: %s to exist and be executable\n  actual:   file not found or not executable\n" \
            "fp_suspected_allowed" "${BASH_SOURCE[0]}" "${LINENO}" "$CHECK_SCRIPT" >&2
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local ci_log="$tmpdir/pr-ci-output.txt"
    cat > "$ci_log" <<'EOF'
FINDING: critical severity — variable type mismatch in foo.sh
FINDING_COUNT: 1
REVIEWER_HASH: abc123
EOF

    DSO_CI_LOG="$ci_log" bash "$CHECK_SCRIPT" >/dev/null 2>&1
    local exit_code=$?

    assert_eq "fp_suspected_allowed: exits 0 when no OVER_BOUND marker" "0" "$exit_code"

    rm -rf "$tmpdir"
}

# --- test_empty_log_allowed ---
# An empty / absent CI log is not OVER_BOUND — allow fp-recovery to proceed.
test_empty_log_allowed() {
    if [[ ! -x "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  at:       %s:%s\n  expected: %s to exist and be executable\n  actual:   file not found or not executable\n" \
            "empty_log_allowed" "${BASH_SOURCE[0]}" "${LINENO}" "$CHECK_SCRIPT" >&2
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local ci_log="$tmpdir/nonexistent-ci-output.txt"
    # Do NOT create the file — simulate no CI log present

    DSO_CI_LOG="$ci_log" bash "$CHECK_SCRIPT" >/dev/null 2>&1
    local exit_code=$?

    assert_eq "empty_log_allowed: exits 0 when CI log absent (no OVER_BOUND signal)" "0" "$exit_code"

    rm -rf "$tmpdir"
}

# --- test_over_bound_rejection_message_content ---
# The rejection message must guide the engineer to use admin review,
# not FP-recovery, for OVER_BOUND PRs.
test_over_bound_rejection_message_content() {
    if [[ ! -x "$CHECK_SCRIPT" ]]; then
        (( ++FAIL ))
        printf "FAIL: %s\n  at:       %s:%s\n  expected: %s to exist and be executable\n  actual:   file not found or not executable\n" \
            "over_bound_rejection_message_content" "${BASH_SOURCE[0]}" "${LINENO}" "$CHECK_SCRIPT" >&2
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    local ci_log="$tmpdir/pr-ci-output.txt"
    printf "OVER_BOUND: chunking budget exceeded.\n" > "$ci_log"

    local output
    output=$(DSO_CI_LOG="$ci_log" bash "$CHECK_SCRIPT" 2>&1 || true)

    # Message must distinguish OVER_BOUND from FP-suspected
    local mentions_admin
    mentions_admin=$(echo "$output" | grep -ic "admin" || echo 0)
    assert_ne "over_bound_rejection_message_content: message mentions admin review" "0" "$mentions_admin"

    rm -rf "$tmpdir"
}

test_over_bound_rejected
test_fp_suspected_allowed
test_empty_log_allowed
test_over_bound_rejection_message_content

print_summary
