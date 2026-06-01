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

command -v "${DSO_GH_BIN:-gh}" >/dev/null 2>&1 || _precondition_not_met "gh not in PATH"
command -v python3 >/dev/null 2>&1 || _precondition_not_met "python3 not in PATH"
[[ -n "${DSO_AUDIT_HMAC_KEY:-}" ]] || _precondition_not_met "DSO_AUDIT_HMAC_KEY not set (cannot sign markers)"

REPO="${GH_REPO:-$(_GH repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")}"
[[ -z "$REPO" ]] && _precondition_not_met "cannot resolve GH_REPO"
LOOKBACK="${DSO_AUDIT_LOOKBACK:-30}"
OUTPUT="${DSO_AUDIT_OUTPUT:-}"

# Canonical HMAC-SHA256 over "pr|merge_sha|merged_at|review_status".
_hmac() {
    DSO_AUDIT_HMAC_KEY="$DSO_AUDIT_HMAC_KEY" python3 -c "
import hmac, hashlib, os, sys
key = os.environ['DSO_AUDIT_HMAC_KEY'].encode()
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
    _checks="$(_GH api "repos/${REPO}/commits/${_head}/check-runs" 2>/dev/null)" || _checks=""
    _verdict="$(printf '%s' "$_checks" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    print('missing'); sys.exit(0)
runs = data.get('check_runs', []) if isinstance(data, dict) else []
m = [r for r in runs if 'review-sub-pr' in r.get('name','') or 'llm-review' in r.get('name','')]
fail = [r for r in m if r.get('conclusion') in ('failure','cancelled','timed_out','action_required')]
ok = [r for r in m if r.get('conclusion') == 'success']
print('failed' if fail else ('passed' if ok else 'missing'))
" 2>/dev/null)"
    [[ "$_verdict" == "passed" ]] && continue   # genuinely reviewed — not a bypass
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
