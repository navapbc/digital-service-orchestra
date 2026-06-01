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

# rc_sha_is_reviewed REPO SHA [PR_UNDER_REVIEW]
#
#   Echoes "<covering_pr>:<covering_head_sha>" (the review evidence) on success.
#   Returns:
#     0 = REVIEWED        (a covering merged PR has a passing review check-run)
#     1 = NOT REVIEWED    (resolved cleanly; no covering PR with a passing review)
#     2 = ERROR/AMBIGUOUS (API/parse failure — caller MUST fail closed)

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

    pulls_json="$(_rc_gh api "repos/${repo}/commits/${sha}/pulls" 2>/dev/null)" || return 2
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
    if head:
        print(f\"{pr.get('number','')}\t{head}\")
" 2>/dev/null)"
    local _filter_rc=$?
    [[ $_filter_rc -eq 3 ]] && return 2          # parse error -> fail closed
    [[ -z "$covering" ]] && return 1             # no covering merged PR -> not reviewed

    while IFS=$'\t' read -r cov_pr cov_head; do
        [[ -z "$cov_head" ]] && continue
        check_json="$(_rc_gh api "repos/${repo}/commits/${cov_head}/check-runs" 2>/dev/null)" || return 2
        verdict="$(printf '%s' "$check_json" | rc_review_check_verdict)"
        case "$verdict" in
            passed)    printf '%s:%s' "$cov_pr" "$cov_head"; return 0 ;;
            failed|not_found) continue ;;
            *)         return 2 ;;                # parse/unknown -> fail closed
        esac
    done <<< "$covering"

    return 1   # had covering PR(s) but none carried a passing review
}
