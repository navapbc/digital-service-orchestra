#!/usr/bin/env bash
# review-convergence-check.sh — W2b/W2c: covered-credit + convergence/cycle cap.
#
# W2c (convergence): a finding flagged → cleared → flagged again across review
# cycles is an oscillation (non-deterministic LLM verdict / a fix that the
# reviewer keeps re-flagging). Detect it from a durable per-cycle history of
# finding identities (lib/review-finding-identity.sh, no pr_number) and STALL +
# escalate rather than looping forever.
#
# W2b (covered credit): the same history lets a re-run after a staged-head
# advance recognise finding-ids already seen-and-cleared, so only genuinely-new
# findings are treated as new (the history is the credit ledger).
#
# Cycle cap: independent of oscillation, if the current cycle exceeds the
# configured max, escalate (matches review.max_cycles discipline).
#
# Inputs (env):
#   DSO_CI_REVIEW_FINDINGS_PATH  current cycle's findings.json (required)
#   DSO_CONVERGENCE_HISTORY      durable history file (appended; required to
#                                detect across cycles — a cache/artifact path)
#   DSO_REVIEW_CYCLE             current cycle number (default 1)
#   DSO_REVIEW_MAX_CYCLES        cycle cap (default 4)
#
# Exit codes:
#   0  converging (record updated; no oscillation; under cap)
#   1  STALL — oscillation detected OR cycle cap exceeded (escalate)
#   78 precondition not met

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_DIR/../.." 2>/dev/null && pwd)}"
# shellcheck source=../lib/review-finding-identity.sh
source "${DSO_FINDING_IDENTITY_LIB:-${_PLUGIN_ROOT}/scripts/lib/review-finding-identity.sh}"

command -v python3 >/dev/null 2>&1 || { echo "PRECONDITION_NOT_MET: python3" >&2; exit 78; }

FINDINGS="${DSO_CI_REVIEW_FINDINGS_PATH:-}"
HISTORY="${DSO_CONVERGENCE_HISTORY:-}"
CYCLE="${DSO_REVIEW_CYCLE:-1}"
CAP="${DSO_REVIEW_MAX_CYCLES:-4}"

[[ -n "$FINDINGS" ]] || { echo "PRECONDITION_NOT_MET: DSO_CI_REVIEW_FINDINGS_PATH unset" >&2; exit 78; }
[[ -n "$HISTORY" ]] || { echo "PRECONDITION_NOT_MET: DSO_CONVERGENCE_HISTORY unset" >&2; exit 78; }

# Current cycle's finding ids (deduped).
_CUR_IDS="$(compute_finding_ids "$FINDINGS" | LC_ALL=C sort -u)"

# History format: "<cycle>\t<id-or-__CYCLE_RAN__>". The sentinel records that a
# cycle ran even if it produced zero findings, so "cleared in cycle N" is
# distinguishable from "cycle N never ran".
mkdir -p "$(dirname "$HISTORY")" 2>/dev/null || true
touch "$HISTORY"

# ── Oscillation detection (uses PRIOR history only) ─────────────────────────
_OSC="$(CUR_IDS="$_CUR_IDS" CYCLE="$CYCLE" python3 -c "
import os, sys
cur = set(x for x in os.environ.get('CUR_IDS','').splitlines() if x)
cycle = int(os.environ.get('CYCLE','1'))
present = {}      # id -> set(cycles present, from prior history)
ran = set()       # cycles that ran (prior)
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.rstrip('\n')
    if not line or '\t' not in line:
        continue
    c_s, tok = line.split('\t', 1)
    try:
        c = int(c_s)
    except ValueError:
        continue
    if c >= cycle:        # only PRIOR cycles inform this run
        continue
    ran.add(c)
    if tok != '__CYCLE_RAN__':
        present.setdefault(tok, set()).add(c)
ran.add(cycle)
osc = []
for fid in cur:
    cyc = present.get(fid, set())
    if not cyc:
        continue          # genuinely new (or new-since-last) -> not oscillation
    lo = min(cyc)
    # cleared in some run strictly between its first appearance and now?
    if any(lo < c < cycle and c not in cyc for c in ran):
        osc.append(fid)
for fid in sorted(osc):
    print(fid)
" "$HISTORY")"

# ── Append THIS cycle to history (credit ledger for W2b) ────────────────────
{
    printf '%s\t__CYCLE_RAN__\n' "$CYCLE"
    while IFS= read -r _id; do [[ -n "$_id" ]] && printf '%s\t%s\n' "$CYCLE" "$_id"; done <<< "$_CUR_IDS"
} >> "$HISTORY"

_cur_n="$(printf '%s' "$_CUR_IDS" | grep -c . || true)"
echo "review-convergence-check: cycle=${CYCLE} cap=${CAP} findings=${_cur_n}"

_stall=0
if [[ -n "$_OSC" ]]; then
    echo "STALL: oscillation — finding(s) flagged → cleared → re-flagged across cycles:" >&2
    while IFS= read -r _oid; do [[ -n "$_oid" ]] && echo "  finding_id=${_oid}" >&2; done <<< "$_OSC"
    echo "AUDIT: decision_record=stall reason=oscillation cycle=${CYCLE} count=$(printf '%s' "$_OSC" | grep -c .)"
    _stall=1
fi
if (( CYCLE > CAP )); then
    echo "STALL: cycle ${CYCLE} exceeds cap ${CAP} — escalate (review.max_cycles)" >&2
    echo "AUDIT: decision_record=stall reason=cycle_cap_exceeded cycle=${CYCLE} cap=${CAP}"
    _stall=1
fi

if (( _stall )); then exit 1; fi
echo "AUDIT: decision_record=converging cycle=${CYCLE} findings=${_cur_n}"
exit 0
