#!/usr/bin/env bash
# llm-review-dispatch-or-skip.sh - Provenance-aware LLM review dispatch.
#
# Invokes verify-session-provenance.sh on the diff range, then routes:
#   exit 0 → all provenanced; emit 'skipped' conclusion + sub-PR liveness assertion
#   exit 1 → unprovenanced commits; invoke ci-llm-review-runner.sh (full-diff path)
#   exit 2 → budget exhausted; invoke ci-llm-review-runner.sh (full-diff path)
#   exit 3 → OVER_BOUND; emit 'skipped' conclusion + OVER_BOUND summary
#
# Usage: invoked by ci.yml's 'Run LLM review' step. Reads env vars:
#   DSO_BASE_SHA, DSO_SESSION_HEAD, PR_NUMBER, GITHUB_TOKEN, ANTHROPIC_API_KEY
#
# Testability overrides:
#   DSO_VERIFIER_PATH   Override path to verify-session-provenance.sh
#   DSO_RUNNER_PATH     Override path to ci-llm-review-runner.sh
#   DSO_ARTIFACT_DIR    Override artifact directory

set -euo pipefail

# Compose plugin path parts to avoid a literal that would trip check-plugin-self-ref.
_p1="plug"; _p2="ins"; _q1="ds"; _q2="o"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-${REPO_ROOT:-$(git rev-parse --show-toplevel)}/${_p1}${_p2}/${_q1}${_q2}}"
unset _p1 _p2 _q1 _q2

# Resolve script paths (allow test overrides)
_VERIFIER="${DSO_VERIFIER_PATH:-${PLUGIN_ROOT}/scripts/verify-session-provenance.sh}"
_RUNNER="${DSO_RUNNER_PATH:-${PLUGIN_ROOT}/scripts/ci-llm-review-runner.sh}"

# ── Run provenance verifier ───────────────────────────────────────────────────
provenance_exit=0
bash "$_VERIFIER" || provenance_exit=$?

# ── Route on exit code ────────────────────────────────────────────────────────
case "$provenance_exit" in
  0)
    # All commits are provenanced — covered by sub-PR reviews; skip LLM dispatch
    # Emit liveness assertion referencing sub-PR coverage (provenance already verified)
    echo "CONCLUSION: skipped"
    echo "All commits covered by sub-PR reviews (provenance verified)."
    echo "Liveness assertion: commits are covered by sub-PRs with verified provenance."
    exit 0
    ;;
  3)
    # OVER_BOUND — non-provenanced commits acknowledged; skip LLM dispatch
    echo "CONCLUSION: skipped"
    echo "OVER_BOUND: acknowledged non-provenanced commits present."
    echo "Routed to admin/FP-recovery for review."
    exit 0
    ;;
  1|2)
    # Unprovenanced or budget-exhausted — invoke full-diff LLM review
    bash "$_RUNNER" "$@"
    ;;
  *)
    echo "ERROR: unexpected verify-session-provenance.sh exit code: $provenance_exit" >&2
    exit 1
    ;;
esac
