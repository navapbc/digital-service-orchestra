#!/usr/bin/env bash
# query-stats.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry query utility
set -euo pipefail
#
# Procedural bash subcommand dispatcher for querying DSO telemetry data.
#
# Subcommands:
#   roundtrip [--timeout=N]  — emit test event + poll S3 until it lands
#   counts    --days=N       — per-client_id event counts over N days
#   recent    --days=N [--limit=M] — most recent M events over N days
#   missing   --days=N       — date-partition gaps in N-day window
#   sizes     --days=N       — per-day object count + total bytes over N days
#
# ── Environment overrides (for testability) ────────────────────────────────────
#   DSO_AWS_CMD                 Override the aws binary
#   DSO_DUCKDB_CMD              Override the duckdb binary
#   DSO_READ_CONFIG_CMD         Override the path to the read-config helper
#   DSO_ROUNDTRIP_BACKOFF_SCHEDULE  Space-separated list of sleep durations (seconds)
#                               e.g. "1 2 4 8 15 30"; default: "1 2 4 8 15 30"

# ── Resolve paths ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# scripts/telemetry/ lives four levels below repo root
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

# CLAUDE_PLUGIN_ROOT is used for self-referential paths (e.g. telemetry-emit.sh).
# SCRIPT_DIR is two levels below the plugin root (scripts/telemetry/ within the plugin).
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# ── Overridable commands ───────────────────────────────────────────────────────
_AWS_CMD="${DSO_AWS_CMD:-aws}"
_DUCKDB_CMD="${DSO_DUCKDB_CMD:-duckdb}"
_READ_CONFIG_CMD="${DSO_READ_CONFIG_CMD:-"$REPO_ROOT/.claude/scripts/dso read-config"}"

# ── Internal wrappers ──────────────────────────────────────────────────────────
_aws() {
    "$_AWS_CMD" "$@"
}

_duckdb() {
    "$_DUCKDB_CMD" "$@"
}

_read_config() {
    $_READ_CONFIG_CMD "$1" 2>/dev/null || true
}

# ── Load required config keys ─────────────────────────────────────────────────
BUCKET="$(_read_config review_telemetry.bucket_name)"

if [[ -z "$BUCKET" ]]; then
    echo "ERROR: config key review_telemetry.bucket_name is not set" >&2
    exit 1
fi

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 << 'EOF'
Usage: query-stats.sh <subcommand> [options]

Subcommands:
  roundtrip [--timeout=N]       Emit a test event and poll S3 until it lands (60s budget)
  counts    --days=N             Per-client_id event counts over last N days
  recent    --days=N [--limit=M] Most recent M events over last N days (default limit: 20)
  missing   --days=N             Date-partition gaps (zero-event days) in N-day window
  sizes     --days=N             Per-day object count and total bytes over last N days
EOF
}

# ── Helper: build list of N daily date prefixes (YYYY-MM-DD) ─────────────────
# Outputs one date per line, starting from today going back N-1 days
_build_date_list() {
    local days="$1"
    local i date_str
    for (( i=0; i<days; i++ )); do
        # macOS: date -v-${i}d; GNU: date -d "${i} days ago"
        date_str="$(date -u -v-"${i}d" +%Y-%m-%d 2>/dev/null \
            || date -u -d "${i} days ago" +%Y-%m-%d 2>/dev/null \
            || true)"
        if [[ -n "$date_str" ]]; then
            echo "$date_str"
        fi
    done
}

# ── Helper: build comma-separated S3 glob paths for DuckDB ───────────────────
# s3_writer.py writes objects under ${client_id}/${YYYY-MM-DD}/${event_id}.jsonl,
# so the glob must place a client-id wildcard FIRST and the date second:
# e.g. 's3://bucket/*/2026-05-23/*.jsonl', 's3://bucket/*/2026-05-22/*.jsonl'.
# Using '*/${date}' captures every client_id partition for the given date.
_build_s3_paths() {
    local days="$1"
    local paths=()
    local date_str
    while IFS= read -r date_str; do
        paths+=("'s3://${BUCKET}/*/${date_str}/*.jsonl'")
    done < <(_build_date_list "$days")

    local IFS=','
    echo "${paths[*]}"
}

