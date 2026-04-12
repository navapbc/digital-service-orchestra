#!/usr/bin/env bash
# emit-review-result.sh
# Assembles review_result event data from artifact files and CLI args,
# then calls emit-review-event.sh.
#
# CLI args (orchestrator in-memory state):
#   --tier-original=<light|standard|deep>
#   --tier-final=<light|standard|deep>
#   --pass-fail=<passed|failed>
#   --overlay-security=<true|false>      (default: false)
#   --overlay-performance=<true|false>    (default: false)
#   --resolution-code-changes=<int>      (default: 0)
#   --resolution-defenses=<int>          (default: 0)
#   --revision-cycles=<int>              (default: 0)
#
# File-sourced data:
#   1. reviewer-findings.json from $(get_artifacts_dir):
#      - dimension_scores from scores{}
#      - finding_counts_by_severity and finding_counts_by_dimension from findings[]
#   2. test-gate-status from $(get_artifacts_dir):
#      - line 1 (passed/failed/timeout), defaults "unknown" if missing
#
# Best-effort: if emit-review-event.sh fails, log warning to stderr but return 0.
# Outputs the assembled JSON to stdout for testability.

set -uo pipefail

# ── Resolve paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${SCRIPT_DIR%/scripts}"

# Source deps.sh for get_artifacts_dir
source "$PLUGIN_ROOT/hooks/lib/deps.sh"

# ── Parse CLI args ────────────────────────────────────────────────────────
tier_original=""
tier_final=""
pass_fail=""
overlay_security="false"
overlay_performance="false"
resolution_code_changes=0
resolution_defenses=0
revision_cycles=0

for arg in "$@"; do
    case "$arg" in
        --tier-original=*) tier_original="${arg#*=}" ;;
        --tier-final=*) tier_final="${arg#*=}" ;;
        --pass-fail=*) pass_fail="${arg#*=}" ;;
        --overlay-security=*) overlay_security="${arg#*=}" ;;
        --overlay-performance=*) overlay_performance="${arg#*=}" ;;
        --resolution-code-changes=*) resolution_code_changes="${arg#*=}" ;;
        --resolution-defenses=*) resolution_defenses="${arg#*=}" ;;
        --revision-cycles=*) revision_cycles="${arg#*=}" ;;
        *)
            echo "Warning: unknown argument '$arg'" >&2
            ;;
    esac
done

# ── Resolve artifacts dir ────────────────────────────────────────────────
ARTIFACTS_DIR=$(get_artifacts_dir)

# ── Read reviewer-findings.json (required) ───────────────────────────────
findings_file="$ARTIFACTS_DIR/reviewer-findings.json"
if [[ ! -f "$findings_file" ]]; then
    echo "Error: reviewer-findings.json not found at $findings_file" >&2
    exit 1
fi

# ── Read test-gate-status (optional, default "unknown") ──────────────────
test_gate_status="unknown"
gate_status_file="$ARTIFACTS_DIR/test-gate-status"
if [[ -f "$gate_status_file" ]]; then
    test_gate_status=$(head -1 "$gate_status_file" 2>/dev/null || echo "unknown")
    [[ -z "$test_gate_status" ]] && test_gate_status="unknown"
fi

# ── Assemble JSON payload ────────────────────────────────────────────────
json_payload=$(python3 -c "
import json, sys

findings_path = sys.argv[1]
pass_fail = sys.argv[2]
tier_original = sys.argv[3]
tier_final = sys.argv[4]
overlay_security = sys.argv[5].lower() == 'true'
overlay_performance = sys.argv[6].lower() == 'true'
resolution_code_changes = int(sys.argv[7])
resolution_defenses = int(sys.argv[8])
revision_cycles = int(sys.argv[9])
test_gate_status = sys.argv[10]

with open(findings_path) as f:
    findings_data = json.load(f)

# Extract dimension scores
dimension_scores = findings_data.get('scores', {})

# Compute finding counts
findings = findings_data.get('findings', [])
finding_count = len(findings)

# Count by severity
severity_counts = {}
for finding in findings:
    sev = finding.get('severity', 'unknown')
    severity_counts[sev] = severity_counts.get(sev, 0) + 1

critical_count = severity_counts.get('critical', 0)
important_count = severity_counts.get('important', 0)
suggestion_count = severity_counts.get('suggestion', 0)
minor_count = severity_counts.get('minor', 0)

# Count by dimension/category
dimension_counts = {}
for finding in findings:
    dim = finding.get('category', 'unknown')
    dimension_counts[dim] = dimension_counts.get(dim, 0) + 1

# Build payload
payload = {
    'event_type': 'review_result',
    'pass_fail': pass_fail,
    'tier_original': tier_original,
    'tier_final': tier_final,
    'overlay_security_triggered': overlay_security,
    'overlay_performance_triggered': overlay_performance,
    'resolution_code_changes': resolution_code_changes,
    'resolution_defenses': resolution_defenses,
    'revision_cycles': revision_cycles,
    'test_gate_status': test_gate_status,
    'finding_count': finding_count,
    'critical_count': critical_count,
    'important_count': important_count,
    'suggestion_count': suggestion_count,
    'minor_count': minor_count,
    'dimension_scores': dimension_scores,
    'finding_counts_by_severity': severity_counts,
    'finding_counts_by_dimension': dimension_counts,
}

print(json.dumps(payload, separators=(',', ':')))
" "$findings_file" "$pass_fail" "$tier_original" "$tier_final" \
  "$overlay_security" "$overlay_performance" \
  "$resolution_code_changes" "$resolution_defenses" \
  "$revision_cycles" "$test_gate_status") || {
    echo "Error: failed to assemble JSON payload" >&2
    exit 1
}

# Output JSON to stdout (for testability and caller consumption)
echo "$json_payload"

# ── Call emit-review-event.sh (best-effort) ──────────────────────────────
"$SCRIPT_DIR/emit-review-event.sh" "$json_payload" 2>/dev/null || {
    echo "Warning: emit-review-event.sh failed (best-effort, continuing)" >&2
}

exit 0
