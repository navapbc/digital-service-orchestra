#!/usr/bin/env bash
# review-coverage-lib.sh — the "reviewed(SHA)" predicate for TS-1.
#
# Sourced by review-coverage-invariant.sh (the fail-closed Goal-1 coverage
# invariant). Mirrors the G3 routine in verify-session-provenance.sh:484-634
# ("a SHA is reviewed iff a covering MERGED PR has a passing review check-run"),
# but with a STRICTER error posture: where the verifier treats an API error /
# not_found as "unprovenanced → route to review" (safe in that context), the
# coverage INVARIANT must FAIL CLOSED on any ambiguity (return 2 → caller
# blocks). The invariant is the last line of defense against unreviewed code
# reaching main, so "I could not confirm" must block, never pass.
#
# CRITICAL — the laundering this defends against (P9 / TS-1): reachability from
# origin/main is NOT review. This predicate NEVER consults reachability; it only
# ever returns "reviewed" on a proven passing review check-run on a covering
# merged PR. Do NOT add a `comm -23` / `^origin/main` shortcut here.

# Allow a mock gh in tests via DSO_GH_BIN (default: gh).
_rc_gh() { "${DSO_GH_BIN:-gh}" "$@"; }

# ── CF-6 (story 7b77): retry/backoff classifier ──────────────────────────────
# The coverage INVARIANT must not wedge the whole team on a single transient GitHub
# blip. Classify a gh error so a transient cause (rate-limit / server 5xx / timeout)
# is RETRIED with bounded backoff before blocking, while a config error (auth /
# scope / not-found) blocks IMMEDIATELY — retrying cannot fix a bad token.
#   _rc_classify_gh_error <stderr-text> -> "transient" | "config" | "unknown"
_rc_classify_gh_error() {
    local lc="${1,,}"   # lowercase for case-insensitive matching
    if [[ "$lc" == *"rate limit"* || "$lc" == *"secondary rate"* || "$lc" == *"abuse"* \
          || "$lc" == *"429"* || "$lc" == *"500"* || "$lc" == *"502"* || "$lc" == *"503"* \
          || "$lc" == *"504"* || "$lc" == *"server error"* || "$lc" == *"bad gateway"* \
          || "$lc" == *"unavailable"* || "$lc" == *"timeout"* || "$lc" == *"timed out"* ]]; then
        echo transient; return 0
    fi
    if [[ "$lc" == *"bad credentials"* || "$lc" == *"401"* || "$lc" == *"scope"* \
          || "$lc" == *"not accessible"* || "$lc" == *"403"* || "$lc" == *"404"* \
          || "$lc" == *"not found"* || "$lc" == *"unauthorized"* || "$lc" == *"forbidden"* ]]; then
        echo config; return 0
    fi
    echo unknown; return 0
}

# _rc_gh_with_backoff <gh args...> — run gh, retrying ONLY transient failures with
# bounded exponential backoff. Echoes stdout + returns 0 on success; returns 2 on
# transient-exhausted (RETRYABLE — a re-run warm-hits the ledger and converges,
# CF-6 E5); returns 3 on a config/unknown error (block now). Tunable via
# GH_RETRY_MAX (default 5) and GH_BACKOFF_INITIAL seconds (default 2; tests set 0).
_rc_gh_with_backoff() {
    local out code cls retries=0
    local _max="${GH_RETRY_MAX:-5}" _delay="${GH_BACKOFF_INITIAL:-2}"
    # Capture the caller's errexit so we can disable it around the command
    # substitution and then RESTORE it — never leak set -e into a caller that did
    # not have it (e.g. a test harness).
    local _had_e=0; case $- in *e*) _had_e=1 ;; esac
    while true; do
        set +e
        out="$(_rc_gh "$@" 2>&1)"
        code=$?
        (( _had_e )) && set -e
        if [[ $code -eq 0 ]]; then
            printf '%s' "$out"
            return 0
        fi
        cls="$(_rc_classify_gh_error "$out")"
        if [[ "$cls" == "transient" ]]; then
            retries=$(( retries + 1 ))
            if (( retries >= _max )); then
                echo "rc_gh: transient errors exhausted after ${_max} attempts (retryable — re-run converges via warm ledger): ${out:0:160}" >&2
                return 2
            fi
            if (( _delay > 0 )); then
                sleep "$_delay"; _delay=$(( _delay * 2 )); (( _delay > 60 )) && _delay=60
            fi
            continue
        fi
        echo "rc_gh: non-retryable (${cls}) error — blocking now (fix the cause, do not re-run): ${out:0:160}" >&2
        return 3
    done
}

