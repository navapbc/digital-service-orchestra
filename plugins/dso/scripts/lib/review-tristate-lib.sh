# shellcheck shell=bash
# review-tristate-lib.sh — 3ebb DD1: the review-gate decidability lattice.
#
# Generalizes the a85d/precondition-gate.sh exit-78 mode-gate into a three-valued
# verdict lattice shared by the Goal-1 review gates (review-coverage-invariant.sh,
# llm-review-dispatch-or-skip.sh). It exists so a gate can distinguish "I could
# not COMPUTE the verdict" (mechanical/transient) from "the verdict is a review
# VIOLATION" — without ever letting the former silently pass.
#
# Contract: docs/contracts/review-tristate-lattice.md. This lib is the executable
# source of truth for that contract.
#
# LATTICE (LOAD-BEARING — every consumer must honor it):
#   - FAIL is the safe bottom. A genuine review violation resolves to FAIL and is
#     NEVER retried, downgraded, or treated as transient.
#   - When PASS vs INDETERMINATE cannot be distinguished by evidence at decision
#     time, resolve to FAIL. Never PASS on inferred-benign (an empty diff is never
#     assumed net-zero; an unconfirmable SHA is never assumed reviewed).
#   - INDETERMINATE ("could not compute the verdict") is retry-able ONLY when the
#     cause is OBSERVABLY transient (5xx / rate-limit / timeout readable from the
#     error). It is NEVER treated as PASS. A non-transient INDETERMINATE resolves
#     to FAIL (caller's responsibility via the retry budget); the lattice itself
#     never converts INDETERMINATE to PASS.
#
# EXIT-CODE CONTRACT (also surfaced as named constants below):
#   0   PASS                  every SHA proven reviewed / verdict is clean
#   1   FAIL                  a genuine review violation — hard block, never retry
#   75  INDETERMINATE         verdict uncomputable (transient/mechanical) — the
#                             orchestrator may retry on an observably-transient
#                             cause, then route to in-channel escalation (DD3);
#                             NEVER an automatic PASS
#   78  PRECONDITION_NOT_MET  cannot even start (no gh/token/repo) — a special
#                             INDETERMINATE; mode-gated by precondition-gate.sh

# Named exit codes (consumers should `exit "$TRISTATE_INDETERMINATE"` etc.).
TRISTATE_PASS=0
TRISTATE_FAIL=1
TRISTATE_INDETERMINATE=75
TRISTATE_PRECONDITION_NOT_MET=78
export TRISTATE_PASS TRISTATE_FAIL TRISTATE_INDETERMINATE TRISTATE_PRECONDITION_NOT_MET

# tristate_classify_verdict <unreviewed_count> <error_count>
#   Resolves a gate's per-SHA tallies into the lattice verdict. Echoes the verdict
#   NAME on stdout and returns the contract exit code.
#
#   unreviewed > 0          -> FAIL (1)            violation dominates — the safe
#                                                   bottom; never downgraded even
#                                                   when errors are also present.
#   else error > 0          -> INDETERMINATE (75)  could-not-confirm only.
#   else                    -> PASS (0)
tristate_classify_verdict() {
    local _unreviewed="${1:-0}" _errors="${2:-0}"
    # Coerce non-numeric input to a fail-closed posture: an unparseable count is
    # itself an inability to confirm -> treat as an error (INDETERMINATE), never PASS.
    [[ "$_unreviewed" =~ ^[0-9]+$ ]] || _unreviewed=0
    [[ "$_errors" =~ ^[0-9]+$ ]] || _errors=1
    if (( _unreviewed > 0 )); then
        echo "FAIL"; return "$TRISTATE_FAIL"
    elif (( _errors > 0 )); then
        echo "INDETERMINATE"; return "$TRISTATE_INDETERMINATE"
    fi
    echo "PASS"; return "$TRISTATE_PASS"
}

# tristate_is_transient_error <error_text>
#   Returns 0 (retry-able) IFF the error text carries an OBSERVABLY transient
#   signature — a 5xx status, an explicit rate-limit/429, a timeout, a reset
#   connection, or a gateway/service-unavailable marker. Returns 1 otherwise.
#   The match is conservative on purpose: anything not provably transient is
#   treated as NON-transient so the caller resolves it to FAIL rather than
#   retrying a structural error forever (lattice: never retry a non-transient).
tristate_is_transient_error() {
    local _m
    _m=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    case "$_m" in
        *50[0-9]*|*429*) return 0 ;;                                  # 5xx / Too Many Requests
        *"rate limit"*|*"rate-limit"*|*ratelimit*) return 0 ;;        # rate limiting
        *timeout*|*"timed out"*) return 0 ;;                          # timeouts
        *"connection reset"*|*"connection refused"*) return 0 ;;      # transient connectivity
        *"temporarily unavailable"*|*"service unavailable"*) return 0 ;;
        *gateway*) return 0 ;;                                        # bad/timeout gateway
        *) return 1 ;;
    esac
}

# tristate_code_to_name <exit_code>  -> verdict name on stdout (UNKNOWN for others)
tristate_code_to_name() {
    case "${1:-}" in
        0)  echo "PASS" ;;
        1)  echo "FAIL" ;;
        75) echo "INDETERMINATE" ;;
        78) echo "PRECONDITION_NOT_MET" ;;
        *)  echo "UNKNOWN" ;;
    esac
}
