#!/usr/bin/env bash
# emit-protocol-review-result.sh
# Assembles plan/fidelity review event data and calls emit-review-event.sh.
#
# CLI args:
#   --review-type=<implementation-plan|brainstorm-fidelity|architectural>
#   --pass-fail=<passed|failed>
#   --revision-cycles=<integer>
#
# File-sourced: review-protocol-output.json from $(get_artifacts_dir) or
#   $WORKFLOW_PLUGIN_ARTIFACTS_DIR — extracts dimension_scores, computes
#   finding_counts_by_severity from findings[].
#
# Output: JSON event payload to stdout.
# Invocation: emit-review-event.sh review_result '<json>' (best-effort via PATH).
# Best-effort: returns 0 even if emit fails; logs warning to stderr.

set -uo pipefail

# ── Parse CLI arguments ────────────────────────────────────────────────────
review_type=""
pass_fail=""
revision_cycles=""

for arg in "$@"; do
    case "$arg" in
        --review-type=*)  review_type="${arg#--review-type=}" ;;
        --pass-fail=*)    pass_fail="${arg#--pass-fail=}" ;;
        --revision-cycles=*) revision_cycles="${arg#--revision-cycles=}" ;;
        *)
            echo "Error: unknown argument '$arg'" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$review_type" || -z "$pass_fail" || -z "$revision_cycles" ]]; then
    echo "Error: --review-type, --pass-fail, and --revision-cycles are required" >&2
    exit 1
fi

# ── Resolve artifacts directory ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

artifacts_dir="${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}"
if [[ -z "$artifacts_dir" ]]; then
    if [[ -f "$PLUGIN_ROOT/hooks/lib/deps.sh" ]]; then
        source "$PLUGIN_ROOT/hooks/lib/deps.sh"
        artifacts_dir=$(get_artifacts_dir)
    else
        echo "Error: cannot resolve artifacts directory" >&2
        exit 1
    fi
fi

# ── Read review-protocol-output.json ──────────────────────────────────────
protocol_file="$artifacts_dir/review-protocol-output.json"
if [[ ! -f "$protocol_file" ]]; then
    # Best-effort: no review protocol file yet â silently succeed (no-op).
    exit 0
fi

# ── Assemble JSON payload ─────────────────────────────────────────────────
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

json_payload=$(python3 -c "
import json, sys
from collections import Counter

protocol_file = sys.argv[1]
review_type = sys.argv[2]
pass_fail = sys.argv[3]
revision_cycles = int(sys.argv[4])
timestamp = sys.argv[5]

with open(protocol_file) as f:
    protocol = json.load(f)

# Extract overall_score
overall_score = protocol.get('overall_score', 0)

# Compute finding_counts_by_severity from findings[]
findings = protocol.get('findings', [])
severity_counts = Counter(f.get('severity', 'unknown') for f in findings)

payload = {
    'event_type': 'review_result',
    'review_type': review_type,
    'pass_fail': pass_fail,
    'revision_cycles': revision_cycles,
    'overall_score': overall_score,
    'finding_counts_by_severity': dict(severity_counts),
    'timestamp': timestamp,
}

print(json.dumps(payload, separators=(',', ':')))
" "$protocol_file" "$review_type" "$pass_fail" "$revision_cycles" "$timestamp") || {
    echo "Error: failed to assemble JSON payload" >&2
    exit 1
}

# ── Output JSON to stdout ─────────────────────────────────────────────────
echo "$json_payload"

# ── Best-effort emit via emit-review-event.sh on PATH ─────────────────────
if command -v emit-review-event.sh >/dev/null 2>&1; then
    emit-review-event.sh review_result "$json_payload" >/dev/null 2>/dev/null || {
        echo "Warning: emit-review-event.sh failed, review event not recorded" >&2
    }
fi

exit 0
