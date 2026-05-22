#!/usr/bin/env bash
# calibration-report.sh — Calibration program reporting tool.
# Location: ${CLAUDE_PLUGIN_ROOT}/scripts/calibration-report.sh
#
# Subcommands:
#   monthly         Aggregate bug tickets by detected_by:<channel> tag for a calendar month.
#   quarterly       Aggregate bug tickets by detected_by:<channel> tag for a calendar quarter.
#   mutation-append Append a mutation-testing result comment for a PR (idempotent).
#   churn-append    Append a churn result comment for a PR (idempotent).
#
# Usage:
#   calibration-report.sh monthly [--period YYYY-MM] [--fixture <dir>] [--dry-run]
#   calibration-report.sh quarterly [--period YYYY-Q[1-4]] [--fixture <dir>] [--dry-run]
#   calibration-report.sh mutation-append --pr <pr-id> --findings <count> [--dry-run]
#   calibration-report.sh churn-append --pr <pr-id> --churn <count> [--dry-run]
#
# Options:
#   --period YYYY-MM        Target month (UTC). Defaults to current UTC month.
#   --period YYYY-Q[1-4]    Target quarter (UTC). Defaults to current UTC quarter.
#   --pr <pr-id>            PR identifier for mutation-append / churn-append.
#   --findings <count>      Number of mutation findings (mutation-append only).
#   --churn <count>         Churn count (churn-append only).
#   --fixture <dir>         Read pre-canned JSON from <dir>/bugs.json instead of
#                           calling the DSO ticket CLI (for testing).
#   --dry-run               Print rollup to stdout; skip posting CLI comment.
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
  monthly         Aggregate bug tickets by detected_by:<channel> for a calendar month.
  quarterly       Aggregate bug tickets by detected_by:<channel> for a calendar quarter.
  mutation-append Append a mutation-testing result for a PR (idempotent).
  churn-append    Append a churn result for a PR (idempotent).
  query           Query calibration data (run 'query --help' for sub-handler list).

Options for monthly:
  --period YYYY-MM        Target month in UTC (default: current UTC month).
  --fixture <dir>         Use pre-canned JSON from <dir>/bugs.json (for testing).
  --dry-run               Print rollup to stdout; skip posting CLI comment.

Options for quarterly:
  --period YYYY-Q[1-4]   Target quarter in UTC (default: current UTC quarter).
  --fixture <dir>         Use pre-canned JSON from <dir>/bugs.json (for testing).
  --dry-run               Print rollup to stdout; skip posting CLI comment.

Options for mutation-append / churn-append:
  --pr <pr-id>            PR identifier (required).
  --findings <count>      Number of mutation findings (mutation-append only).
  --churn <count>         Churn count (churn-append only).
  --dry-run               Print comment body to stdout; skip posting CLI comment.
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
# Lists bug tickets for the given period and emits a filtered JSON array.
# Period is YYYY-MM (monthly) or YYYY-Q[1-4] (quarterly).
# Uses default JSON format (not --format=llm) so created_at and tags are present.
_load_from_cli() {
    local period="$1"
    "$DSO" ticket list --type=bug 2>/dev/null \
        | python3 -c '
import sys, json, re
from datetime import datetime, timezone
period = sys.argv[1]
try:
    bugs_all = json.load(sys.stdin)
except Exception:
    bugs_all = []
def bug_bucket(ca):
    try:
        dt = datetime.fromtimestamp(int(ca) / 1e9, tz=timezone.utc)
    except (ValueError, OSError, TypeError):
        return None
    if re.match(r"^\d{4}-Q\d$", period):
        return f"{dt.year}-Q{(dt.month - 1) // 3 + 1}"
    return dt.strftime("%Y-%m")
filtered = [b for b in bugs_all if bug_bucket(b.get("created_at")) == period]
print(json.dumps(filtered))
' "$period"
}

# ── Helper: resolve current UTC quarter as YYYY-Q[1-4] ──────────────────────
_current_utc_quarter() {
    local month year quarter
    month=$(TZ="${CALIBRATION_TZ}" date '+%-m')
    year=$(TZ="${CALIBRATION_TZ}" date '+%Y')
    quarter=$(( (month - 1) / 3 + 1 ))
    echo "${year}-Q${quarter}"
}