# ── Subcommand: roundtrip ─────────────────────────────────────────────────────
cmd_roundtrip() {
    local timeout_secs=60
    local arg
    for arg in "$@"; do
        case "$arg" in
            --timeout=*) timeout_secs="${arg#--timeout=}" ;;
        esac
    done

    # Emit the test event.
    # telemetry_emit.py uses argparse with --event-type / --payload-field flags
    # (NOT positional KEY=VALUE). event_type must be one of the canonical enum
    # values; "tool_finding" is the closest fit for a smoke-test event and
    # carries the required tool_name / tool_rule / tool_severity / file /
    # message PER_TYPE_FIELDS. Override client_id via --payload-field so the
    # roundtrip event lands under the `dso-roundtrip-test/` S3 partition rather
    # than polluting the operator's real client_id partition — this also keeps
    # the S3 poll loop below scoped to a stable sentinel prefix.
    local emit_script="${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/telemetry-emit.sh"
    bash "$emit_script" \
        --event-type tool_finding \
        --payload-field 'client_id=dso-roundtrip-test' \
        --payload-field 'tool_name=dso-query-stats-roundtrip' \
        --payload-field 'tool_rule=roundtrip_smoke_test' \
        --payload-field 'tool_severity=info' \
        --payload-field 'file=' \
        --payload-field 'message=cmd_roundtrip synthetic ping' \
        2>/dev/null || true

    # Backoff schedule: allow override for tests
    local schedule_str="${DSO_ROUNDTRIP_BACKOFF_SCHEDULE:-1 2 4 8 15 30}"
    # shellcheck disable=SC2206
    local schedule=( $schedule_str )

    local elapsed=0
    local iteration=0
    local total_iterations=${#schedule[@]}

    while [[ $iteration -lt $total_iterations ]]; do
        local sleep_secs="${schedule[$iteration]}"
        # Sleep before poll (except iteration 0 gets at least a moment)
        if [[ "$sleep_secs" -gt 0 ]] 2>/dev/null; then
            sleep "$sleep_secs"
        fi
        elapsed=$(( elapsed + sleep_secs ))

        # Poll S3 for the sentinel object
        local list_result
        list_result="$(_aws s3api list-objects-v2 \
            --bucket "$BUCKET" \
            --prefix "dso-roundtrip-test/" \
            --output json 2>/dev/null || echo '{}')"

        # Check if Contents is non-empty
        local has_content
        has_content="$(printf '%s' "$list_result" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    contents = d.get('Contents', [])
    print('yes' if contents else 'no')
except Exception:
    print('no')
" 2>/dev/null || echo "no")"

        if [[ "$has_content" == "yes" ]]; then
            echo "roundtrip: test object landed after ~${elapsed}s" >&2
            return 0
        fi

        iteration=$(( iteration + 1 ))

        # Check budget
        if [[ $elapsed -ge $timeout_secs ]]; then
            break
        fi
    done

    echo "roundtrip: timeout after ${elapsed}s — test object not found in s3://${BUCKET}/dso-roundtrip-test/" >&2
    return 1
}

# ── Subcommand: counts ────────────────────────────────────────────────────────
cmd_counts() {
    local days=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --days=*) days="${arg#--days=}" ;;
        esac
    done

    if [[ -z "$days" ]]; then
        echo "ERROR: counts requires --days=N" >&2
        usage
        exit 1
    fi

    local s3_paths
    s3_paths="$(_build_s3_paths "$days")"

    local sql
    sql="SELECT client_id, COUNT(*) AS event_count
FROM read_json_auto([${s3_paths}], ignore_errors=true)
GROUP BY client_id
ORDER BY event_count DESC;"

    _duckdb :memory: "$sql"
}