# ADR-0022 (identity-based admin exemption): a covering PR merged by a designated
# bypass-actor (server-set merged_by) makes the SHA reviewed-equivalent. Source the
# set-membership helper (sibling lib). Replaces the HMAC admin-exemption ledger.
_RCL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_RCL_DIR/bypass-actor-set.sh"

# rc_sha_is_reviewed REPO SHA [PR_UNDER_REVIEW]
#
#   Echoes "<covering_pr>:<covering_head_sha>" (the review evidence) on success.
#   Returns:
#     0 = REVIEWED        (a covering merged PR has a passing review check-run)
#     1 = NOT REVIEWED    (resolved cleanly; no covering PR with a passing review)
#     2 = ERROR/AMBIGUOUS (API/parse failure — caller MUST fail closed)

# ── 0cd7 DD3: shared diff-scoped EXEMPTION predicate ─────────────────────────
# rc_diff_is_tickets_only <sha>
#
#   A commit is EXEMPT from per-SHA review coverage IFF its OWN diff is entirely
#   within the event-sourced ticket store. This is the ONE   # tickets-boundary-ok
#   shared helper sourced by all three coverage consumers (review-coverage-
#   invariant.sh, verify-session-provenance.sh, fp-recovery-audit-sweep.sh) so they
#   compute the IDENTICAL exemption (DD6 equivalence test guards the divergence).
#
#   AUTHORITATIVE SCOPE (2026-06-03 KEEP amendment): the ONLY exempt prefix is the
#   ticket store. The version-file COVERAGE exemption was REMOVED — under KEEP the
#   version bump rides PR1's review-sub-pr (plugin.json allowlisted) and is covered
#   per-SHA like any commit, so no separate coverage exemption is needed here.
#
#   TREE EVIDENCE ONLY: the exemption is computed from git diff-tree, NEVER from a
#   commit trailer/marker (the v4 fabricated-trailer lesson — a marker can be forged
#   into an unreviewed commit; a tree cannot). A commit mixing a ticket-store change
#   with ANY other path is NOT exempt (prevents laundering code through a ticket
#   commit). I-1 GUARD: an EMPTY file list is NOT exempt — an empty/merge diff must
#   never be silently read as "all paths are tickets"; merge handling is the caller's
#   clean-merge concern, not this predicate's.
#
#   Returns: 0 EXEMPT (all changed paths under the ticket store, >=1 path)
#            1 NOT exempt (some non-ticket path, OR empty file list)
#            2 ERROR (bad SHA / git failure) — caller MUST fail closed
RC_TICKET_STORE_PREFIX="${RC_TICKET_STORE_PREFIX:-.tickets-tracker/}"  # tickets-boundary-ok
rc_diff_is_tickets_only() {
    local _sha="${1:-}" _files _f
    [[ -z "$_sha" ]] && return 2
    # Per-commit file list vs first parent (--root handles the initial commit). A
    # merge commit produces NO entries here (no -m/--cc) -> empty -> NOT exempt,
    # which is correct: the clean-merge exemption is evaluated by the caller.
    _files="$(git diff-tree --no-commit-id --name-only -r --root "$_sha" 2>/dev/null)" || return 2
    [[ -z "$_files" ]] && return 1          # I-1: empty list is NOT exempt
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        case "$_f" in
            "$RC_TICKET_STORE_PREFIX"*) ;;  # under the ticket store -> ok
            *) return 1 ;;                  # any non-ticket path -> not exempt
        esac
    done <<< "$_files"
    return 0
}

# rc_review_check_verdict  (check-runs JSON on STDIN)
#   SINGLE SOURCE OF TRUTH for the poison-on-failure "did the review pass" verdict
#   over a SHA's check-runs. Any failure-class conclusion (failure/cancelled/
#   timed_out/action_required) on a review-sub-pr|llm-review check BLOCKS; else a
#   success passes; else not_found; parse error -> 'error'. (Was duplicated across
#   review-coverage-lib.sh, fp-recovery-audit-sweep.sh, and verify-session-
#   provenance.sh G3 — the new callers now share this; the verifier's embedded G3
#   copy is tracked for consolidation in a follow-up, see its KEEP-IN-SYNC note.)
rc_review_check_verdict() {
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print('error'); sys.exit(0)
runs = data.get('check_runs', []) if isinstance(data, dict) else []
m = [r for r in runs if 'review-sub-pr' in r.get('name','') or 'llm-review' in r.get('name','')]
fail = [r for r in m if r.get('conclusion') in ('failure','cancelled','timed_out','action_required')]
ok = [r for r in m if r.get('conclusion') == 'success']
print('failed' if fail else ('passed' if ok else 'not_found'))
" 2>/dev/null
}