# ── Helper: validate YYYY-Q[1-4] format ────────────────────────────────────
_validate_quarter_period() {
    local period="$1"
    if [[ ! "$period" =~ ^[0-9]{4}-Q[1-4]$ ]]; then
        echo "calibration-report: invalid period '${period}' — expected YYYY-Q[1-4]" >&2
        exit 1
    fi
}

# ── Helper: aggregate bugs by detected_by channel ───────────────────────────
# Shared function used by both monthly and quarterly subcommands.
# Takes the JSON array as $1, outputs channel→count map as JSON object.
aggregate_bugs_by_channel() {
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
        bugs_json=$(_load_from_cli "$period")
    fi

    # Aggregate by channel
    local channels_json
    channels_json=$(aggregate_bugs_by_channel "$bugs_json")

    # Render rollup body
    local rollup_body
    rollup_body=$(_render_rollup "$period" "$channels_json")

    if [ "$dry_run" -eq 1 ]; then
        echo "$rollup_body"
        return 0
    fi

    # Post rollup as comment on calibration-program-health ticket
    # Find calibration-program-health ticket by tag (default JSON format; --format=llm renames tags→tg)
    local health_ticket_id
    health_ticket_id=$(_find_health_ticket)

    if [ -z "$health_ticket_id" ]; then
        echo "calibration-report: ERROR: calibration-program-health ticket not found. Run dso-bootstrap-calibration-tickets.sh to create it." >&2
        exit 1
    fi

    # Idempotency guard: check via ticket show comments (ticket list-comments does not exist).
    local idempotency_marker="<!-- calibration-rollup: period=${period} kind=monthly -->"
    local existing_comments
    existing_comments=$(_read_ticket_comments "$health_ticket_id")
    if echo "$existing_comments" | grep -qF "$idempotency_marker"; then
        echo "calibration-report: skipping: rollup already posted for ${period}" >&2
        return 0
    fi

    "$DSO" ticket comment "$health_ticket_id" "$rollup_body"
    echo "calibration-report: rollup comment posted to ticket ${health_ticket_id} for period ${period}" >&2
}

