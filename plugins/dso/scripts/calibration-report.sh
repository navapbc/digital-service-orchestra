#!/usr/bin/env bash
# calibration-report.sh — Calibration program reporting tool.
# Location: ${CLAUDE_PLUGIN_ROOT}/scripts/calibration-report.sh
#
# Subcommands:
#   monthly  Aggregate bug tickets by detected_by:<channel> tag for a calendar month.
#
# Usage:
#   calibration-report.sh monthly [--period YYYY-MM] [--fixture <dir>] [--dry-run]
#
# Options:
#   --period YYYY-MM    Target month (UTC). Defaults to current UTC month.
#   --fixture <dir>     Read pre-canned JSON from <dir>/bugs.json instead of
#                       calling the DSO ticket CLI (for testing).
#   --dry-run           Print rollup to stdout; skip posting CLI comment.
#
# Environment:
#   DSO   Path to the dso CLI wrapper. Defaults to $(dirname "$0")/dso.

set -euo pipefail

# ── Shared constant ─────────────────────────────────────────────────────────
readonly CALIBRATION_TZ='UTC'

# ── DSO CLI override pattern ────────────────────────────────────────────────
DSO="${DSO:-$(dirname "$0")/dso}"

# ── Usage ───────────────────────────────────────────────────────────────────
_usage() {
    cat >&2 <<'USAGE'
Usage: calibration-report.sh <subcommand> [options]

Subcommands:
  monthly   Aggregate bug tickets by detected_by:<channel> for a calendar month.

Options for monthly:
  --period YYYY-MM    Target month in UTC (default: current UTC month).
  --fixture <dir>     Use pre-canned JSON from <dir>/bugs.json (for testing).
  --dry-run           Print rollup to stdout; skip posting CLI comment.
USAGE
}

# ── Helper: resolve current UTC month as YYYY-MM ────────────────────────────
_current_utc_month() {
    TZ="${CALIBRATION_TZ}" date '+%Y-%m'
}

# ── Helper: validate YYYY-MM format ─────────────────────────────────────────
_validate_period() {
    local period="$1"
    if [[ ! "$period" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
        echo "calibration-report: invalid period '${period}' — expected YYYY-MM" >&2
        exit 1
    fi
}

# ── Helper: load bugs from fixture dir ─────────────────────────────────────
# Reads <dir>/bugs.json and emits to stdout as a JSON array.
_load_fixture() {
    local fixture_dir="$1"
    local fixture_file="${fixture_dir}/bugs.json"
    if [ ! -d "$fixture_dir" ]; then
        echo "calibration-report: fixture directory not found: ${fixture_dir}" >&2
        exit 1
    fi
    if [ ! -f "$fixture_file" ]; then
        echo "calibration-report: fixture file not found: ${fixture_file}" >&2
        exit 1
    fi
    cat "$fixture_file"
}

# ── Helper: load bugs from DSO ticket CLI ───────────────────────────────────
# Lists all bug tickets and emits a JSON array to stdout.
_load_from_cli() {
    "$DSO" ticket list --type=bug --format=llm 2>/dev/null \
        | python3 -c '
import sys, json
lines = sys.stdin.read().strip().splitlines()
bugs = []
for line in lines:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        # Expand to full shape via ticket show if needed; for now use list shape.
        bugs.append(obj)
    except json.JSONDecodeError:
        pass
print(json.dumps(bugs))
'
}

# ── Helper: aggregate channels from a JSON bugs array ───────────────────────
# Takes the JSON array as $1, outputs channel→count map as JSON object.
_aggregate_channels() {
    local bugs_json="$1"
    python3 -c "
import json, sys

raw = sys.argv[1].strip()
if not raw:
    print('{}')
    sys.exit(0)

bugs = json.loads(raw)
counts = {}
for bug in bugs:
    tags = bug.get('tags', [])
    for tag in tags:
        if tag.startswith('detected_by:'):
            channel = tag[len('detected_by:'):]
            counts[channel] = counts.get(channel, 0) + 1
            break  # at most one detected_by tag per ticket

print(json.dumps(counts))
" "$bugs_json"
}

# ── Helper: render rollup body ───────────────────────────────────────────────
# Writes the comment body to stdout.
_render_rollup() {
    local period="$1"
    local channels_json="$2"

    python3 - "$period" "$channels_json" <<'PY'
import json, sys

period = sys.argv[1]
counts = json.loads(sys.argv[2])

lines = []
lines.append(f"<!-- calibration-rollup: period={period} kind=monthly -->")
lines.append(f"## Calibration Monthly Rollup — {period}")
lines.append("")
lines.append("| Channel | Bug Count |")
lines.append("|---------|-----------|")

total = 0
for channel in sorted(counts.keys()):
    count = counts[channel]
    total += count
    lines.append(f"| {channel} | {count} |")

lines.append("")
lines.append(f"**Total bugs detected:** {total}")
lines.append("")
lines.append(f"_Period: {period} (UTC)_")

print("\n".join(lines))
PY
}

# ═══════════════════════════════════════════════════════════════════════════════
# Subcommand: monthly
# ═══════════════════════════════════════════════════════════════════════════════
_cmd_monthly() {
    local period="" fixture_dir="" dry_run=0

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --period)
                [[ $# -ge 2 ]] || { echo "calibration-report: --period requires an argument" >&2; exit 1; }
                period="$2"
                shift 2
                ;;
            --fixture)
                [[ $# -ge 2 ]] || { echo "calibration-report: --fixture requires an argument" >&2; exit 1; }
                fixture_dir="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "calibration-report monthly: unknown option: $1" >&2
                _usage
                exit 1
                ;;
        esac
    done

    # Resolve period
    if [ -z "$period" ]; then
        period=$(_current_utc_month)
    fi
    _validate_period "$period"

    # Load bug data
    local bugs_json
    if [ -n "$fixture_dir" ]; then
        bugs_json=$(_load_fixture "$fixture_dir")
    else
        bugs_json=$(_load_from_cli)
    fi

    # Aggregate by channel
    local channels_json
    channels_json=$(_aggregate_channels "$bugs_json")

    # Render rollup body
    local rollup_body
    rollup_body=$(_render_rollup "$period" "$channels_json")

    if [ "$dry_run" -eq 1 ]; then
        echo "$rollup_body"
        return 0
    fi

    # Post rollup as comment on calibration-program-health ticket
    # Find calibration-program-health ticket by tag
    local health_ticket_id
    health_ticket_id=$(
        "$DSO" ticket list --type=epic --format=llm 2>/dev/null \
            | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        t = json.loads(line)
        tags = t.get("tags", [])
        if "calibration-program-health" in tags:
            print(t.get("id") or t.get("ticket_id", ""))
            break
    except Exception:
        pass
' || true
    )

    if [ -z "$health_ticket_id" ]; then
        echo "calibration-report: WARNING: calibration-program-health ticket not found; rollup not posted." >&2
        echo "$rollup_body"
        return 0
    fi

    "$DSO" ticket comment "$health_ticket_id" "$rollup_body"
    echo "calibration-report: rollup comment posted to ticket ${health_ticket_id} for period ${period}" >&2
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main dispatcher
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    if [[ $# -eq 0 ]]; then
        _usage
        exit 1
    fi

    local subcommand="$1"
    shift

    case "$subcommand" in
        monthly)
            _cmd_monthly "$@"
            ;;
        *)
            echo "calibration-report: unknown subcommand: ${subcommand}" >&2
            _usage
            exit 1
            ;;
    esac
}

main "$@"
