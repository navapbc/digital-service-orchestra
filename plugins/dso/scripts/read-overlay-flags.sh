#!/usr/bin/env bash
# scripts/read-overlay-flags.sh
#
# Single source-of-truth for reading classifier overlay flags. Both
# REVIEW-WORKFLOW.md Step 4 (orchestrator dispatch) and hooks/record-review.sh
# (post-commit gate) call this script so they cannot disagree on which overlays
# are flagged for the current diff.
#
# Modes:
#   classifier  — stdin is a single JSON object (the classifier's stdout).
#                 No filtering. Used by REVIEW-WORKFLOW.md Step 4 to decide
#                 which overlay agents to add to the parallel dispatch.
#   telemetry   — stdin is JSONL (classifier-telemetry.jsonl). Filter records
#                 by --diff-hash and read the LAST matching record. Used by
#                 record-review.sh to enforce that every flagged overlay has a
#                 corresponding reviewer-findings-<dim>.json file recorded.
#
# Output: one dimension name per line for any overlay flagged true. Filename
# convention is `_overlay` suffix stripped, `_` replaced with `-`:
#   test_quality_overlay -> test-quality
#   security_overlay     -> security
#   performance_overlay  -> performance
#
# Usage:
#   echo "$CLASSIFIER_OUTPUT" | read-overlay-flags.sh --mode classifier
#   read-overlay-flags.sh --mode telemetry --diff-hash <hash> < telemetry.jsonl
#
# Exit codes:
#   0 — success (output may be empty if no flags are true)
#   1 — usage error (missing mode, missing --diff-hash in telemetry mode)
#   0 with empty output — also returned when input is malformed (fail-open
#       per the existing `2>/dev/null || true` contract upstream); the caller
#       receives an empty list and decides whether to fail-closed.

set -euo pipefail

_MODE=""
_DIFF_HASH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)       _MODE="${2:?--mode requires classifier|telemetry}"; shift 2 ;;
        --diff-hash)  _DIFF_HASH="${2:?--diff-hash requires a hash value}"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$_MODE" ]]; then
    echo "ERROR: --mode is required (classifier or telemetry)" >&2
    exit 1
fi
if [[ "$_MODE" != "classifier" && "$_MODE" != "telemetry" ]]; then
    echo "ERROR: --mode must be 'classifier' or 'telemetry' (got '$_MODE')" >&2
    exit 1
fi
if [[ "$_MODE" == "telemetry" && -z "$_DIFF_HASH" ]]; then
    echo "ERROR: --diff-hash is required in telemetry mode" >&2
    exit 1
fi

# Overlay schema: extend this list when adding new overlays. Both modes share it.
# Output filenames: strip _overlay suffix, replace _ with -.
python3 -c "
import json, sys

OVERLAY_KEYS = ('test_quality_overlay', 'security_overlay', 'performance_overlay')

def emit(obj):
    if not isinstance(obj, dict):
        return
    for k in OVERLAY_KEYS:
        if obj.get(k) is True:
            dim = k[:-len('_overlay')].replace('_', '-')
            print(dim)

mode = sys.argv[1]
diff_hash = sys.argv[2] if len(sys.argv) > 2 else ''

if mode == 'classifier':
    try:
        obj = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    emit(obj)
else:
    matched = None
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get('diff_hash') == diff_hash:
            matched = obj
    if matched is not None:
        emit(matched)
" "$_MODE" "$_DIFF_HASH"
