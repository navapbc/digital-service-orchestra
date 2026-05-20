#!/usr/bin/env bash
# check-fp-recovery-eligibility.sh — pre-check gate for /dso:fp-recovery.
#
# Verifies that a PR is eligible for FP-recovery. Rejects PRs whose CI
# llm-review produced an OVER_BOUND status, because OVER_BOUND means the PR
# exceeded the hard upper bound (max_files × max_calls) and was routed to
# admin review — it is NOT a false-positive from the LLM reviewer; it never
# reached the LLM at all. Using fp-recovery to clear an OVER_BOUND PR would
# bypass admin review, defeating the budget enforcement.
#
# Usage:
#   DSO_CI_LOG=<path-to-ci-output-log> bash check-fp-recovery-eligibility.sh
#
# Environment variables:
#   DSO_CI_LOG   Path to the CI llm-review job output log to inspect.
#                If absent or the file does not exist, eligibility is assumed
#                (no OVER_BOUND signal → proceed with fp-recovery).
#
# Exit codes:
#   0  — PR is eligible for FP-recovery; proceed.
#   1  — PR is NOT eligible: OVER_BOUND status detected; admin review required.

set -uo pipefail

_CI_LOG="${DSO_CI_LOG:-}"

# If no CI log is provided or the file does not exist, no OVER_BOUND signal
# is present — fp-recovery may proceed.
if [[ -z "$_CI_LOG" || ! -f "$_CI_LOG" ]]; then
    exit 0
fi

# Check for the OVER_BOUND marker as emitted by llm-review-dispatch-or-skip.sh
# exit-3 path: "OVER_BOUND: ..."
if grep -q "^OVER_BOUND:" "$_CI_LOG" 2>/dev/null; then
    echo "ERROR: OVER_BOUND PRs are not eligible for FP-recovery — these require admin attention (chunking budget exceeded, not a false-positive)." >&2
    echo "The CI llm-review never ran on this PR because it exceeded the max_files × max_calls hard upper bound." >&2
    echo "Next step: request admin review or split the PR into smaller chunks." >&2
    exit 1
fi

exit 0
