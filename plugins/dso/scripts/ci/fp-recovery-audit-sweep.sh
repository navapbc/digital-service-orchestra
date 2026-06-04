#!/usr/bin/env bash
# fp-recovery-audit-sweep.sh — W3d (Goal-6b): post-hoc bypass audit.
#
# When a human bypass actor merges a PR to main via the web UI (the only override
# path under the Goal-4 containment model), the llm-review check may have been
# skipped or failed. This sweep walks recently-merged main PRs, finds any that
# lack a PASSING review check (llm-review / review-sub-pr), and records a
# TAMPER-EVIDENT, HMAC-signed marker for each — so a bypass can never be silently
# lost from the audit trail. It is a REPORTING tool (it does not block).
#
# Inputs (env):
#   GH_REPO              owner/name (default: gh repo view)
#   DSO_AUDIT_HMAC_KEY   REQUIRED — the secret signing key (e.g. a repo secret).
#   DSO_AUDIT_LOOKBACK   number of most-recent merged main PRs to scan (default 30)
#   DSO_AUDIT_OUTPUT     file to APPEND markers to (default: stdout only)
#   DSO_GH_BIN           gh override (tests)
#
# Output: one JSON marker per bypassed PR:
#   {"pr":N,"merge_sha":"...","merged_at":"...","review_status":"missing|failed",
#    "marker_version":1,"hmac_sha256":"<hex over pr|merge_sha|merged_at|review_status>"}
#
# Exit codes:
#   0  sweep completed (markers emitted for any bypassed PRs found)
#   1  hard error (API failure on the PR list — fail loud so the sweep is not
#      silently empty)
#   78 precondition not met (no gh / no HMAC key)

set -uo pipefail

_GH() { "${DSO_GH_BIN:-gh}" "$@"; }
_precondition_not_met() { echo "PRECONDITION_NOT_MET: $1" >&2; exit 78; }

# Shared poison-on-failure review verdict (single source of truth; also used by
# review-coverage-lib.sh). Sourced rather than re-inlined to avoid drift in this
# security-load-bearing predicate.
_FPA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_FPA_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_FPA_DIR/../.." 2>/dev/null && pwd)}"
_FPA_LIB="${DSO_REVIEW_COVERAGE_LIB:-${_FPA_PLUGIN_ROOT}/scripts/lib/review-coverage-lib.sh}"
if [[ ! -f "$_FPA_LIB" ]]; then
    echo "PRECONDITION_NOT_MET: review-coverage lib (for rc_review_check_verdict) not found: $_FPA_LIB" >&2
    exit 78
fi
# shellcheck source=../lib/review-coverage-lib.sh
source "$_FPA_LIB"

# ── 0cd7 DD3: exempt-merge scaffolding (the audit had none before this story) ──
# A merged main PR whose content carries NO reviewable application code is NOT a
# bypass — flagging it would be audit noise. Two diff-scoped exemptions, IDENTICAL
# to the other two consumers (DD6 equivalence test):
#   (a) a CLEAN merge commit (>=2 parents, empty combined diff) — its parents are
#       reviewed independently;
#   (b) a TICKETS_ONLY commit (shared rc_diff_is_tickets_only) — diff entirely in
#       the ticket store.
# AUDIT ERROR POSTURE (distinct from coverage's fail-closed-BLOCK): this is a
# non-blocking REPORTING tool, so it must POSITIVELY CONFIRM the exemption to skip a
# PR. Any doubt — local commit not checked out, git error, rc_diff returns 2 — yields
# NOT-exempt, so the PR is RECORDED for manual follow-up rather than silently dropped.
# Requires the merge SHA to be present locally (CI: actions/checkout fetch-depth 0);
# when it is not, the PR is (correctly) recorded.
_fpa_is_exempt_merge() {
    local _s="${1:-}" _parents _cc
    [[ -z "$_s" ]] && return 1
    git rev-parse --verify --quiet "${_s}^{commit}" >/dev/null 2>&1 || return 1  # not local -> record
    # (a) clean merge: >=2 parents AND empty combined diff (positive-confirm only).
    _parents="$(git rev-list --parents -n1 "$_s" 2>/dev/null)" || return 1
    if [[ "$(printf '%s' "$_parents" | wc -w)" -ge 3 ]]; then
        _cc="$(git diff-tree --cc --no-commit-id "$_s" 2>/dev/null)" || return 1
        [[ -z "$_cc" ]] && return 0      # clean merge -> exempt
        return 1                         # evil merge -> record
    fi
    # (b) tickets-only (shared predicate; rc 0 = exempt, 1/2 = record).
    declare -F rc_diff_is_tickets_only >/dev/null 2>&1 || return 1
    rc_diff_is_tickets_only "$_s"
}

