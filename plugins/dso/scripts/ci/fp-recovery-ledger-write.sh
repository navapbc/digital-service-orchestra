#!/usr/bin/env bash
# fp-recovery-ledger-write.sh
#
# Append one structured record to the FP-recovery ledger when an fp-recovery
# clearance overrides a blocking LLM-review finding judged a false positive.
#
# WHY (epic 7412 / task 7eff): the 2026-06-08 FP-analysis of ~48 override PRs had
# to reverse-engineer FP root causes from scattered, sometimes-unrecoverable PR
# comments. There was no durable, queryable record of WHICH finding was overridden,
# its severity/class, or WHY. This writer captures the ORIGINAL blocking finding
# (not the neutral re-review, which is 0-findings by definition at clearance) plus a
# structured root-cause category and the human rationale, so future FP-rate and
# root-cause analysis is a query, not an excavation.
#
# The ledger is append-only JSONL at $DSO_FP_LEDGER_PATH (default:
# $REPO_ROOT/docs/audits/fp-recovery-ledger.jsonl). It is pure reporting — it is NOT
# on the bypass-propagation path (that is ADR-0022 identity-based exemption), so it
# needs no signing key. It lives in the project tree (not the plugin tree) per the
# no-dev-artifacts invariant.
#
# Usage (invoked by FP-RECOVERY-WORKFLOW.md after the verdict clears):
#   fp-recovery-ledger-write.sh \
#     --pr <N> --fp-category <T1..T10|TX> --fp-rationale <text> \
#     --original-summary <text> \
#     [--original-severity <critical|important|fragile|unknown>] \
#     [--original-class <verification|correctness|security|...>] \
#     [--original-location <file:line>] \
#     [--neutral-reviewer-hash <hash>] [--cleared-by <github-login>]
#
# Exit: 0 on append; 2 on usage/validation error (loud — the skill must notice a
# mis-call rather than silently drop the audit record); the caller treats a non-zero
# exit as non-blocking for the merge but surfaces it.

set -uo pipefail

PR=""
FP_CATEGORY=""
FP_RATIONALE=""
ORIG_SEVERITY="unknown"
ORIG_CLASS="unknown"
ORIG_LOCATION=""
ORIG_SUMMARY=""
NEUTRAL_HASH=""
CLEARED_BY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr) PR="${2:-}"; shift 2 ;;
        --fp-category) FP_CATEGORY="${2:-}"; shift 2 ;;
        --fp-rationale) FP_RATIONALE="${2:-}"; shift 2 ;;
        --original-severity) ORIG_SEVERITY="${2:-}"; shift 2 ;;
        --original-class) ORIG_CLASS="${2:-}"; shift 2 ;;
        --original-location) ORIG_LOCATION="${2:-}"; shift 2 ;;
        --original-summary) ORIG_SUMMARY="${2:-}"; shift 2 ;;
        --neutral-reviewer-hash) NEUTRAL_HASH="${2:-}"; shift 2 ;;
        --cleared-by) CLEARED_BY="${2:-}"; shift 2 ;;
        *) echo "fp-recovery-ledger-write: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

# ── Validate required fields (fail loud) ──────────────────────────────────────
_missing=()
[[ -z "$PR" ]] && _missing+=("--pr")
[[ -z "$FP_CATEGORY" ]] && _missing+=("--fp-category")
[[ -z "$FP_RATIONALE" ]] && _missing+=("--fp-rationale")
[[ -z "$ORIG_SUMMARY" ]] && _missing+=("--original-summary")
if [[ ${#_missing[@]} -gt 0 ]]; then
    echo "fp-recovery-ledger-write: missing required argument(s): ${_missing[*]}" >&2
    exit 2
fi

# ── Taxonomy guard — keep fp_category queryable ───────────────────────────────
case "$FP_CATEGORY" in
    T1|T2|T3|T4|T5|T6|T7|T8|T9|T10|TX) : ;;
    *) echo "fp-recovery-ledger-write: invalid --fp-category '$FP_CATEGORY' (expected T1..T10 or TX)" >&2; exit 2 ;;
esac

# ── Resolve ledger path (configurable; default project-local docs/audits) ─────
if [[ -n "${DSO_FP_LEDGER_PATH:-}" ]]; then
    LEDGER="$DSO_FP_LEDGER_PATH"
else
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
    LEDGER="$_repo_root/docs/audits/fp-recovery-ledger.jsonl"
fi
mkdir -p "$(dirname "$LEDGER")" || { echo "fp-recovery-ledger-write: cannot create ledger dir for '$LEDGER'" >&2; exit 2; }

# ── Build the record with python3 (safe JSON encoding of all free text) and
#    append exactly one line. Values pass via env so no text reaches python source. ──
_line="$(
  DSO_LW_PR="$PR" \
  DSO_LW_CATEGORY="$FP_CATEGORY" \
  DSO_LW_RATIONALE="$FP_RATIONALE" \
  DSO_LW_OSEV="$ORIG_SEVERITY" \
  DSO_LW_OCLASS="$ORIG_CLASS" \
  DSO_LW_OLOC="$ORIG_LOCATION" \
  DSO_LW_OSUM="$ORIG_SUMMARY" \
  DSO_LW_NHASH="$NEUTRAL_HASH" \
  DSO_LW_CLEAREDBY="$CLEARED_BY" \
  python3 -c '
import os, json, hashlib, datetime

pr_raw = os.environ["DSO_LW_PR"].strip()
try:
    pr = int(pr_raw)
except ValueError:
    pr = pr_raw  # tolerate non-numeric (e.g. URL fragment); keep as string

loc = os.environ.get("DSO_LW_OLOC", "")
summ = os.environ["DSO_LW_OSUM"]
# Content-stable fingerprint of the original finding: location when present
# (matches review-finding-identity cited-lines scheme), else the summary.
fp_basis = loc if loc else summ
fingerprint = hashlib.sha256(fp_basis.encode("utf-8")).hexdigest()[:16]

rec = {
    "schema": "fp-recovery-ledger/v1",
    "pr": pr,
    "recorded_at": datetime.datetime.now(datetime.timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "verdict": "cleared",
    "fp_category": os.environ["DSO_LW_CATEGORY"],
    "fp_rationale": os.environ["DSO_LW_RATIONALE"],
    "original_finding": {
        "severity": os.environ.get("DSO_LW_OSEV") or "unknown",
        "class": os.environ.get("DSO_LW_OCLASS") or "unknown",
        "location": loc,
        "summary": summ,
        "fingerprint": fingerprint,
    },
    "neutral_reviewer_hash": os.environ.get("DSO_LW_NHASH", ""),
    "cleared_by": os.environ.get("DSO_LW_CLEAREDBY", ""),
}
print(json.dumps(rec, ensure_ascii=False, separators=(",", ":")))
'
)" || { echo "fp-recovery-ledger-write: failed to encode record" >&2; exit 2; }

# O_APPEND single-line write is atomic on local filesystems.
printf '%s\n' "$_line" >> "$LEDGER" || { echo "fp-recovery-ledger-write: append failed to '$LEDGER'" >&2; exit 2; }

echo "LEDGER_WRITE: ok pr=$PR category=$FP_CATEGORY path=$LEDGER"
