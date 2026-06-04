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

_PR=""; _SHAS=""; _HASH=""; _REASON=""; _REPO="${GH_REPO:-}"; _FINDINGS=""
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
        --findings) _FINDINGS="$2"; shift 2 ;;
        *) echo "fp-recovery-record-exemption: unknown arg: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$_HASH" ]] && { echo "fp-recovery-record-exemption: --reviewer-hash is required (the manual review's REVIEWER_HASH)" >&2; exit 1; }
[[ -z "$_REASON" ]] && { echo "fp-recovery-record-exemption: --reason is required" >&2; exit 1; }

# C1 — CODE-ENFORCE THE OPUS-GATE (3ebb DD4 unit 5 / panel showstopper). An
# exemption may be recorded ONLY when backed by a REAL CLEARED review. Verify
# --reviewer-hash against the reviewer-findings.json the FP-recovery opus review
# produced (shasum integrity — the SAME mechanism as record-review.sh:274) AND
# require ZERO blocking findings (critical/important/fragile). This refuses a
# forged --reviewer-hash from minting a "reviewed-equivalent" exemption. RESIDUAL
# (panel C3): a wholly-fabricated findings file is closed by the .closure-key
# boundary, NOT by this check — provenance must not honor the ledger in CI until
# C3 is an enforced control.
_FINDINGS="${_FINDINGS:-${WORKFLOW_PLUGIN_ARTIFACTS_DIR:+${WORKFLOW_PLUGIN_ARTIFACTS_DIR}/reviewer-findings.json}}"
if [[ -z "$_FINDINGS" || ! -f "$_FINDINGS" ]]; then
    echo "fp-recovery-record-exemption: --findings <reviewer-findings.json> (the opus review's output) is required — refusing to record an unverified exemption" >&2
    exit 2
fi
_actual_hash="$(shasum -a 256 "$_FINDINGS" 2>/dev/null | awk '{print $1}')"
if [[ -z "$_actual_hash" || "$_actual_hash" != "$_HASH" ]]; then
    echo "fp-recovery-record-exemption: --reviewer-hash does not match ${_FINDINGS} (got ${_actual_hash:0:12}..., expected ${_HASH:0:12}...) — fabricated/tampered review; refusing" >&2
    exit 2
fi
if ! python3 - "$_FINDINGS" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as fh:          # context manager — no leaked fd
        d = json.load(fh)
except Exception as e:
    print(f"findings file is not valid JSON: {e}", file=sys.stderr); sys.exit(1)
# A valid reviewer-findings.json MUST carry a 'findings' array (or be a bare
# list). A file lacking it is NOT a review and must FAIL the gate — NOT default
# to empty (else {"summary": "..."} would pass with "0 blocking findings",
# bypassing the opus-gate schema enforcement).
if isinstance(d, list):
    findings = d
elif isinstance(d, dict) and isinstance(d.get("findings"), list):
    findings = d["findings"]
else:
    print("findings file lacks a 'findings' array — not a valid review", file=sys.stderr); sys.exit(1)
blocking = {"critical", "important", "fragile"}
if any(isinstance(f, dict) and f.get("severity") in blocking for f in findings):
    print("review has blocking (critical/important/fragile) findings — not cleared", file=sys.stderr); sys.exit(1)
sys.exit(0)
PY
then
    echo "fp-recovery-record-exemption: review at ${_FINDINGS} not cleared / not a valid review (see reason above) — refusing to record an exemption" >&2
    exit 2
fi

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

# Key precondition (fail LOUD and EARLY): the HMAC signing key must exist before
# we append anything, so a missing/unreadable key is reported as a distinct
# PROVISIONING error (exit 2) rather than surfacing as N identical per-SHA
# ael_append failures. A deleted/corrupt key cannot silently no-op exemptions.
_keyf="$(ael_key_file 2>/dev/null || true)"
if [[ -z "$_keyf" || ! -f "$_keyf" || ! -r "$_keyf" ]]; then
    echo "fp-recovery-record-exemption: HMAC signing key not provisioned/readable (${_keyf:-unresolved}) — cannot sign exemptions. Provision the closure-key to this environment (gap G-A) before recording." >&2
    exit 2
fi

_count=0
for _sha in $_resolved; do
    [[ -z "$_sha" ]] && continue
    # Input validation (defense-in-depth): only a well-formed git object name may
    # be recorded. Even though entries are HMAC-signed and the caller is the admin
    # running FP-recovery, refusing a malformed SHA prevents a typo or a crafted
    # --shas value from writing a junk exemption that could never match a real
    # commit (or, worse, embedding control chars into the ledger row).
    if ! [[ "$_sha" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        echo "fp-recovery-record-exemption: refusing malformed SHA '$_sha' (expected 7-40 hex chars)" >&2
        exit 1
    fi
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