command -v "${DSO_GH_BIN:-gh}" >/dev/null 2>&1 || _precondition_not_met "gh not in PATH"
command -v python3 >/dev/null 2>&1 || _precondition_not_met "python3 not in PATH"
[[ -n "${DSO_AUDIT_HMAC_KEY:-}" ]] || _precondition_not_met "DSO_AUDIT_HMAC_KEY not set (cannot sign markers)"

REPO="${GH_REPO:-$(_GH repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")}"
[[ -z "$REPO" ]] && _precondition_not_met "cannot resolve GH_REPO"
LOOKBACK="${DSO_AUDIT_LOOKBACK:-30}"
OUTPUT="${DSO_AUDIT_OUTPUT:-}"

# Canonical HMAC-SHA256 over "pr|merge_sha|merged_at|review_status".
# The key is passed via STDIN, not the process environment, so it is not visible
# in /proc/<pid>/environ and cannot leak through a subprocess error message.
_hmac() {
    printf '%s' "$DSO_AUDIT_HMAC_KEY" | python3 -c "
import hmac, hashlib, sys
key = sys.stdin.buffer.read()
msg = sys.argv[1].encode()
print(hmac.new(key, msg, hashlib.sha256).hexdigest())
" "$1"
}

# Fetch the most-recent closed PRs targeting main. Fail loud on API error.
_pr_list="$(_GH api "repos/${REPO}/pulls?state=closed&base=main&per_page=${LOOKBACK}&sort=updated&direction=desc" 2>/dev/null)" || {
    echo "ERROR [audit]: failed to list closed PRs for ${REPO} — sweep aborted (not silently empty)" >&2
    exit 1
}
if [[ -z "$_pr_list" ]]; then
    echo "ERROR [audit]: empty PR list response — sweep aborted" >&2
    exit 1
fi

# Extract merged PRs as "number<TAB>merge_commit_sha<TAB>head_sha<TAB>merged_at".
_merged="$(printf '%s' "$_pr_list" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
prs = data if isinstance(data, list) else data.get('items', [])
for pr in prs:
    if not isinstance(pr, dict) or not pr.get('merged_at'):
        continue
    print(f\"{pr.get('number','')}\t{pr.get('merge_commit_sha','')}\t{(pr.get('head') or {}).get('sha','')}\t{pr.get('merged_at','')}\")
" 2>/dev/null)" || { echo "ERROR [audit]: could not parse PR list" >&2; exit 1; }

_scanned=0; _bypassed=0
while IFS=$'\t' read -r _num _merge _head _at; do
    [[ -z "$_num" ]] && continue
    _scanned=$(( _scanned + 1 ))
    # Review verdict on the PR head: poison-on-failure (failure-class blocks).
    # Distinguish an API failure (status unknowable) from a genuinely-absent review
    # check: an API error must NOT be silently classified as 'missing' (which would
    # be indistinguishable from a real bypass). On API error, record review_status
    # =unknown so the PR enters the audit trail for manual follow-up rather than
    # being mis-credited.
    _checks_rc=0
    _checks="$(_GH api "repos/${REPO}/commits/${_head}/check-runs" 2>/dev/null)" || _checks_rc=$?
    if [[ "$_checks_rc" -ne 0 ]]; then
        echo "WARNING [audit]: check-runs API failed for PR #${_num} (head ${_head:0:8}); recording review_status=unknown" >&2
        _verdict="unknown"
    else
        # Shared verdict (passed|failed|not_found|error). Map the audit-marker enum:
        # not_found/error -> 'missing' (no review evidence found in a valid response).
        _verdict="$(printf '%s' "$_checks" | rc_review_check_verdict)"
        case "$_verdict" in
            not_found|error|'') _verdict="missing" ;;
        esac
    fi
    [[ "$_verdict" == "passed" ]] && continue   # genuinely reviewed — not a bypass
    # 0cd7 DD3: a PR carrying no reviewable content (clean merge / tickets-only) is
    # not a bypass. Positive-confirm only — any doubt records the marker.
    if _fpa_is_exempt_merge "$_merge"; then
        echo "fp-recovery-audit-sweep: PR #${_num} (merge ${_merge:0:8}) exempt (no reviewable content) — not a bypass" >&2
        continue
    fi
    _bypassed=$(( _bypassed + 1 ))
    _sig="$(_hmac "${_num}|${_merge}|${_at}|${_verdict}")"
    _marker="$(printf '{"pr":%s,"merge_sha":"%s","merged_at":"%s","review_status":"%s","marker_version":1,"hmac_sha256":"%s"}' \
        "$_num" "$_merge" "$_at" "$_verdict" "$_sig")"
    echo "$_marker"
    if [[ -n "$OUTPUT" ]]; then
        mkdir -p "$(dirname "$OUTPUT")" 2>/dev/null || true
        echo "$_marker" >> "$OUTPUT"
    fi
done <<< "$_merged"

echo "fp-recovery-audit-sweep: scanned ${_scanned} merged main PR(s); ${_bypassed} lacked a passing review (markers emitted)" >&2
exit 0
