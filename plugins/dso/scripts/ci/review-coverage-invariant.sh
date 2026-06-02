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
#   DSO_COVERAGE_INVARIANT_MODE   enforce (default) | warn  (warn = log + exit 0,
#                                 for staged rollout before wiring as required)
#   DSO_GH_BIN                    gh override (tests)
#
# Exit codes:
#   0  every base..head SHA is proven reviewed (or warn mode)
#   1  at least one SHA is unreviewed, OR a fail-closed condition (enforce mode)
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

_total=0; _ledger_hits=0; _verified=0; _unreviewed=0; _errors=0; _exempt_merges=0
_violations=""

# A merge commit (>=2 parents) that introduces NO content of its own (empty
# combined diff) carries no standalone reviewable code: its parents are
# enumerated in THIS SAME base..head walk and verified independently, so the
# merge adds nothing to review. Such a commit is EXEMPT. This is NOT a
# reachability shortcut — the exemption is gated on the commit being a *clean*
# merge. An EVIL merge (manual conflict-resolution edits → non-empty combined
# diff) is NOT exempt and still requires a covering review. Fail closed: if
# parentage or the combined diff cannot be computed, return non-zero (do NOT
# exempt).
#
# Why this is required: the two-tier staged->main flow's HEAD is always the
# staged merge commit, which no MERGED PR covers — A3b (review-coverage-lib.sh)
# excludes the sub-PR whose merge_commit_sha IS this SHA, and A1 excludes the
# open PR under review. Without this exemption the invariant returns
# false-UNREVIEWED for that merge commit and blocks every legitimate
# staged->main PR. The code-bearing (non-merge) commits in the range remain
# fully verified.
_is_clean_merge() {
    local _s="$1" _parents _cc
    _parents="$(git rev-list --parents -n1 "$_s" 2>/dev/null)" || return 1
    # tokens = self + N parents; a merge has >=2 parents => >=3 tokens.
    [[ "$(printf '%s' "$_parents" | wc -w)" -ge 3 ]] || return 1
    # Evil-merge guard: any combined-diff content => the merge has its own
    # changes => NOT a clean merge (must be reviewed).
    _cc="$(git diff-tree --cc --no-commit-id "$_s" 2>/dev/null)" || return 1
    [[ -z "$_cc" ]]
}

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
    # Clean-merge exemption (see _is_clean_merge): a merge commit with no content
    # of its own is covered by its independently-verified parents in this walk.
    if _is_clean_merge "$_sha"; then
        _exempt_merges=$(( _exempt_merges + 1 ))
        continue
    fi
    # Perf prefilter: a ledger HIT (proven reviewed in a prior run) skips
    # re-verification. This is a ledger hit, NOT reachability-to-main.
    if _ledger_has "$_sha"; then
        _ledger_hits=$(( _ledger_hits + 1 ))
        continue
    fi
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
            _violations+="  FAIL_CLOSED ${_sha} — could not confirm review (API/parse error)"$'\n'
            ;;
    esac
done <<< "$_SHAS"

echo "review-coverage-invariant: ${_total} SHA(s) in ${_BASE_REF}..${_HEAD} — verified=${_verified} exempt_merges=${_exempt_merges} ledger_hits=${_ledger_hits} unreviewed=${_unreviewed} errors=${_errors}"

if (( _unreviewed == 0 && _errors == 0 )); then
    echo "review-coverage-invariant: ok (every SHA proven reviewed)"
    exit 0
fi

echo "ERROR [coverage]: coverage invariant VIOLATED — unreviewed/unconfirmable SHAs reach ${_BASE_REF}:" >&2
printf '%s' "$_violations" >&2
echo "ERROR [coverage]: review is proven by a passing review check-run on a covering merged PR — NEVER inferred from reachability to ${_BASE_REF}." >&2

if [[ "$MODE" == "warn" ]]; then
    echo "::warning::review-coverage-invariant found ${_unreviewed} unreviewed + ${_errors} unconfirmable SHA(s) — MODE=warn (not blocking this run)"
    exit 0
fi
exit 1
