#!/usr/bin/env bash
# review-gate.sh — 0cd7 DD1/DD2/DD4/DD5: the single always-runs fail-closed gate.
#
# THE ARCHITECTURAL CORE. Replaces the conjunction of independently-skippable
# required checks (the no-op merge-pipeline-checks umbrella + the separate
# review-coverage-invariant and dangling-references workflows) with ONE script that
# runs them INLINE in a single process tree.
#
# WHY A SINGLE SCRIPT, NOT A `needs:`/`if: failure()` AGGREGATION (DD1): a GitHub
# Actions job that depends on upstream jobs reports SUCCESS when an upstream job is
# SKIPPED (a path filter or an `if:` condition evaluating false) — so the conjunction
# greens even though a real check never ran. This script cannot do that: it invokes
# each sub-check DIRECTLY, so a sub-check can only "skip to success" if THIS script
# decides it (never the GH scheduler). The job that runs this script has NO
# code_changed/path skip — it runs on every base==main PR.
#
# SUB-CHECKS (all inline, same process):
#   1. review-coverage-invariant.sh — every SHA in origin/main..HEAD is PROVEN
#      reviewed, EXCEPT a SHA whose diff is entirely within the ticket store
#      (shared rc_diff_is_tickets_only; 0cd7 DD2/DD3). (SC1/SC4)
#   2. check-dangling-references.sh  — symbol-level cross-change conflict at the
#      combined head; runs inline so it cannot independently skip-to-success. (DD4)
#
# DD5 — RECONCILIATION WITH assert-review-liveness.sh (complementary, NOT subsumed):
#   - assert-review-liveness asserts, for the CURRENT PR's llm-review job, that a
#     review RAN (findings.json present/non-empty) OR the diff is genuinely
#     allowlist-only (it re-runs skip-review-check.sh as a cross-check). It is a
#     per-PR review-PRESENCE assertion.
#   - review-gate asserts per-SHA review COVERAGE over origin/main..HEAD plus
#     combined-head integrity (dangling refs). Different question, different scope.
#   Neither subsumes the other; both run unconditionally. This script intentionally
#   does NOT re-implement liveness's code_changed classification cross-check — that
#   remains its own ci.yml step. The boundary is documented here so a future
#   maintainer does not collapse the two.
#
# MODE (DSO_REVIEW_GATE_MODE: warn|enforce, default warn): the SINGLE source of mode
# truth. It is propagated to BOTH sub-checks (DSO_COVERAGE_INVARIANT_MODE /
# DSO_DANGLING_MODE) so a sub-check can never pass in warn while the gate enforces.
# warn  -> sub-check violations log ::warning and the gate exits 0 (rollout/shadow).
# enforce -> any sub-check violation OR unmet precondition fails the gate closed.
# Per-sub-check preconditions (exit 78) are mapped through precondition-gate.sh with
# the gate mode, so a transient/precondition failure blocks under enforce and is
# advisory under warn — identical fail-closed semantics across both carriers.
#
# Sub-check script paths are overridable (DSO_REVIEW_GATE_COVERAGE_SCRIPT /
# DSO_REVIEW_GATE_DANGLING_SCRIPT) for behavioral testing; they default to the
# real plugin scripts.
#
# Exit codes:
#   0  all sub-checks ok (or warn mode)
#   1  at least one sub-check failed or had an unmet precondition (enforce mode)

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="${DSO_REVIEW_GATE_MODE:-warn}"
if [[ "$MODE" != "warn" && "$MODE" != "enforce" ]]; then
    echo "review-gate: invalid DSO_REVIEW_GATE_MODE='${MODE}' (expected warn|enforce) — fail closed" >&2
    exit 1
fi

_COVERAGE_SCRIPT="${DSO_REVIEW_GATE_COVERAGE_SCRIPT:-${_DIR}/review-coverage-invariant.sh}"
_DANGLING_SCRIPT="${DSO_REVIEW_GATE_DANGLING_SCRIPT:-${_DIR}/check-dangling-references.sh}"
_PRECOND_GATE="${DSO_REVIEW_GATE_PRECOND_SCRIPT:-${_DIR}/precondition-gate.sh}"

# Propagate the single mode-of-truth to both sub-checks. They apply MODE internally
# for VIOLATIONS (warn -> exit 0 + ::warning); preconditions (exit 78) are mapped
# centrally below via precondition-gate.sh so the policy is identical and testable.
export DSO_COVERAGE_INVARIANT_MODE="$MODE"
export DSO_DANGLING_MODE="$MODE"

_overall=0
_ran=0

# _run_subcheck <label> <script-path>
#   Runs the sub-check inline, maps its exit through precondition-gate.sh with the
#   gate MODE, and folds the result into _overall. A MISSING sub-check script is a
#   precondition failure (treated as rc=78) — fail closed under enforce, never
#   silently skipped (a missing check must not green the gate).
_run_subcheck() {
    local label="$1" script="$2" rc
    if [[ ! -f "$script" ]]; then
        echo "review-gate: ${label} script not found: ${script}" >&2
        rc=78
    else
        echo "review-gate: running ${label} (mode=${MODE})"
        bash "$script"
        rc=$?
    fi
    _ran=$(( _ran + 1 ))
    # Map precondition (78) per mode; any other rc passes through (0 ok, non-0 block).
    bash "$_PRECOND_GATE" "$rc" "$MODE" "$label"
    local mapped=$?
    if [[ "$mapped" -ne 0 ]]; then
        echo "review-gate: ${label} -> FAIL (rc=${rc}, mapped=${mapped})" >&2
        _overall=1
    else
        echo "review-gate: ${label} -> ok (rc=${rc})"
    fi
}

# DD1: BOTH sub-checks always run — never short-circuit. Running the second even
# after the first fails preserves full observability (you see every violation in
# one run) and is the property that makes this a true always-runs gate.
_run_subcheck "review-coverage-invariant" "$_COVERAGE_SCRIPT"
_run_subcheck "dangling-references" "$_DANGLING_SCRIPT"

echo "review-gate: ${_ran} sub-check(s) ran; mode=${MODE}; overall=$([[ $_overall -eq 0 ]] && echo ok || echo FAIL)"

if [[ "$_overall" -ne 0 ]]; then
    if [[ "$MODE" == "warn" ]]; then
        # Defense in depth: sub-checks already map their own warn behavior to exit 0,
        # so reaching here in warn implies a sub-check returned non-zero under warn
        # (e.g. a hard precondition the sub-check did not mode-gate). Keep the gate
        # advisory in warn — log, do not block.
        echo "::warning::review-gate found sub-check failures — MODE=warn (not blocking this run)"
        exit 0
    fi
    echo "::error::review-gate FAILED — one or more sub-checks did not pass (enforce mode)" >&2
    exit 1
fi
exit 0