# ── Subcommand: recent ────────────────────────────────────────────────────────
cmd_recent() {
    local days="" limit=20
    local arg
    for arg in "$@"; do
        case "$arg" in
            --days=*)  days="${arg#--days=}" ;;
            --limit=*) limit="${arg#--limit=}" ;;
        esac
    done

    if [[ -z "$days" ]]; then
        echo "ERROR: recent requires --days=N" >&2
        usage
        exit 1
    fi

    local s3_paths
    s3_paths="$(_build_s3_paths "$days")"

    local sql
    sql="SELECT *
FROM read_json_auto([${s3_paths}], ignore_errors=true)
ORDER BY timestamp DESC
LIMIT ${limit};"

    _duckdb :memory: "$sql"
}

# ── Subcommand: missing ───────────────────────────────────────────────────────
cmd_missing() {
    local days=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --days=*) days="${arg#--days=}" ;;
        esac
    done

    if [[ -z "$days" ]]; then
        echo "ERROR: missing requires --days=N" >&2
        usage
        exit 1
    fi

    # Build date list and per-date paths to detect gaps
    local date_list
    date_list="$(_build_date_list "$days")"

    # Build a query that lists each expected date and its object count,
    # filtering for dates with zero objects (gaps)
    # We construct per-day paths and check each one individually
    local date_cases=""
    local date_str
    while IFS= read -r date_str; do
        date_cases="${date_cases}
    SELECT '${date_str}' AS partition_date,
           (SELECT COUNT(*) FROM read_json_auto(
               ['s3://${BUCKET}/${date_str}/**/*.jsonl'],
               ignore_errors=true
           )) AS event_count,"
    done <<< "$date_list"

    # Simpler approach: use a UNION of per-day counts
    local union_parts=()
    while IFS= read -r date_str; do
        union_parts+=("SELECT '${date_str}' AS partition_date, COUNT(*) AS event_count FROM read_json_auto(['s3://${BUCKET}/${date_str}/**/*.jsonl'], ignore_errors=true)")
    done <<< "$date_list"

    local IFS=$'\n'
    local union_sql
    union_sql="$(printf '%s\nUNION ALL\n' "${union_parts[@]}")"
    # Remove trailing UNION ALL
    union_sql="${union_sql%$'\n'UNION ALL$'\n'}"

    local sql
    sql="SELECT partition_date
FROM (
    ${union_sql}
) day_counts
WHERE event_count = 0
ORDER BY partition_date;"

    _duckdb :memory: "$sql"
}

# ── Subcommand: sizes ─────────────────────────────────────────────────────────
cmd_sizes() {
    local days=""
    local arg
    for arg in "$@"; do
        case "$arg" in
            --days=*) days="${arg#--days=}" ;;
        esac
    done

    if [[ -z "$days" ]]; then
        echo "ERROR: sizes requires --days=N" >&2
        usage
        exit 1
    fi

    local s3_paths
    s3_paths="$(_build_s3_paths "$days")"

    # DuckDB: extract date partition from file path + aggregate
    local sql
    sql="SELECT
    regexp_extract(filename, '([0-9]{4}-[0-9]{2}-[0-9]{2})', 1) AS partition_date,
    COUNT(*) AS object_count,
    SUM(length(json_serialize(row))) AS total_bytes
FROM read_json_auto([${s3_paths}], filename=true, ignore_errors=true)
GROUP BY partition_date
ORDER BY partition_date DESC;"

    _duckdb :memory: "$sql"
}

# ── Main dispatcher ────────────────────────────────────────────────────────────
main() {
    local subcmd="${1:-}"
    shift || true

    case "$subcmd" in
        roundtrip) cmd_roundtrip "$@" ;;
        counts)    cmd_counts    "$@" ;;
        recent)    cmd_recent    "$@" ;;
        missing)   cmd_missing   "$@" ;;
        sizes)     cmd_sizes     "$@" ;;
        *)
            echo "ERROR: unknown subcommand: '${subcmd}'" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
