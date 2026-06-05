#!/usr/bin/env bash
# review-coverage-invariant.sh — TS-1: the fail-closed Goal-1 coverage invariant.
#
# THE HOLE IT CLOSES (P9): two places in the pipeline equate "reachable from
# origin/main" with "reviewed" — the dispatcher's `comm -23` scope filter and the
# verifier's `^origin/main` walk exclusion. Consequence: any SHA that reaches
# main UNREVIEWED (admin bypass, hotfix, or a prior slip) is permanently
# "laundered" — every later PR silently filters it out and it is never reviewed.
#
# THE INVARIANT: a SHA leaves review scope IFF a covering PR has a passing
# (poison-on-failure) review check-run — PROVEN by check-run lookup, NEVER
# inferred from reachability to origin/main. This check resolves the FULL
# origin/main..HEAD SHA set with NO reachability prefilter, then requires each
# SHA to be proven reviewed (lib/review-coverage-lib.sh::rc_sha_is_reviewed) or
# present in the durable reviewed-SHA ledger.
#
# FAIL CLOSED: any API error / not_found / shallow clone / ambiguity BLOCKS
# (exit 1). "I could not confirm review" must never pass — that is the whole
# point of a Goal-1 backstop.
#
# Inputs (env):
#   GH_REPO                       owner/name (default: gh repo view)
#   GITHUB_BASE_REF               PR base branch (default: main)
#   DSO_HEAD_SHA / GITHUB_SHA     head override (else PR head via gh, else HEAD)
#   PR_NUMBER                     self-exclusion for the covering-PR filter
#   DSO_REVIEWED_LEDGER           path to the durable reviewed-SHA ledger file.
#                                 Stores `<sha> <evidence>` for SHAs PROVEN
#                                 reviewed (reviewed=true + covering-PR evidence),
#                                 NEVER present-on-main. Reachability is allowed
#                                 ONLY as a perf prefilter that still requires a
#                                 ledger HIT to skip re-verification.
#   (admin exemption is identity-based per ADR-0022: a covering PR merged by a
#    designated bypass-actor — ruleset.bypass_user_ids — counts as reviewed-
#    equivalent inside rc_sha_is_reviewed. No ledger env, no signing key.)
#   DSO_COVERAGE_INVARIANT_MODE   enforce (default) | warn  (warn = log + exit 0,
#                                 for staged rollout before wiring as required)
#   DSO_GH_BIN                    gh override (tests)
#
# Exit codes (3ebb DD1 tristate — docs/contracts/review-tristate-lattice.md):
#   0  PASS           every base..head SHA is proven reviewed (or warn mode)
#   1  FAIL           at least one SHA is a genuine review violation (enforce) —
#                     the safe bottom; never retried/downgraded
#   75 INDETERMINATE  could not confirm review (API/parse error) with NO genuine
#                     violation (enforce) — still blocks, but a distinct signal the
#                     orchestrator may retry on a transient cause / escalate (DD3)
#   78 precondition not met (no gh / no token) — rollout-friendly, like the
#      ruleset-invariants check

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_DIR/../.." 2>/dev/null && pwd)}"
# Fail closed (precondition) if the coverage-predicate lib is missing — `source`
# does not validate its path, so a missing file would leave rc_sha_is_reviewed
# undefined and the invariant would mis-evaluate.
_REVIEW_COVERAGE_LIB="${DSO_REVIEW_COVERAGE_LIB:-${_PLUGIN_ROOT}/scripts/lib/review-coverage-lib.sh}"
if [[ ! -f "$_REVIEW_COVERAGE_LIB" ]]; then
    echo "PRECONDITION_NOT_MET: review-coverage lib not found: $_REVIEW_COVERAGE_LIB" >&2
    exit 78
fi
# shellcheck source=../lib/review-coverage-lib.sh
source "$_REVIEW_COVERAGE_LIB"
# 3ebb DD1: the tristate decidability lattice (docs/contracts/review-tristate-lattice.md).
# Fail closed (precondition) if missing — without it the verdict classifier is undefined.
_REVIEW_TRISTATE_LIB="${DSO_REVIEW_TRISTATE_LIB:-${_PLUGIN_ROOT}/scripts/lib/review-tristate-lib.sh}"
if [[ ! -f "$_REVIEW_TRISTATE_LIB" ]]; then
    echo "PRECONDITION_NOT_MET: review-tristate lib not found: $_REVIEW_TRISTATE_LIB" >&2
    exit 78
