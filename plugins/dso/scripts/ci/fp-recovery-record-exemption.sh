#!/usr/bin/env bash
# fp-recovery-record-exemption.sh — record FP-recovery-cleared SHAs in the
# admin-exemption ledger so an admin override on a (sub-)PR PROPAGATES.
#
# THE PROBLEM (epic 588e / 3ebb DD4, gap G-B): when FP-recovery clears a PR's
# blocking llm-review finding and a human merges it via the web UI, the cleared
# commits land WITHOUT a passing review-check. Under enforce, the coverage
# invariant on the NEXT PR (e.g. PR2 staged->main) walks those SHAs, finds no
# passing review, and fail-closes — forcing a SECOND admin override per PR. The
# admin-exemption ledger (story 2730) exists to break this, but nothing wrote it.
#
# THIS SCRIPT is the producer: after an FP-recovery clearance it appends an
# HMAC-signed exemption entry for each commit the (sub-)PR introduced, so the
# coverage invariant treats them as reviewed-equivalent thereafter. It handles
# BOTH a review-sub-pr (PR1 source->staged, the COMMON case where the LLM runs)
# and a main llm-review (PR2) — the SHA set is just base..head either way.
#
# Usage:
#   fp-recovery-record-exemption.sh --pr <n> --reviewer-hash <h> --reason <t> [--ledger <p>] [--repo <o/r>]
#   fp-recovery-record-exemption.sh --shas "<sha> <sha>..." --reviewer-hash <h> --reason <t> [--ledger <p>]
#
# The CALLER commits the updated ledger onto the (sub-)PR's BASE branch (staged
# for PR1, main for PR2) so the next coverage walk reads it from the tree.
#
# Exit codes: 0 appended (or all already present); 1 usage/resolution error;
#             2 signing failed (no key).

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_DIR/admin-exemption-ledger.sh"

_PR=""; _SHAS=""; _HASH=""; _REASON=""; _REPO="${GH_REPO:-}"
_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
_LEDGER="$_ROOT/.admin-exemption-ledger"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr) _PR="$2"; shift 2 ;;
        --shas) _SHAS="$2"; shift 2 ;;
        --reviewer-hash) _HASH="$2"; shift 2 ;;
        --reason) _REASON="$2"; shift 2 ;;
        --ledger) _LEDGER="$2"; shift 2 ;;
        --repo) _REPO="$2"; shift 2 ;;
        *) echo "fp-recovery-record-exemption: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$_HASH" ]] && { echo "fp-recovery-record-exemption: --reviewer-hash is required (the manual review's REVIEWER_HASH)" >&2; exit 1; }
[[ -z "$_REASON" ]] && { echo "fp-recovery-record-exemption: --reason is required" >&2; exit 1; }

# Resolve the SHA set: explicit --shas, or the PR's introduced commits (base..head).
_resolved=""
if [[ -n "$_SHAS" ]]; then
    _resolved="$_SHAS"
elif [[ -n "$_PR" ]]; then
    command -v gh >/dev/null 2>&1 || { echo "fp-recovery-record-exemption: gh required to resolve --pr" >&2; exit 1; }
    local_repo_arg=(); [[ -n "$_REPO" ]] && local_repo_arg=(--repo "$_REPO")
    # The PR's own commits are exactly the SHAs whose review was bypassed.
    _resolved="$(gh pr view "$_PR" "${local_repo_arg[@]}" --json commits \
        --jq '.commits[].oid' 2>/dev/null)" \
        || { echo "fp-recovery-record-exemption: could not resolve commits for PR #$_PR" >&2; exit 1; }
else
    echo "fp-recovery-record-exemption: one of --pr or --shas is required" >&2; exit 1
fi

[[ -z "${_resolved//[[:space:]]/}" ]] && { echo "fp-recovery-record-exemption: no SHAs to record" >&2; exit 1; }

_count=0
for _sha in $_resolved; do
    [[ -z "$_sha" ]] && continue
    # Idempotent: skip a SHA already validly exempt (re-runs must not duplicate).
    if ael_sha_is_exempt "$_LEDGER" "$_sha"; then
        echo "fp-recovery-record-exemption: $_sha already exempt — skipping" >&2
        continue
    fi
    if ! ael_append "$_LEDGER" "$_sha" "fp-recovery" "${_HASH}: ${_REASON}"; then
        echo "fp-recovery-record-exemption: ael_append failed for $_sha (no signing key?)" >&2
        exit 2
    fi
    _count=$(( _count + 1 ))
    echo "fp-recovery-record-exemption: recorded exemption for $_sha" >&2
done

echo "fp-recovery-record-exemption: appended ${_count} exemption(s) to ${_LEDGER##*/}. COMMIT the ledger onto the PR's base branch (staged for PR1 / main for PR2) so the next coverage walk reads it." >&2
exit 0