rc_sha_is_reviewed() {
    local repo="$1" sha="$2" pr_under_review="${3:-0}"
    local pulls_json covering check_json verdict cov_pr cov_head

    pulls_json="$(_rc_gh_with_backoff api "repos/${repo}/commits/${sha}/pulls")" || return 2
    [[ -z "$pulls_json" ]] && return 2

    # Filter to MERGED covering PRs (A2 merged-only, A3a head!=sha, A3b
    # merge_commit!=sha, A1 self-exclusion). Emit "<number>\t<head_sha>".
    covering="$(printf '%s' "$pulls_json" | PR_UNDER_REVIEW="$pr_under_review" SHA_UNDER_REVIEW="$sha" python3 -c "
import sys, json, os
try:
    pur = int(os.environ.get('PR_UNDER_REVIEW', '0'))
except (TypeError, ValueError):
    pur = 0
sha_u = os.environ.get('SHA_UNDER_REVIEW', '')
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)               # parse error -> distinct code -> caller fails closed
prs = data['items'] if isinstance(data, dict) and 'items' in data else (data if isinstance(data, list) else None)
if prs is None:
    sys.exit(3)
for pr in prs:
    if not isinstance(pr, dict):
        continue
    if pr.get('state') != 'closed' or not pr.get('merged_at'):
        continue
    head = (pr.get('head') or {}).get('sha', '')
    # A1 self-exclusion: the PR under review cannot provide its own provenance.
    if pur > 0 and pr.get('number') == pur:
        continue
    # A3b self-merge guard only. The blanket A3a (head == sha_u) is intentionally
    # NOT applied: a DIFFERENT merged sub-PR whose head IS sha_under_review is the
    # VALID covering evidence (the common case — a sub-PR's own head commit).
    # Excluding it would return false-UNREVIEWED for every sub-PR head SHA and,
    # in enforce mode, block every legitimate staged->main merge. G3 below
    # independently re-verifies the covering PR's review check actually PASSED, so
    # keeping it cannot launder. (Mirrors the W4 fix in verify-session-provenance.sh.)
    if pr.get('merge_commit_sha') == sha_u:
        continue
    # NOTE: merged_by is intentionally NOT read here — the /commits/{sha}/pulls list
    # representation does not include it (null). The identity-exemption check (ADR-0022)
    # fetches merged_by from the single-PR GET, on the bypass path only.
    if head:
        print(f\"{pr.get('number','')}\t{head}\")
" 2>/dev/null)"
    local _filter_rc=$?
    [[ $_filter_rc -eq 3 ]] && return 2          # parse error -> fail closed
    [[ -z "$covering" ]] && return 1             # no covering merged PR -> not reviewed

    while IFS=$'\t' read -r cov_pr cov_head; do
        [[ -z "$cov_head" ]] && continue
        check_json="$(_rc_gh_with_backoff api "repos/${repo}/commits/${cov_head}/check-runs")" || return 2
        verdict="$(printf '%s' "$check_json" | rc_review_check_verdict)"
        case "$verdict" in
            passed)    printf '%s:%s' "$cov_pr" "$cov_head"; return 0 ;;
            failed|not_found)
                # ADR-0022 identity-based admin exemption: the review did not pass, but
                # if this covering PR was merged by a DESIGNATED BYPASS-ACTOR it is an
                # admin bypass and reviewed-equivalent. merged_by is NOT present in the
                # /commits/{sha}/pulls LIST representation (it is null there) — it must
                # be read from the single-PR GET. This extra call happens ONLY on the
                # rare bypass path (a covering PR whose review failed/never ran), never
                # for a normally-reviewed SHA. Forge-proof: the agent is
                # current_user_can_bypass:never, so it cannot be the merged_by on a
                # bypass; merged_by is set server-side by GitHub.
                local _mby
                _mby="$(_rc_gh_with_backoff api "repos/${repo}/pulls/${cov_pr}" --jq '.merged_by.id // empty')" || _mby=""
                if bas_is_bypass_actor "$_mby"; then
                    printf 'admin-merged-by:%s:%s' "$_mby" "$cov_pr"; return 0
                fi
                continue ;;
            *)         return 2 ;;                # parse/unknown -> fail closed
        esac
    done <<< "$covering"

    return 1   # had covering PR(s) but none carried a passing review
}
