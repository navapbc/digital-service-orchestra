#!/usr/bin/env bash
# overlay-dispatch.sh
# Overlay dispatch logic for the review workflow (story w22-25ui, task 67e2-2912).
#
# Defense-in-depth dispatch: parallel overlay when classifier emits deterministic
# signal, serial overlay when tier reviewer raises flag, no overlay when neither fires.
#
# Designed to be sourced by the commit/review workflow. Provides three functions:
#   overlay_dispatch_mode <classifier_json> <reviewer_summary>
#       Prints "parallel", "serial", or "none" to stdout.
#   run_overlay_agent <mode> <artifacts_dir>
#       Stub for overlay agent invocation; returns 0 on success, non-zero on failure.
#   overlay_dispatch_with_fallback <classifier_json> <reviewer_summary> <artifacts_dir>
#       Wraps dispatch + agent call with graceful degradation (always exits 0).

# ---------------------------------------------------------------------------
# overlay_dispatch_mode — determine overlay dispatch strategy
# ---------------------------------------------------------------------------
# Args:
#   $1 — path to classifier JSON output file
#   $2 — path to tier reviewer summary text file
# Output:
#   "parallel" | "serial" | "none" on stdout
# Exit:
#   0 on success, 1 on invalid input (missing files)
# ---------------------------------------------------------------------------
overlay_dispatch_mode() {
    local classifier_json="$1"
    local reviewer_summary="$2"

    # Validate inputs
    if [[ ! -f "$classifier_json" ]]; then
        echo "overlay_dispatch_mode: classifier JSON file not found: $classifier_json" >&2
        return 1
    fi
    if [[ ! -f "$reviewer_summary" ]]; then
        echo "overlay_dispatch_mode: reviewer summary file not found: $reviewer_summary" >&2
        return 1
    fi

    # Extract overlay dimensions from classifier JSON via the shared helper
    # (single source-of-truth — same script REVIEW-WORKFLOW.md Step 4 and
    # record-review.sh use). Empty output means no flags are true.
    local _helper
    _helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/read-overlay-flags.sh"
    local overlay_dims=""
    if [[ -x "$_helper" ]]; then
        overlay_dims="$(bash "$_helper" --mode classifier < "$classifier_json" 2>/dev/null || true)"
    fi

    # Branch 1: deterministic signal from classifier -> parallel dispatch
    if [[ -n "$overlay_dims" ]]; then
        echo "parallel"
        return 0
    fi

    # Branch 2: check reviewer summary for warranted flags (no -P flag; macOS compat)
    local sec_warranted perf_warranted tq_warranted
    sec_warranted="$(sed -n 's/^security_overlay_warranted:[[:space:]]*//p' "$reviewer_summary" 2>/dev/null | tr -d '[:space:]')"
    perf_warranted="$(sed -n 's/^performance_overlay_warranted:[[:space:]]*//p' "$reviewer_summary" 2>/dev/null | tr -d '[:space:]')"
    tq_warranted="$(sed -n 's/^test_quality_overlay_warranted:[[:space:]]*//p' "$reviewer_summary" 2>/dev/null | tr -d '[:space:]')"

    if [[ "$sec_warranted" == "yes" || "$perf_warranted" == "yes" || "$tq_warranted" == "yes" ]]; then
        echo "serial"
        return 0
    fi

    # Branch 3: no overlay needed
    echo "none"
    return 0
}

# ---------------------------------------------------------------------------
# run_overlay_agent — invoke the overlay review agent
# ---------------------------------------------------------------------------
# Args:
#   $1 — dispatch mode ("parallel" or "serial")
#   $2 — path to artifacts directory
# Exit:
#   0 on success, non-zero on failure
# ---------------------------------------------------------------------------
run_overlay_agent() {
    local mode="$1"
    local artifacts_dir="$2"

    # Stub implementation — will be wired to actual overlay agents
    # by a subsequent task. For now, succeeds silently.
    return 0
}

# ---------------------------------------------------------------------------
# overlay_dispatch_with_fallback — graceful degradation wrapper
# ---------------------------------------------------------------------------
# Wraps overlay_dispatch_mode + run_overlay_agent. If the overlay agent fails
# (non-zero exit), emits a warning to stderr but returns exit 0 so the commit
# is never blocked by overlay failures.
#
# Args:
#   $1 — path to classifier JSON output file
#   $2 — path to tier reviewer summary text file
#   $3 — path to artifacts directory
# Exit:
#   0 always (graceful degradation); 1 only on invalid input
# ---------------------------------------------------------------------------
overlay_dispatch_with_fallback() {
    local classifier_json="$1"
    local reviewer_summary="$2"
    local artifacts_dir="$3"

    local mode
    mode="$(overlay_dispatch_mode "$classifier_json" "$reviewer_summary")" || return 1

    if [[ "$mode" == "none" ]]; then
        return 0
    fi

    # Attempt overlay agent dispatch; swallow failures
    if ! run_overlay_agent "$mode" "$artifacts_dir"; then
        echo "WARNING: overlay agent ($mode) failed — continuing without overlay review" >&2
    fi

    return 0
}
