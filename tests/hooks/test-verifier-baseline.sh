#!/usr/bin/env bash
# tests/hooks/test-verifier-baseline.sh
# Baseline behavioral tests for pre-commit-compliance-verifier.sh and commit-step.sh.
# Story 256a: pins the verifier clean-path behavior and the breadcrumb log regression (bug 7b41-3061).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

VERIFIER="$REPO_ROOT/plugins/dso/hooks/pre-commit-compliance-verifier.sh"
COMMIT_STEP="$REPO_ROOT/plugins/dso/scripts/commit-step.sh"

# ── Isolation helpers ──
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup_tmpdirs EXIT

_make_artifacts_dir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Test 1: test_validate_ci_clean ──
# Given: all 5 required step artifacts present with exit_code 0
# When:  pre-commit-compliance-verifier.sh is invoked with DSO_COMPLIANCE_VERIFIER_ENABLED=true
# Then:  exits 0 (clean path — no missing artifacts)
test_validate_ci_clean() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Write all 5 required step artifacts
    local required_steps=(test format lint classifier-dispatch reviewer-record)
    for step in "${required_steps[@]}"; do
        python3 -c "
import json, sys
data = {
    'step': sys.argv[1],
    'exit_code': 0,
    'stdout': '',
    'stderr': '',
    'timestamp': '2026-05-08T00:00:00Z'
}
print(json.dumps(data, indent=2))
" "$step" > "$artifacts_dir/${step}.result"
    done

    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
    DSO_COMPLIANCE_VERIFIER_ENABLED=true \
        bash "$VERIFIER" 2>/dev/null || exit_code=$?

    assert_eq "verifier_exits_0_when_all_artifacts_present" "0" "$exit_code"
}

# ── Test 2: test_bug_7b41_breadcrumb_not_empty ──
# Regression test for bug 7b41-3061: "empty breadcrumb log on non-trivial commit".
# Given: a fresh artifacts dir
# When:  commit-step.sh runs a successful command (echo ok)
# Then:  $ARTIFACTS_DIR/steps.log exists and contains at least one JSON Lines entry
test_bug_7b41_breadcrumb_not_empty() {
    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)

    # Run commit-step for the lint step; second arg is timeout-seconds (not enforced)
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir" \
        bash "$COMMIT_STEP" lint 5 echo ok 2>/dev/null || true

    local steps_log="$artifacts_dir/steps.log"

    # Assert: steps.log exists
    local log_exists="no"
    [[ -f "$steps_log" ]] && log_exists="yes"
    assert_eq "steps_log_created" "yes" "$log_exists"

    # Assert: steps.log is non-empty (at least one JSON Lines entry)
    local line_count=0
    if [[ -f "$steps_log" ]]; then
        line_count=$(wc -l < "$steps_log" | tr -d ' ')
    fi
    # line_count should be >= 1
    local has_entries="no"
    (( line_count >= 1 )) && has_entries="yes"
    assert_eq "steps_log_has_at_least_one_entry" "yes" "$has_entries"
}

test_validate_ci_clean
test_bug_7b41_breadcrumb_not_empty

print_summary