fi
# shellcheck source=../lib/review-tristate-lib.sh
source "$_REVIEW_TRISTATE_LIB"
# Identity-based admin exemption (ADR-0022, supersedes the HMAC ledger): a covering
# PR merged by a designated bypass-actor counts as reviewed-equivalent. This is
# folded into rc_sha_is_reviewed (the coverage lib already sources the bypass-actor
# set helper) — there is no separate ledger consult or signing key here.

MODE="${DSO_COVERAGE_INVARIANT_MODE:-enforce}"
LEDGER="${DSO_REVIEWED_LEDGER:-}"

_precondition_not_met() { echo "PRECONDITION_NOT_MET: $1" >&2; exit 78; }
command -v "${DSO_GH_BIN:-gh}" >/dev/null 2>&1 || _precondition_not_met "gh not in PATH"
command -v python3 >/dev/null 2>&1 || _precondition_not_met "python3 not in PATH"

# ── Resolve repo ─────────────────────────────────────────────────────────────
REPO="${GH_REPO:-$("${DSO_GH_BIN:-gh}" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")}"
[[ -z "$REPO" ]] && _precondition_not_met "cannot resolve GH_REPO"

# ── Resolve base + head (fail closed on either unresolvable or shallow) ───────
_BASE_REF="origin/${GITHUB_BASE_REF:-main}"
if ! git rev-parse --verify --quiet "$_BASE_REF" >/dev/null 2>&1; then
    echo "ERROR [coverage]: base ref ${_BASE_REF} not resolvable — fail closed" >&2
    echo "ERROR [coverage]: ensure actions/checkout fetch-depth: 0" >&2
    exit 1
fi
if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" == "true" ]]; then
    echo "ERROR [coverage]: shallow repository — cannot enumerate base..head reliably; fail closed" >&2
    echo "ERROR [coverage]: set actions/checkout fetch-depth: 0" >&2
    exit 1
fi
_HEAD=""
_pr_head=""
if [[ -n "${PR_NUMBER:-}" ]]; then
    _pr_head=$("${DSO_GH_BIN:-gh}" api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha' 2>/dev/null || echo "")
fi
for _cand in "${DSO_HEAD_SHA:-}" "$_pr_head" "${GITHUB_SHA:-}" "HEAD"; do
    [[ -z "$_cand" ]] && continue
    if git rev-parse --verify --quiet "$_cand" >/dev/null 2>&1; then _HEAD="$_cand"; break; fi
done
[[ -z "$_HEAD" ]] && { echo "ERROR [coverage]: no resolvable head — fail closed" >&2; exit 1; }

# ── Full SHA set: NO reachability/comm prefilter ─────────────────────────────
_SHAS="$(git rev-list "${_BASE_REF}..${_HEAD}" 2>/dev/null)"
if [[ -z "$_SHAS" ]]; then
    echo "review-coverage-invariant: ok (no commits in ${_BASE_REF}..${_HEAD})"
    exit 0
fi

_total=0; _ledger_hits=0; _verified=0; _unreviewed=0; _errors=0; _exempt_tickets=0
_violations=""

# cca8 (linear-history cutover, DD3): the clean-merge exemption (_is_clean_merge)
# was REMOVED. It existed because the two-tier staged->main flow's HEAD used to be
# a staged MERGE commit that no MERGED PR covers (A3b excludes the sub-PR whose
# merge_commit_sha IS that SHA). Now that the flow rebase-merges end-to-end (DD1)
# and required_linear_history forbids merge commits on main (DD2), no clean merge
# commit reaches this walk — the exemption was provably unreachable (exp L8). Its
# removal is strictly fail-closed: any merge commit that DID somehow appear now
# falls through to the normal coverage path and must be proven-reviewed like any
# other SHA, rather than being silently exempted.

_ledger_has() {
    [[ -n "$LEDGER" && -f "$LEDGER" ]] && grep -q "^$1 " "$LEDGER" 2>/dev/null
}
_ledger_add() {
    [[ -z "$LEDGER" ]] && return 0
    mkdir -p "$(dirname "$LEDGER")" 2>/dev/null || true
    printf '%s %s\n' "$1" "$2" >> "$LEDGER"
}

while IFS= read -r _sha; do
    [[ -z "$_sha" ]] && continue
    _total=$(( _total + 1 ))
    # Ticket-store diff-scoped exemption (0cd7 DD3): a commit whose ENTIRE diff is
    # within the event-sourced ticket store carries no reviewable application code.
    # Computed by the shared rc_diff_is_tickets_only (review-coverage-lib.sh) so all
    # three consumers agree (DD6). rc 0 = exempt; rc 1/2 (not-exempt OR error) falls
    # through to the normal coverage path, which itself fails closed — so an error
    # here can never launder an unreviewed SHA.
    if rc_diff_is_tickets_only "$_sha"; then
        _exempt_tickets=$(( _exempt_tickets + 1 ))
        continue
    fi
    # Perf prefilter: a ledger HIT (proven reviewed in a prior run) skips
    # re-verification. This is a ledger hit, NOT reachability-to-main.
    if _ledger_has "$_sha"; then
        _ledger_hits=$(( _ledger_hits + 1 ))
        continue
    fi
    # Admin exemption is identity-based (ADR-0022): a covering PR merged by a
    # designated bypass-actor is recognized as reviewed-equivalent INSIDE
    # rc_sha_is_reviewed below (it returns 0 with "admin-merged-by:<id>" evidence),
    # so admin-bypassed SHAs are counted as _verified — no separate consult, no key.
    _evidence="$(rc_sha_is_reviewed "$REPO" "$_sha" "${PR_NUMBER:-0}")"
    case $? in
        0)
            _verified=$(( _verified + 1 ))
            _ledger_add "$_sha" "$_evidence"
            ;;
        1)
            _unreviewed=$(( _unreviewed + 1 ))
            _violations+="  UNREVIEWED ${_sha} — no covering merged PR with a passing review check-run"$'\n'
            ;;
        *)
            _errors=$(( _errors + 1 ))
            _violations+="  INDETERMINATE ${_sha} — could not confirm review (API/parse error)"$'\n'
            ;;
    esac
