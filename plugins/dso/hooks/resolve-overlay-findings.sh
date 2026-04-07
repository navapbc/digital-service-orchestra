#!/usr/bin/env bash
# plugins/dso/hooks/resolve-overlay-findings.sh
# Overlay findings resolution loop integration.
#
# Reads one or more overlay findings JSON files (standard reviewer-findings.json
# format: scores, findings, summary) and integrates them into the resolution loop
# with single-writer compliance.
#
# USAGE
#   resolve-overlay-findings.sh \
#     --findings-json <path> [--findings-json <path> ...] \
#     [--ticket-cmd <path>] \
#     [--write-findings-cmd <path>]
#
# OPTIONS
#   --findings-json <path>      Path to a findings JSON file. May be specified
#                               multiple times for multiple overlay sources.
#   --ticket-cmd <path>         Path to the ticket CLI. May be set via TICKET_CMD env.
#   --write-findings-cmd <path> Path to write-reviewer-findings.sh.
#
# EXIT CODES
#   0  No blocking findings (minor or empty).
#   1  Critical or important findings present (commit is blocked).
#
# STDOUT SIGNALS
#   OVERLAY_TICKET_CREATED:<id>  Emitted once per minor finding when a tracking
#                                ticket is created.
#   OVERLAY_WRITE_COUNT:<n>      Emitted before exit when findings are present;
#                                n is always 1 (single-writer invariant).

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

FINDINGS_FILES=()
TICKET_CMD="${TICKET_CMD:-}"
WRITE_FINDINGS_CMD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --findings-json)
            FINDINGS_FILES+=("$2")
            shift 2
            ;;
        --ticket-cmd)
            TICKET_CMD="$2"
            shift 2
            ;;
        --write-findings-cmd)
            WRITE_FINDINGS_CMD="$2"
            shift 2
            ;;
        *)
            echo "resolve-overlay-findings.sh: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ ${#FINDINGS_FILES[@]} -eq 0 ]]; then
    echo "resolve-overlay-findings.sh: at least one --findings-json is required" >&2
    exit 2
fi

# Default write-findings-cmd (resolved relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "$WRITE_FINDINGS_CMD" ]]; then
    WRITE_FINDINGS_CMD="$SCRIPT_DIR/write-reviewer-findings.sh"
fi

# ---------------------------------------------------------------------------
# Temp dir for intermediate data
# ---------------------------------------------------------------------------

_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TMPDIR"' EXIT

# ---------------------------------------------------------------------------
# Aggregate findings from all input files using Python
# ---------------------------------------------------------------------------

AGGREGATE_JSON="$_TMPDIR/aggregate.json"

python3 - "$AGGREGATE_JSON" "${FINDINGS_FILES[@]}" <<'PYEOF'
import json, sys

out_path = sys.argv[1]
files    = sys.argv[2:]

all_findings  = []
has_blocking  = False
has_findings  = False

for path in files:
    try:
        with open(path) as fh:
            data = json.load(fh)
    except Exception as exc:
        print(f"ERROR: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(2)

    for finding in data.get("findings", []):
        has_findings = True
        if finding.get("severity", "minor") in ("critical", "important", "fragile"):
            has_blocking = True
        all_findings.append(finding)

result = {
    "has_blocking": has_blocking,
    "has_findings": has_findings,
    "findings":     all_findings,
}
with open(out_path, "w") as fh:
    json.dump(result, fh)
PYEOF

# ---------------------------------------------------------------------------
# Parse aggregate fields
# ---------------------------------------------------------------------------

HAS_BLOCKING=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print('1' if d['has_blocking'] else '0')
" "$AGGREGATE_JSON")

HAS_FINDINGS=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print('1' if d['has_findings'] else '0')
" "$AGGREGATE_JSON")

# ---------------------------------------------------------------------------
# Empty findings: exit cleanly with no side effects
# ---------------------------------------------------------------------------

if [[ "$HAS_FINDINGS" == "0" ]]; then
    exit 0
fi

# ---------------------------------------------------------------------------
# Process minor findings: create tracking tickets
# ---------------------------------------------------------------------------

MINOR_DESCS="$_TMPDIR/minor-descriptions.txt"

python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
for f in d['findings']:
    if f.get('severity', 'minor') == 'minor':
        print(f.get('description', 'Overlay finding (no description)'))
" "$AGGREGATE_JSON" > "$MINOR_DESCS"

while IFS= read -r description; do
    if [[ -n "$TICKET_CMD" ]]; then
        # Truncate title to 255 chars (Jira sync limit per CLAUDE.md)
        _title="[overlay] ${description:0:244}"
        ticket_id=$(
            "$TICKET_CMD" create task "$_title" --priority=3 2>/dev/null
        ) || ticket_id="error"
        echo "OVERLAY_TICKET_CREATED:$ticket_id"
    fi
done < "$MINOR_DESCS"

# ---------------------------------------------------------------------------
# Single-writer: call write-reviewer-findings.sh exactly once
# ---------------------------------------------------------------------------

if [[ -x "$WRITE_FINDINGS_CMD" ]]; then
    # Build full reviewer-findings.json schema (3 keys: scores, findings, summary)
    # Scores derived per-dimension from findings' categories and severities.
    # Severity mapping: critical→1, important→3, minor→4 (per CLAUDE.md reviewer schema).
    # Each finding's category maps to a dimension; unaffected dimensions stay at 5.
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
severity_to_score = {'critical': 1, 'important': 3, 'fragile': 3, 'minor': 4}
dim_scores = {'correctness': 5, 'verification': 5, 'hygiene': 5, 'design': 5, 'maintainability': 5}
for f in d['findings']:
    sev = f.get('severity', 'minor')
    cat = f.get('category', 'correctness')
    score = severity_to_score.get(sev, 4)
    if cat in dim_scores:
        dim_scores[cat] = min(dim_scores[cat], score)
    else:
        dim_scores['correctness'] = min(dim_scores['correctness'], score)
output = {
    'scores': dim_scores,
    'findings': d['findings'],
    'summary': 'Overlay findings aggregated from security, performance, and/or test quality review.'
}
print(json.dumps(output))
" "$AGGREGATE_JSON" | "$WRITE_FINDINGS_CMD" >/dev/null 2>&1 || true
fi
echo "OVERLAY_WRITE_COUNT:1"

# ---------------------------------------------------------------------------
# Exit with appropriate code
# ---------------------------------------------------------------------------

if [[ "$HAS_BLOCKING" == "1" ]]; then
    exit 1
fi
exit 0