# ── Helper: render quarterly rollup body ────────────────────────────────────
# Writes the quarterly comment body to stdout.
_render_quarterly_rollup() {
    local period="$1"
    local channels_json="$2"

    python3 - "$period" "$channels_json" <<'PY'
import json, sys

period = sys.argv[1]
counts = json.loads(sys.argv[2])

lines = []
lines.append(f"<!-- calibration-rollup: period={period} kind=quarterly -->")
lines.append(f"## Calibration Quarterly Rollup — {period}")
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
# Subcommand: quarterly
# ═══════════════════════════════════════════════════════════════════════════════
_cmd_quarterly() {
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
                echo "calibration-report quarterly: unknown option: $1" >&2
                _usage
                exit 1
                ;;
        esac
    done

    # Resolve period
    if [ -z "$period" ]; then
        period=$(_current_utc_quarter)
    fi
    _validate_quarter_period "$period"

    # Load bug data
    local bugs_json
    if [ -n "$fixture_dir" ]; then
        bugs_json=$(_load_fixture "$fixture_dir")
    else
        bugs_json=$(_load_from_cli "$period")
    fi

    # Aggregate by channel (shared function)
    local channels_json
    channels_json=$(aggregate_bugs_by_channel "$bugs_json")

    # Render rollup body
    local rollup_body
    rollup_body=$(_render_quarterly_rollup "$period" "$channels_json")

    if [ "$dry_run" -eq 1 ]; then
        echo "$rollup_body"
        return 0
    fi

    # Post rollup as comment on calibration-program-health ticket
    # (default JSON format; --format=llm renames tags→tg)
    local health_ticket_id
    health_ticket_id=$(_find_health_ticket)

    if [ -z "$health_ticket_id" ]; then
        echo "calibration-report: ERROR: calibration-program-health ticket not found. Run dso-bootstrap-calibration-tickets.sh to create it." >&2
        exit 1
    fi

    # Idempotency guard: quarterly markers use kind=quarterly — no collision with monthly.
    # Use ticket show comments (ticket list-comments does not exist as a subcommand).
    local idempotency_marker="<!-- calibration-rollup: period=${period} kind=quarterly -->"
    local existing_comments
    existing_comments=$(_read_ticket_comments "$health_ticket_id")
    if echo "$existing_comments" | grep -qF "$idempotency_marker"; then
        echo "calibration-report: skipping: quarterly rollup already posted for ${period}" >&2
        return 0
    fi

    "$DSO" ticket comment "$health_ticket_id" "$rollup_body"
    echo "calibration-report: quarterly rollup comment posted to ticket ${health_ticket_id} for period ${period}" >&2
}

# ── Helper: find the calibration-program-health ticket ID ──────────────────
# Emits the ticket ID to stdout, or empty string if not found.
_find_health_ticket() {
    "$DSO" ticket list --type=epic 2>/dev/null \
        | python3 -c '
import json, sys
try:
    tickets = json.load(sys.stdin)
except Exception:
    tickets = []
for t in tickets:
    if "calibration-program-health" in t.get("tags", []):
        print(t.get("ticket_id") or t.get("id", ""))
        break
' || true
}

# ── Helper: resolve flock executable ───────────────────────────────────────
# Returns 0 and prints path if found; returns 1 if unavailable.
_find_flock() {
    if command -v flock >/dev/null 2>&1; then
        command -v flock
    elif [ -x /opt/homebrew/opt/util-linux/bin/flock ]; then
        echo "/opt/homebrew/opt/util-linux/bin/flock"
    else
        return 1
    fi
}

# ── Helper: read existing comments from a ticket ───────────────────────────
# Emits all comment bodies concatenated, one per line.
_read_ticket_comments() {
    local ticket_id="$1"
    "$DSO" ticket show "$ticket_id" 2>/dev/null \
        | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print("\n".join(c.get("body", "") for c in d.get("comments", [])))
except Exception:
    pass
' || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# Subcommand: mutation-append
# ═══════════════════════════════════════════════════════════════════════════════
_cmd_mutation_append() {
    local pr_id="" findings_count="" dry_run=0

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr)
                [[ $# -ge 2 ]] || { echo "calibration-report: --pr requires an argument" >&2; exit 1; }
                pr_id="$2"
                shift 2
                ;;
            --findings)
                [[ $# -ge 2 ]] || { echo "calibration-report: --findings requires an argument" >&2; exit 1; }
                findings_count="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "calibration-report mutation-append: unknown option: $1" >&2
                _usage
                exit 1
                ;;
        esac
    done

    # Validate required args
    if [ -z "$pr_id" ]; then
        echo "calibration-report mutation-append: --pr is required" >&2
        exit 1
    fi
    if [ -z "$findings_count" ]; then
        echo "calibration-report mutation-append: --findings is required" >&2
        exit 1
    fi

    local idempotency_marker="<!-- calibration-mutation: pr=${pr_id} -->"
    local comment_body
    comment_body="${idempotency_marker}
**Mutation Append** — PR #${pr_id} | findings: ${findings_count} | $(TZ="${CALIBRATION_TZ}" date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "$dry_run" -eq 1 ]; then
        echo "$comment_body"
        return 0
    fi

    # Resolve health ticket
    local health_ticket_id
    health_ticket_id=$(_find_health_ticket)

    if [ -z "$health_ticket_id" ]; then
        echo "calibration-report: ERROR: calibration-program-health ticket not found. Run dso-bootstrap-calibration-tickets.sh to create it." >&2
        exit 1
    fi

    # Acquire exclusive lock per PR to prevent TOCTOU race (d079)
    local _LOCK_FILE="/tmp/calibration-append-${pr_id}.lock"
    local flock_bin
    if flock_bin=$(_find_flock); then
        (
            "$flock_bin" -x 9
            # Read-check-post sequence (inside lock)
            local existing_comments
            existing_comments=$(_read_ticket_comments "$health_ticket_id")
            if echo "$existing_comments" | grep -qF "$idempotency_marker"; then
                echo "calibration-report: skipping: mutation already posted for pr=${pr_id}" >&2
                exit 0
            fi
            "$DSO" ticket comment "$health_ticket_id" "$comment_body"
            echo "calibration-report: mutation-append comment posted to ticket ${health_ticket_id} for pr=${pr_id}" >&2
        ) 9>"$_LOCK_FILE"
    else
        echo "calibration-report: WARNING: flock not available; proceeding without lock" >&2
        # Read-check-post sequence (no lock — best effort)
        local existing_comments
        existing_comments=$(_read_ticket_comments "$health_ticket_id")
        if echo "$existing_comments" | grep -qF "$idempotency_marker"; then
            echo "calibration-report: skipping: mutation already posted for pr=${pr_id}" >&2
            return 0
        fi
        "$DSO" ticket comment "$health_ticket_id" "$comment_body"
        echo "calibration-report: mutation-append comment posted to ticket ${health_ticket_id} for pr=${pr_id}" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Subcommand: churn-append
# ═══════════════════════════════════════════════════════════════════════════════
_cmd_churn_append() {
    local pr_id="" churn_count="" dry_run=0

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr)
                [[ $# -ge 2 ]] || { echo "calibration-report: --pr requires an argument" >&2; exit 1; }
                pr_id="$2"
                shift 2
                ;;
            --churn)
                [[ $# -ge 2 ]] || { echo "calibration-report: --churn requires an argument" >&2; exit 1; }
                churn_count="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            *)
                echo "calibration-report churn-append: unknown option: $1" >&2
                _usage
                exit 1
                ;;
        esac
    done

    # Validate required args
    if [ -z "$pr_id" ]; then
        echo "calibration-report churn-append: --pr is required" >&2
        exit 1
    fi
    if [ -z "$churn_count" ]; then
        echo "calibration-report churn-append: --churn is required" >&2
        exit 1
    fi

    local idempotency_marker="<!-- calibration-churn: pr=${pr_id} -->"
    local comment_body
    comment_body="${idempotency_marker}
**Churn Append** — PR #${pr_id} | churn: ${churn_count} | $(TZ="${CALIBRATION_TZ}" date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ "$dry_run" -eq 1 ]; then
        echo "$comment_body"
        return 0
    fi

    # Resolve health ticket
    local health_ticket_id
    health_ticket_id=$(_find_health_ticket)

    if [ -z "$health_ticket_id" ]; then
        echo "calibration-report: ERROR: calibration-program-health ticket not found. Run dso-bootstrap-calibration-tickets.sh to create it." >&2
        exit 1
    fi

    # Acquire exclusive lock per PR to prevent TOCTOU race (d079)
    local _LOCK_FILE="/tmp/calibration-append-${pr_id}.lock"
    local flock_bin
    if flock_bin=$(_find_flock); then
        (
            "$flock_bin" -x 9
            # Read-check-post sequence (inside lock)
            local existing_comments
            existing_comments=$(_read_ticket_comments "$health_ticket_id")
            if echo "$existing_comments" | grep -qF "$idempotency_marker"; then
                echo "calibration-report: skipping: churn already posted for pr=${pr_id}" >&2
                exit 0
            fi
            "$DSO" ticket comment "$health_ticket_id" "$comment_body"
            echo "calibration-report: churn-append comment posted to ticket ${health_ticket_id} for pr=${pr_id}" >&2
        ) 9>"$_LOCK_FILE"
    else
        echo "calibration-report: WARNING: flock not available; proceeding without lock" >&2
        # Read-check-post sequence (no lock — best effort)
        local existing_comments
        existing_comments=$(_read_ticket_comments "$health_ticket_id")
        if echo "$existing_comments" | grep -qF "$idempotency_marker"; then
            echo "calibration-report: skipping: churn already posted for pr=${pr_id}" >&2
            return 0
        fi
        "$DSO" ticket comment "$health_ticket_id" "$comment_body"
        echo "calibration-report: churn-append comment posted to ticket ${health_ticket_id} for pr=${pr_id}" >&2
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Subcommand: query
# ═══════════════════════════════════════════════════════════════════════════════

# ── Help: query subcommand schema ───────────────────────────────────────────
_cmd_query_help() {
    cat <<'HELP'
Usage: calibration-report.sh query <sub> [options]

Sub-handlers:
  intents-with-low-kill-rate   List intents where mutation kill_rate < threshold.
  intents-without-coverage     List intents with no automated test coverage.
  bugs-by-channel-and-type     Count bugs grouped by detected_by channel and type.
  rule-effectiveness           Report effectiveness metrics for a review rule.

Options (all subs):
  --fixture <dir>   Use pre-canned JSON from <dir>/bugs.json instead of live CLI.
  --dry-run         No-op flag for forward-compatibility (all query subs are read-only).

Options for intents-with-low-kill-rate:
  --threshold <pct> Kill-rate threshold (default: 50). Intents below this are returned.

Options for rule-effectiveness:
  <rule-id>         Positional: the rule ID to query (e.g. "rule:no-raw-commit").

Output schema:
  intents-with-low-kill-rate:
    JSON array: [{"intent_id": "<title>", "kill_rate": <pct>, "bug_count": <n>}]
    kill_rate=0 pending mutation integration (bug ad1d-c14f).

  intents-without-coverage:
    JSON array: [{"intent_id": "<title>", "bug_count": <n>}]
    Coverage detection deferred (real mode emits []).

  bugs-by-channel-and-type:
    JSON array: [{"channel": "<ch>", "type": "<type>", "count": <n>}]

  rule-effectiveness:
    JSON object: {"rule_id": "<id>", "bug_count": <n>, "kill_rate": 0, "effectiveness_score": 0}
    kill_rate and effectiveness_score pending mutation integration (bug ad1d-c14f).
HELP
}

# ── Query sub-handler: intents-with-low-kill-rate ───────────────────────────
_query_intents_with_low_kill_rate() {
    local fixture_dir="$1"
    local threshold="${2:-50}"

    if [ -n "$fixture_dir" ]; then
        local bugs_json
        bugs_json=$(_load_fixture "$fixture_dir")
        python3 -c "
import json, sys

bugs = json.loads(sys.argv[1])
threshold = int(sys.argv[2])

# Group bugs by title (intent)
groups = {}
for bug in bugs:
    title = bug.get('title', '')
    groups[title] = groups.get(title, 0) + 1

# All intents have kill_rate=0 in fixture mode (no mutation data)
results = []
for title, count in sorted(groups.items()):
    kill_rate = 0
    if kill_rate < threshold:
        results.append({'intent_id': title, 'kill_rate': kill_rate, 'bug_count': count})

print(json.dumps(results))
" "$bugs_json" "$threshold"
    else
        # Real mode: mutation history integration deferred per bug ad1d-c14f
        echo "[]"
    fi
}

# ── Query sub-handler: intents-without-coverage ─────────────────────────────
_query_intents_without_coverage() {
    local fixture_dir="$1"

    if [ -n "$fixture_dir" ]; then
        local bugs_json
        bugs_json=$(_load_fixture "$fixture_dir")
        python3 -c "
import json, sys

bugs = json.loads(sys.argv[1])

# Group bugs by title (intent); check for test_run_id tags
groups = {}
has_coverage = set()
for bug in bugs:
    title = bug.get('title', '')
    groups[title] = groups.get(title, 0) + 1
    for tag in bug.get('tags', []):
        if tag.startswith('test_run_id:'):
            has_coverage.add(title)

# Return intents with no test_run_id tag
results = []
for title, count in sorted(groups.items()):
    if title not in has_coverage:
        results.append({'intent_id': title, 'bug_count': count})

print(json.dumps(results))
" "$bugs_json"
    else
        # Real mode: test coverage integration deferred
        echo "[]"
    fi
}

# ── Query sub-handler: bugs-by-channel-and-type ─────────────────────────────
_query_bugs_by_channel_and_type() {
    local fixture_dir="$1"

    if [ -n "$fixture_dir" ]; then
        local bugs_json
        bugs_json=$(_load_fixture "$fixture_dir")
        python3 -c "
import json, sys

bugs = json.loads(sys.argv[1])

# Group by (channel, type)
groups = {}
for bug in bugs:
    bug_type = bug.get('ticket_type', 'bug')
    channel = 'unknown'
    for tag in bug.get('tags', []):
        if tag.startswith('detected_by:'):
            channel = tag[len('detected_by:'):]
            break
    key = (channel, bug_type)
    groups[key] = groups.get(key, 0) + 1

results = []
for (channel, btype), count in sorted(groups.items()):
    results.append({'channel': channel, 'type': btype, 'count': count})

print(json.dumps(results))
" "$bugs_json"
    else
        # Real mode: fetch from ticket system and aggregate
        local bugs_json
        bugs_json=$("$DSO" ticket list --type=bug 2>/dev/null || echo "[]")
        python3 -c "
import json, sys

try:
    bugs = json.loads(sys.argv[1])
except Exception:
    bugs = []

groups = {}
for bug in bugs:
    bug_type = bug.get('ticket_type', 'bug')
    channel = 'unknown'
    for tag in bug.get('tags', []):
        if tag.startswith('detected_by:'):
            channel = tag[len('detected_by:'):]
            break
    key = (channel, bug_type)
    groups[key] = groups.get(key, 0) + 1

results = []
for (channel, btype), count in sorted(groups.items()):
    results.append({'channel': channel, 'type': btype, 'count': count})

print(json.dumps(results))
" "$bugs_json"
    fi
}

# ── Query sub-handler: rule-effectiveness ───────────────────────────────────
_query_rule_effectiveness() {
    local rule_id="$1"
    local fixture_dir="$2"

    if [ -z "$rule_id" ]; then
        echo "calibration-report query rule-effectiveness: <rule-id> argument required" >&2
        exit 1
    fi

    local bug_count=0

    if [ -n "$fixture_dir" ]; then
        local bugs_json
        bugs_json=$(_load_fixture "$fixture_dir")
        bug_count=$(python3 -c "
import json, sys

bugs = json.loads(sys.argv[1])
rule_tag = 'rule:' + sys.argv[2]
count = sum(1 for b in bugs if rule_tag in b.get('tags', []))
print(count)
" "$bugs_json" "$rule_id")
    else
        bug_count=$("$DSO" ticket list --type=bug 2>/dev/null \
            | python3 -c "
import json, sys
try:
    bugs = json.load(sys.stdin)
except Exception:
    bugs = []
rule_tag = 'rule:' + sys.argv[1]
count = sum(1 for b in bugs if rule_tag in b.get('tags', []))
print(count)
" "$rule_id" || echo "0")
    fi

    python3 -c "
import json, sys
print(json.dumps({
    'rule_id': sys.argv[1],
    'bug_count': int(sys.argv[2]),
    'kill_rate': 0,
    'effectiveness_score': 0
}))
" "$rule_id" "$bug_count"
}

# ── Subcommand dispatcher: query ─────────────────────────────────────────────
_cmd_query() {
    local sub="" fixture_dir="" dry_run=0 threshold=50

    # First pass: check for --help before requiring sub
    for arg in "$@"; do
        if [[ "$arg" == "--help" ]]; then
            _cmd_query_help
            return 0
        fi
    done

    if [[ $# -eq 0 ]]; then
        _cmd_query_help
        exit 1
    fi

    sub="$1"
    shift

    # Parse shared flags
    local positionals=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fixture)
                [[ $# -ge 2 ]] || { echo "calibration-report query: --fixture requires an argument" >&2; exit 1; }
                fixture_dir="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            --threshold)
                [[ $# -ge 2 ]] || { echo "calibration-report query: --threshold requires an argument" >&2; exit 1; }
                threshold="$2"
                shift 2
                ;;
            --*)
                echo "calibration-report query: unknown option: $1" >&2
                _cmd_query_help
                exit 1
                ;;
            *)
                positionals+=("$1")
                shift
                ;;
        esac
    done

    case "$sub" in
        intents-with-low-kill-rate)
            _query_intents_with_low_kill_rate "$fixture_dir" "$threshold"
            ;;
        intents-without-coverage)
            _query_intents_without_coverage "$fixture_dir"
            ;;
        bugs-by-channel-and-type)
            _query_bugs_by_channel_and_type "$fixture_dir"
            ;;
        rule-effectiveness)
            local rule_id="${positionals[0]:-}"
            _query_rule_effectiveness "$rule_id" "$fixture_dir"
            ;;
        *)
            echo "calibration-report query: unknown sub-handler: ${sub}" >&2
            _cmd_query_help
            exit 1
            ;;
    esac
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
        quarterly)
            _cmd_quarterly "$@"
            ;;
        mutation-append)
            _cmd_mutation_append "$@"
            ;;
        churn-append)
            _cmd_churn_append "$@"
            ;;
        query)
            _cmd_query "$@"
            ;;
        *)
            echo "calibration-report: unknown subcommand: ${subcommand}" >&2
            _usage
            exit 1
            ;;
    esac
}

main "$@"