done <<< "$_SHAS"

echo "review-coverage-invariant: ${_total} SHA(s) in ${_BASE_REF}..${_HEAD} — verified=${_verified} exempt_tickets=${_exempt_tickets} ledger_hits=${_ledger_hits} unreviewed=${_unreviewed} errors=${_errors}"

# 3ebb DD1: resolve the per-SHA tallies through the tristate lattice. A genuine
# unreviewed SHA is FAIL (1, the safe bottom — never retried/downgraded); a
# could-not-confirm-only run is INDETERMINATE (75) — still blocking under enforce,
# but a distinct signal the orchestrator may retry on an observably-transient
# cause and otherwise route to in-channel escalation (DD3). Never PASS on
# inferred-benign: an unconfirmable SHA is never assumed reviewed.
_verdict="$(tristate_classify_verdict "$_unreviewed" "$_errors")"; _verdict_code=$?
if [[ "$_verdict" == "PASS" ]]; then
    echo "review-coverage-invariant: ok (every SHA proven reviewed)"
    exit 0
fi

echo "ERROR [coverage]: coverage invariant ${_verdict} — unreviewed/unconfirmable SHAs reach ${_BASE_REF}:" >&2
printf '%s' "$_violations" >&2
echo "ERROR [coverage]: review is proven by a passing review check-run on a covering merged PR — NEVER inferred from reachability to ${_BASE_REF}." >&2

if [[ "$MODE" == "warn" ]]; then
    echo "::warning::review-coverage-invariant verdict=${_verdict} (unreviewed=${_unreviewed} errors=${_errors}) — MODE=warn (not blocking this run)"
    exit 0
fi
# 3ebb DD3: an INDETERMINATE verdict (could-not-confirm; per-SHA retries already
# spent in rc_sha_is_reviewed) routes to /dso:fp-recovery in-channel — not manual
# git surgery. A genuine FAIL does NOT escalate here: it is a real review
# violation, not a false-positive/uncomputable case.
if [[ "$_verdict" == "INDETERMINATE" ]] && declare -F tristate_indeterminate_escalation >/dev/null 2>&1; then
    tristate_indeterminate_escalation "review-coverage-invariant" \
        "could not confirm review for ${_errors} SHA(s) in ${_BASE_REF}..${_HEAD} (API/parse error); coverage verdict uncomputable" \
        "${PR_NUMBER:+PR#}${PR_NUMBER:-}"
fi
# FAIL -> 1; INDETERMINATE -> 75 (both block under enforce; the code is the signal).
exit "$_verdict_code"
