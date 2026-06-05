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
    # Numeric status codes (5xx, 429) must appear as a STANDALONE token, not
    # embedded in a larger number (a byte count, offset, PR number, SHA fragment)
    # — otherwise "504800 bytes" or "...42900" would wrongly read as transient and
    # flip a non-transient INDETERMINATE into a retry (violating lattice rule 4,
    # "conservative: anything not provably transient is NON-transient"). Anchor on
    # non-digit boundaries.
    if printf '%s' "$_m" | grep -qE '(^|[^0-9])(5[0-9]{2}|429)([^0-9]|$)'; then
        return 0
    fi
    case "$_m" in
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

# tristate_indeterminate_escalation <gate_label> <reason> [pr_or_branch_ref]
# 3ebb DD3 — the UNIVERSAL in-channel escalation surface. Any gate that resolves
# to INDETERMINATE (after exhausting its bounded transient-retry budget) calls
# this to route the operator to the existing /dso:fp-recovery escape valve —
# instead of a bare red check or manual git surgery. Emits to stderr:
#   1. a single greppable JSON marker (machine routing + FP-rate telemetry), and
#   2. a human-readable, actionable banner.
# This is a LAST-RESORT surface: callers MUST have already retried any
# observably-transient cause (lattice rule 4). It does NOT exit — the caller
# exits TRISTATE_INDETERMINATE so the gate still blocks. It NEVER downgrades a
# genuine FAIL (only INDETERMINATE verdicts reach here).
tristate_indeterminate_escalation() {
    local _gate="${1:-unknown-gate}" _reason="${2:-verdict could not be computed}" _ref="${3:-}"
    # JSON-safe the free-text fields (collapse quotes/newlines) so the marker is
    # always parseable for telemetry regardless of the caller's reason string.
    local _gs="${_gate//\"/\'}"; _gs="${_gs//$'\n'/ }"
    local _rs="${_reason//\"/\'}"; _rs="${_rs//$'\n'/ }"
    local _next="/dso:fp-recovery${_ref:+ $_ref}"
    printf 'INDETERMINATE_ESCALATION: {"gate":"%s","reason":"%s","next_action":"%s","recovery":"in-channel"}\n' \
        "$_gs" "$_rs" "$_next" >&2
    {
        echo "================================================================="
        echo "INDETERMINATE verdict from gate '${_gate}' — the verdict could NOT be computed."
        echo "Reason: ${_reason}"
        echo "This is NOT a confirmed review violation, and transient retries are exhausted."
        echo "In-channel recovery (do NOT hand-edit git state): ${_next}"
        echo "================================================================="
    } >&2
}
