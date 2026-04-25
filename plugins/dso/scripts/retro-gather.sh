#!/usr/bin/env bash
# retro-gather.sh — Collect all Phase 1 health metrics for /dso:retro.
#
# Extracts the deterministic data-collection steps from retro SKILL.md Phase 1
# into a single script that outputs structured sections. The LLM only needs to
# interpret/analyze the output, not run the individual commands.
#
# Usage:
#   retro-gather.sh           # Full collection
#   retro-gather.sh --quick   # Skip slow checks (dependency freshness, plugin versions)
#
# Output: Structured text sections to stdout, suitable for LLM analysis.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 2
fi
QUICK="${1:-}"

# ── Config-driven artifact prefix ──────────────────────────────────────────
# read-config.sh is a sibling script in the same directory
PLUGIN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_PREFIX="$(bash "$PLUGIN_SCRIPTS/read-config.sh" session.artifact_prefix 2>/dev/null || true)"
if [ -z "$ARTIFACT_PREFIX" ]; then
    # Derive from repo dir name: strip dots, spaces, underscores → hyphens, lowercase
    ARTIFACT_PREFIX="$(basename "$REPO_ROOT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/-$//')-test-artifacts"
fi

# ── Config-driven app directory ─────────────────────────────────────────────
_app_dir_rel="$(bash "$PLUGIN_SCRIPTS/read-config.sh" paths.app_dir 2>/dev/null || true)"
if [ -n "$_app_dir_rel" ]; then
    APP_DIR="$REPO_ROOT/$_app_dir_rel"
else
    APP_DIR="$REPO_ROOT/app"
fi

section() {
    echo "=== $1 ==="
}

# --- Friction Suggestions (fast — emitted before slow validation) ---
# Reads .tickets-tracker/.suggestions/*.json, groups by affected_file/skill_name,
# and outputs frequency-ranked clusters. Section omitted when no suggestions exist.
TRACKER_DIR="${TRACKER_DIR:-$REPO_ROOT/.tickets-tracker}"
SUGGESTIONS_DIR="$TRACKER_DIR/.suggestions"
if [ -d "$SUGGESTIONS_DIR" ] && compgen -G "$SUGGESTIONS_DIR/*.json" > /dev/null 2>&1; then
    section "SUGGESTION_DATA"
    python3 - "$SUGGESTIONS_DIR" <<'PYEOF'
import json, os, sys, collections

suggestions_dir = sys.argv[1]

# Load all suggestion records
records = []
for fname in sorted(os.listdir(suggestions_dir)):
    if not fname.endswith('.json'):
        continue
    fpath = os.path.join(suggestions_dir, fname)
    try:
        with open(fpath, encoding='utf-8') as f:
            data = json.load(f)
        records.append(data)
    except Exception:
        pass  # Skip malformed files

if not records:
    sys.exit(0)

# Group by (affected_file, skill_name) as the cluster key
cluster_counts = collections.Counter()
cluster_recommendations = collections.defaultdict(list)

for rec in records:
    affected_file = rec.get('affected_file') or '(unknown)'
    skill_name = rec.get('skill_name') or rec.get('pattern') or '(unknown)'
    key = (affected_file, skill_name)
    cluster_counts[key] += 1
    rec_text = rec.get('recommendation') or rec.get('observation') or ''
    if rec_text:
        cluster_recommendations[key].append(rec_text)

# Output clusters ranked by frequency (highest first)
print(f"Total suggestion records: {len(records)}")
print(f"Distinct clusters: {len(cluster_counts)}")
print("")

for (affected_file, skill_name), count in cluster_counts.most_common():
    key = (affected_file, skill_name)
    recs = cluster_recommendations[key]
    # Deduplicate recommendations, keep insertion order
    seen = set()
    unique_recs = []
    for r in recs:
        if r not in seen:
            seen.add(r)
            unique_recs.append(r)
    proposed_edit = unique_recs[0] if unique_recs else '(no recommendation)'
    print(f"  count={count}  file={affected_file}  pattern={skill_name}")
    print(f"    proposed_edit: {proposed_edit}")

PYEOF
fi

# --- Step 1: Cleanup + Validation ---
section "CLEANUP"
if [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-claude-session.sh" ]; then
    "${CLAUDE_PLUGIN_ROOT}/scripts/cleanup-claude-session.sh" 2>&1 | tail -5
else
    echo "cleanup-claude-session.sh not found, skipping"
fi

section "VALIDATION"
# When CI_STATUS=pending is supplied externally (e.g. by a caller that already
# knows CI is still running), skip the --ci flag so validate.sh does not exit
# non-zero and abort collection.  All other local checks still run.
# RETRO_SKIP_VALIDATION=1 skips validate.sh entirely (useful in tests to avoid
# spawning orphan subprocesses and to keep test runtime bounded).
if [ "${RETRO_SKIP_VALIDATION:-}" = "1" ]; then
    echo "Skipped (RETRO_SKIP_VALIDATION=1)"
elif [ "${CI_STATUS:-}" = "pending" ]; then
    "${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh" --full 2>&1 || true
    echo "ci: PENDING — skip CI check (CI_STATUS=pending)"
else
    "${CLAUDE_PLUGIN_ROOT}/scripts/validate.sh" --full --ci 2>&1 || true
fi

# --- Step 2: Issues Health ---
section "TICKETS_HEALTH"
"${CLAUDE_PLUGIN_ROOT}/scripts/validate-issues.sh" 2>&1 || true

section "TICKETS_STATS"
# Aggregate ticket stats via v3 ticket system (event-sourced, JSON reducer)
TICKET_CMD="$SCRIPT_DIR/ticket"
if [ -x "$TICKET_CMD" ]; then
    "$TICKET_CMD" list 2>/dev/null | python3 -c "
import json, sys, collections
tickets = json.load(sys.stdin)
valid = [t for t in tickets if 'status' in t and t.get('status') != 'error']
stats = collections.Counter(t['status'] for t in valid)
print('total: ' + str(len(valid)) + ', ' + ', '.join(f'{k}: {v}' for k, v in sorted(stats.items())))
" 2>/dev/null || echo "ticket list failed"
else
    echo "ticket command not found"
fi

section "TICKETS_OPEN"
if [ -x "$TICKET_CMD" ]; then
    "$TICKET_CMD" list 2>/dev/null | python3 -c "
import json, sys
tickets = json.load(sys.stdin)
found = False
for t in sorted((t for t in tickets if t.get('status') == 'open'), key=lambda x: x.get('ticket_id','')):
    print(t['ticket_id'] + ' ' + t.get('title','(no title)'))
    found = True
if not found:
    print('none')
" 2>/dev/null || echo "none"
else
    echo "none"
fi

section "TICKETS_IN_PROGRESS"
if [ -x "$TICKET_CMD" ]; then
    "$TICKET_CMD" list 2>/dev/null | python3 -c "
import json, sys
tickets = json.load(sys.stdin)
found = False
for t in sorted((t for t in tickets if t.get('status') == 'in_progress'), key=lambda x: x.get('ticket_id','')):
    print(t['ticket_id'] + ' ' + t.get('title','(no title)'))
    found = True
if not found:
    print('none')
" 2>/dev/null || echo "none"
else
    echo "none"
fi

section "TICKETS_BLOCKED"
echo "none"

section "TICKETS_ORPHANED"
# TODO(5d90-b43c): v2 orphan detection removed — stub returns none
echo "none"

# --- Step 3: Worktree Status ---
section "WORKTREES"
git worktree list 2>/dev/null || echo "No worktrees"

section "WORKTREE_STALENESS"
git worktree list --porcelain 2>/dev/null | grep '^worktree ' | sed 's/^worktree //' | while IFS= read -r wt_path; do
    if [ -d "$wt_path" ]; then
        last_commit=$(git -C "$wt_path" log -1 --format='%ci' 2>/dev/null || echo "unknown")
        days_old=""
        if [ "$last_commit" != "unknown" ]; then
            commit_ts=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$last_commit" +%s 2>/dev/null || date -d "$last_commit" +%s 2>/dev/null || echo "")
            if [ -n "$commit_ts" ]; then
                now_ts=$(date +%s)
                days_old=$(( (now_ts - commit_ts) / 86400 ))
            fi
        fi
        stale=""
        if [ -n "$days_old" ] && [ "$days_old" -gt 7 ]; then
            stale=" [STALE: ${days_old}d]"
        fi
        echo "  $wt_path — last commit: $last_commit${stale}"
    fi
done

# --- Step 4: Dependency Freshness ---
if [ "$QUICK" != "--quick" ]; then
    section "OUTDATED_DEPENDENCIES"
    (cd "$APP_DIR" && poetry show --outdated 2>/dev/null) || echo "Could not check dependencies"
else
    section "OUTDATED_DEPENDENCIES"
    echo "Skipped (--quick mode)"
fi

# --- Step 5: Session Usage ---
section "SESSION_USAGE"
if [ -x "$HOME/.claude/check-session-usage.sh" ]; then
    "$HOME/.claude/check-session-usage.sh" 2>&1 || echo "Session usage: normal"
else
    echo "check-session-usage.sh not found"
fi

# --- Step 6: Error Log Triage ---
section "HOOK_ERROR_LOG"
HOOK_LOG="$HOME/.claude/hook-error-log.jsonl"
if [ -f "$HOOK_LOG" ] && [ -s "$HOOK_LOG" ]; then
    echo "Entries: $(wc -l < "$HOOK_LOG" | tr -d ' ')"
    echo "Grouped by hook:"
    python3 -c "
import json, sys, collections
counts = collections.Counter()
with open('$HOOK_LOG') as f:
    for line in f:
        try:
            d = json.loads(line.strip())
            counts[d.get('hook','unknown')] += 1
        except: pass
for hook, count in counts.most_common():
    print(f'  {hook}: {count}')
" 2>/dev/null || echo "  (could not parse)"
else
    echo "No error logs to triage"
fi

section "TIMEOUT_LOGS"
for log_dir in /tmp/"${ARTIFACT_PREFIX}"-*/; do
    [ -d "$log_dir" ] || continue
    for log_file in "$log_dir"validation-timeouts.log "$log_dir"precommit-timeouts.log; do
        if [ -f "$log_file" ] && [ -s "$log_file" ]; then
            echo "--- $(basename "$log_file") ---"
            wc -l < "$log_file" | tr -d ' '
            echo " events"
            tail -5 "$log_file"
        fi
    done
done
if ! compgen -G "/tmp/${ARTIFACT_PREFIX}-*/" > /dev/null 2>&1; then
    echo "No timeout logs found for prefix ${ARTIFACT_PREFIX}"
fi

# --- Step 7: Plugin Versions ---
if [ "$QUICK" != "--quick" ]; then
    section "PLUGIN_VERSIONS"
    PLUGIN_CACHE="$HOME/.claude/plugins/cache"
    if [ -d "$PLUGIN_CACHE" ]; then
        echo "Installed plugins:"
        find "$PLUGIN_CACHE" -maxdepth 1 -mindepth 1 2>/dev/null | while IFS= read -r _plugin_path; do
            plugin=$(basename "$_plugin_path")
            echo "  $plugin"
        done
    else
        echo "No plugin cache found"
    fi

    # Check MCP server pins from .mcp.json files
    for mcp_file in "$REPO_ROOT/.mcp.json" "$HOME/.claude/.mcp.json"; do
        if [ -f "$mcp_file" ]; then
            echo "MCP config: $mcp_file"
            python3 -c "
import json
with open('$mcp_file') as f:
    cfg = json.load(f)
for name, srv in cfg.get('mcpServers', {}).items():
    args = srv.get('args', [])
    pkg = next((a for a in args if '@' in a or '/' in a), None)
    if pkg:
        print(f'  {name}: {pkg}')
" 2>/dev/null || echo "  (could not parse)"
        fi
    done
else
    section "PLUGIN_VERSIONS"
    echo "Skipped (--quick mode)"
fi

# --- Phase 2 Data Collection (codebase metrics) ---
section "TEST_METRICS"
echo "Test file counts:"
for dir in unit e2e integration; do
    count=$(find "$APP_DIR/tests/$dir" -name 'test_*.py' -o -name '*_test.py' 2>/dev/null | wc -l | tr -d ' ')
    echo "  tests/$dir: $count files"
done

echo "Skipped tests:"
(grep -Ern '@pytest\.mark\.skip|pytest\.skip\(' "$APP_DIR/tests/" 2>/dev/null || true) | wc -l | tr -d ' '
echo " skipped test markers"

section "CODE_METRICS"
echo "Top 10 files by line count (>500 lines):"
find "$APP_DIR/src" -name '*.py' -exec wc -l {} + 2>/dev/null | sort -rn | head -11 | tail -10 | while IFS= read -r line; do
    count=$(echo "$line" | awk '{print $1}')
    if [ "$count" -gt 500 ] 2>/dev/null; then
        echo "  $line"
    fi
done

echo "TODO-family comment scan (src/ and tests/):"
# Covers: TODO, FIXME, HACK, XXX, NOCOMMIT, TEMP, KLUDGE, WORKAROUND, BUG, REVISIT, DEPRECATED
# Each pattern is searched case-insensitively; matches require a word boundary so e.g.
# "temporary" or "fixmes" do not fire. Output is structured for agent evaluation —
# per-pattern counts first (deterministic), then sample matches (first 25) for triage.
_TODO_PATTERN='#[[:space:]]*(TODO|FIXME|HACK|XXX|NOCOMMIT|TEMP|KLUDGE|WORKAROUND|BUG|REVISIT|DEPRECATED)[[:space:]:!]'
echo "  Per-pattern counts (non-zero only):"
for pat in TODO FIXME HACK XXX NOCOMMIT TEMP KLUDGE WORKAROUND BUG REVISIT DEPRECATED; do
    { set +o pipefail; count=$(grep -rnEi "#[[:space:]]*${pat}[[:space:]:!]" "$APP_DIR/src/" "$APP_DIR/tests/" 2>/dev/null | wc -l | tr -d ' '); set -o pipefail; } 2>/dev/null || true
    if [ "${count:-0}" -gt 0 ]; then
        printf "    %-14s %s\n" "$pat:" "${count:-0}"
    fi
done
{ set +o pipefail; _todo_total=$(grep -rnEi "$_TODO_PATTERN" "$APP_DIR/src/" "$APP_DIR/tests/" 2>/dev/null | wc -l | tr -d ' '); set -o pipefail; } 2>/dev/null || true
_todo_total="${_todo_total:-0}"
echo "  Total: $_todo_total"
echo "  Sample matches (up to 25, for agent evaluation):"
grep -rnEi "$_TODO_PATTERN" "$APP_DIR/src/" "$APP_DIR/tests/" 2>/dev/null \
    | sed "s|$APP_DIR/||" \
    | head -25 \
    || true

section "KNOWN_ISSUES"
if [ -f "$REPO_ROOT/.claude/docs/KNOWN-ISSUES.md" ]; then
    total=$(grep -cE '^### INC-' "$REPO_ROOT/.claude/docs/KNOWN-ISSUES.md" 2>/dev/null || echo "0")
    resolved=$(grep -ciE 'status.*resolved' "$REPO_ROOT/.claude/docs/KNOWN-ISSUES.md" 2>/dev/null || echo "0")
    echo "Total incidents: $total"
    echo "Resolved: $resolved"
else
    echo "KNOWN-ISSUES.md not found"
fi

section "CI_SHIFT_LEFT"
# Raw CI failure data for the shift-left analysis in /dso:retro Phase 2.
# Collects: recent run outcomes, failed job names, and failure rate.
# The LLM maps each failure type to the earliest gate that could catch it.
if ! command -v gh >/dev/null 2>&1; then
    echo "gh CLI not available — skipping CI shift-left data"
else
    echo "Recent CI runs on main (last 20 — conclusion / date / title):"
    gh run list --workflow=CI --branch=main --limit=20 \
        --json conclusion,createdAt,displayTitle \
        --jq '.[] | "\(.conclusion)\t\(.createdAt[0:16])\t\(.displayTitle)"' 2>/dev/null \
        | sed 's/^/  /' \
        || echo "  (could not retrieve runs)"

    echo ""
    echo "Failure rate (last 20 runs on main):"
    _fail_count=$(gh run list --workflow=CI --branch=main --limit=20 \
        --json conclusion \
        --jq '[.[] | select(.conclusion == "failure")] | length' 2>/dev/null || echo "?")
    echo "  ${_fail_count} failures out of 20 runs"

    echo ""
    echo "Failed job names (last 5 failures on main, for shift-left categorisation):"
    _failed_ids=$(gh run list --workflow=CI --branch=main --status=failure --limit=5 \
        --json databaseId --jq '.[].databaseId' 2>/dev/null || echo "")
    if [ -z "$_failed_ids" ]; then
        echo "  No recent failures on main"
    else
        echo "$_failed_ids" | while IFS= read -r _run_id; do
            [ -z "$_run_id" ] && continue
            echo "  Run $_run_id:"
            gh run view "$_run_id" --json jobs \
                --jq '.jobs[] | select(.conclusion == "failure") | "    [FAIL] \(.name)"' \
                2>/dev/null || echo "    (could not retrieve jobs)"
        done
    fi
fi

section "GATHER_COMPLETE"
echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
