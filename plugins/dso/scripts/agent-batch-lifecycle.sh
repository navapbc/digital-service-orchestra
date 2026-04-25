#!/usr/bin/env bash
set -euo pipefail
# agent-batch-lifecycle.sh — Shared lifecycle operations for multi-agent orchestration.
#
# Consolidates deterministic sequences used by /dso:debug-everything and /dso:sprint.
# Config-driven: all project-specific values read from dso-config.conf via read-config.sh.
#
# Subcommands:
#   pre-check [--db]          Pre-batch safety checks (session usage, git, optional DB)
#   preflight [--start-db]    Pre-flight Docker & DB check (before diagnostic sub-agents)
#   file-overlap <file>...    Detect file conflicts from multiple agent result files
#   lock-acquire <label>      Session lock via ticket CLI (debug-everything only)
#   lock-release <issue-id>   Release session lock (debug-everything only)
#   lock-status <label>       Check if a session lock exists
#   cleanup-stale-containers  Remove Docker containers for worktrees that no longer exist
#   cleanup-discoveries       Remove agent discovery files and ensure directory exists
#
# Exit codes:
#   0 = success / checks pass
#   1 = check failed (details on stdout)
#   2 = usage error
#   10 = context-check only: medium usage (compaction recommended)
#   11 = context-check only: high usage (compaction recommended, limit agents)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_SCRIPTS="$SCRIPT_DIR"
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "")}"
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not in a git repository"
    exit 2
fi

# ─── Rate-limit sentinel ────────────────────────────────────────────────────
# Default sentinel path; override via RATE_LIMIT_SENTINEL for test isolation.
# Use an internal variable (_RL_SENTINEL) to capture the path so that it
# persists when the script is sourced via `RATE_LIMIT_SENTINEL=val source ...`
# (bash drops prefix-assigned vars of the same name after source returns,
# but preserves assignments to different names).
_RL_SENTINEL="${RATE_LIMIT_SENTINEL:-$HOME/.cache/claude/error-reactive-throttle}"

# _check_rate_limit_error <text>
#   Checks whether <text> contains quota-specific rate-limit keywords.
#   Matches: rate.limit, usage.limit, quota.exceeded (case-insensitive).
#   Does NOT match bare "429" without a quota keyword.
#   On match: writes sentinel file with timestamp, returns 0.
#   No match: returns 1 (sentinel not created).
_check_rate_limit_error() {
    local text="${1:-}"
    if echo "$text" | grep -qiE 'rate.limit|usage.limit|quota.exceeded'; then
        # Ensure parent directory exists
        mkdir -p "$(dirname "$_RL_SENTINEL")"
        date '+%s' > "$_RL_SENTINEL"
        return 0
    fi
    return 1
}

# ─── Config helpers ──────────────────────────────────────────────────────────
# _read_cfg <key> — read a config value, respecting WORKFLOW_CONFIG env var override.
# When WORKFLOW_CONFIG is set, it is passed as the config-file argument to read-config.sh.
# This allows callers (e.g. tests) to point at /dev/null or a minimal config to simulate
# absent sections without touching the real dso-config.conf.
_read_cfg() {
    local key="$1"
    if [ -n "${WORKFLOW_CONFIG:-}" ]; then
        bash "$SCRIPT_DIR/read-config.sh" "$WORKFLOW_CONFIG" "$key" 2>/dev/null || true
    else
        bash "$SCRIPT_DIR/read-config.sh" "$key" 2>/dev/null || true
    fi
}

# _compute_max_agents — determine the maximum number of concurrent sub-agents.
#
# Combines three signals:
#   1. check-usage.sh exit code: 0=unlimited, 1=throttled(1), 2=paused(0)
#   2. orchestration.max_agents config value (caps unlimited when set)
#   3. CLAUDE_CONTEXT_WINDOW_USAGE env var (>= 0.90 forces cap to 1)
#
# Precedence:
#   - Paused (exit 2) always wins → "0"
#   - Context window >= 90% → cap to "1"
#   - Config cap: min(verdict, config) when both are numeric
#   - No config + unlimited verdict → "unlimited"
#
# Output (stdout): a single bare string — "unlimited", "N", or "0"
_compute_max_agents() {
    # Step 1: Call check-usage.sh (resolved via PATH) and capture exit code
    local usage_exit=0
    check-usage.sh >/dev/null 2>&1 || usage_exit=$?

    # Step 2: Map exit code to verdict
    local verdict
    case "$usage_exit" in
        0) verdict="unlimited" ;;
        1) verdict="1" ;;
        2) verdict="0" ;;
        *) verdict="unlimited" ;;  # unknown exit → safe fallback
    esac

    # Step 3: Paused always wins regardless of anything else
    if [ "$verdict" = "0" ]; then
        echo "0"
        return 0
    fi

    # Step 4: Context window usage override (>= 0.90 → cap to 1)
    if [ -n "${CLAUDE_CONTEXT_WINDOW_USAGE:-}" ]; then
        local is_high
        is_high=$(awk -v u="${CLAUDE_CONTEXT_WINDOW_USAGE}" 'BEGIN { print (u >= 0.90) ? 1 : 0 }' 2>/dev/null || echo 0)
        if [ "$is_high" = "1" ]; then
            # Context pressure caps at 1, regardless of usage verdict
            echo "1"
            return 0
        fi
    fi

    # Step 5: Read orchestration.max_agents config
    local config_cap
    config_cap=$(_read_cfg "orchestration.max_agents")

    # Step 6: Apply config cap
    if [ -n "$config_cap" ]; then
        # Validate config_cap is a positive integer
        if ! [[ "$config_cap" =~ ^[0-9]+$ ]] || [ "$config_cap" -eq 0 ]; then
            # Invalid or zero config → ignore, treat as unset
            echo "$verdict"
            return 0
        fi
        if [ "$verdict" = "unlimited" ]; then
            # Config caps unlimited → use config value
            echo "$config_cap"
        else
            # Both are numeric: min(verdict, config) wins
            local v_num="$verdict"
            if [ "$config_cap" -lt "$v_num" ] 2>/dev/null; then
                echo "$config_cap"
            else
                echo "$v_num"
            fi
        fi
    else
        # No config cap → pass through verdict as-is
        echo "$verdict"
    fi

    return 0
}

# Resolve APP_DIR from config (paths.app_dir, relative to REPO_ROOT)
_app_dir() {
    local rel
    rel=$(_read_cfg "paths.app_dir")
    if [ -n "$rel" ]; then
        echo "$REPO_ROOT/$rel"
    else
        echo "$REPO_ROOT"
    fi
}

# ─── pre-check ───────────────────────────────────────────────────────────────
#
# Runs ALL pre-batch safety checks. Outputs structured report.
# Used by: debug-everything Phase G, /dso:sprint Phase 4
#
# Options:
#   --db    Also check database status (for DB-dependent batches)
#
# Output:
#   MAX_AGENTS: unlimited | N | 0
#   SESSION_USAGE: normal | high | critical
#   GIT_CLEAN: true | false
#   DB_STATUS: running | stopped | skipped
#
# Exit 0 if all checks pass, 1 if any require action (details in output).

cmd_pre_check() {
    local check_db=false
    for arg in "$@"; do
        case "$arg" in
            --db) check_db=true ;;
        esac
    done

    local any_fail=false

    # Rate-limit sentinel override: if a recent sentinel exists (<5 min),
    # force MAX_AGENTS to 1 regardless of check-usage.sh verdict.
    local sentinel_override=false
    if [ -f "$_RL_SENTINEL" ]; then
        local sentinel_age_s=0
        local sentinel_ts now_ts
        sentinel_ts=$(cat "$_RL_SENTINEL" 2>/dev/null || echo "")
        now_ts=$(date '+%s')
        if [ -n "$sentinel_ts" ] && [ "$sentinel_ts" -gt 0 ] 2>/dev/null; then
            # Sentinel contains a unix timestamp — use it directly
            sentinel_age_s=$(( now_ts - sentinel_ts ))
        else
            # Sentinel exists but no valid timestamp — use file mtime
            # stat -f%m works on macOS; stat -c%Y works on Linux
            local mtime
            mtime=$(stat -f%m "$_RL_SENTINEL" 2>/dev/null || stat -c%Y "$_RL_SENTINEL" 2>/dev/null || echo 0)
            sentinel_age_s=$(( now_ts - mtime ))
        fi
        if [ "$sentinel_age_s" -le 300 ]; then
            sentinel_override=true
        else
            # TTL expired — remove stale sentinel
            rm -f "$_RL_SENTINEL"
        fi
    fi

    # Session usage — 3-tier protocol via _compute_max_agents()
    local max_agents
    if $sentinel_override; then
        max_agents="1"
    else
        max_agents=$(_compute_max_agents)
    fi
    local usage="normal"
    case "$max_agents" in
        unlimited) usage="normal" ;;
        0)         usage="critical" ;;
        *)         usage="high" ;;
    esac
    echo "MAX_AGENTS: $max_agents"
    echo "SESSION_USAGE: $usage"

    # Clean working tree
    local dirty_files
    dirty_files=$(git status --short 2>/dev/null || true)
    if [ -n "$dirty_files" ]; then
        echo "GIT_CLEAN: false"
        echo "GIT_DIRTY_FILES: $(echo "$dirty_files" | wc -l | tr -d ' ')"
        any_fail=true
    else
        echo "GIT_CLEAN: true"
    fi

    # DB status (optional) — read-config.sh database.status_cmd
    if $check_db; then
        local db_status_cmd
        db_status_cmd=$(_read_cfg "database.status_cmd")
        if [ -z "$db_status_cmd" ]; then
            # No database config — graceful no-op
            echo "WARN: pre-check --db skipped — database not configured" >&2
            echo "DB_STATUS: skipped"
        elif (cd "$(_app_dir)" && eval "$db_status_cmd" >/dev/null 2>&1); then
            echo "DB_STATUS: running"
        else
            echo "DB_STATUS: stopped"
            any_fail=true
        fi
    else
        echo "DB_STATUS: skipped"
    fi

    if $any_fail; then
        return 1
    fi
    return 0
}

# ─── file-overlap ────────────────────────────────────────────────────────────
#
# Detects file-level conflicts between multiple agents' modifications.
# Used by: debug-everything Phase H Step 4, /dso:sprint Phase 6 Step 1a
#
# Usage:
#   agent-batch-lifecycle.sh file-overlap agent1.files agent2.files [agent3.files ...]
#
# Each input file contains one file path per line (the files that agent modified).
# Alternatively, pass file lists as arguments with agent labels:
#   agent-batch-lifecycle.sh file-overlap --agent=task-1:file1,file2 --agent=task-2:file2,file3
#
# Output:
#   CONFLICTS: 0 | <N>
#   (for each conflict):
#   CONFLICT: <file> PRIMARY=<agent> SECONDARY=<agent1>,<agent2>
#
# Exit 0 if no conflicts, 1 if conflicts detected.

cmd_file_overlap() {
    # Build a flat list of "file|agent" pairs using a temp file (bash 3 compatible)
    local tmpfile
    tmpfile=$(mktemp /tmp/file-overlap.XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    local agent_count=0

    for arg in "$@"; do
        case "$arg" in
            --agent=*)
                local spec="${arg#--agent=}"
                local label="${spec%%:*}"
                local files="${spec#*:}"
                agent_count=$((agent_count + 1))
                # Write one line per file: "file|agent"
                echo "$files" | tr ',' '\n' | while IFS= read -r f; do
                    [ -z "$f" ] && continue
                    echo "$f|$label"
                done >> "$tmpfile"
                ;;
            *)
                if [ -f "$arg" ]; then
                    local label
                    label=$(basename "$arg" .files)
                    agent_count=$((agent_count + 1))
                    while IFS= read -r f; do
                        [ -z "$f" ] && continue
                        echo "$f|$label"
                    done < "$arg" >> "$tmpfile"
                fi
                ;;
        esac
    done

    if [ "$agent_count" -lt 2 ]; then
        echo "CONFLICTS: 0"
        return 0
    fi

    # Sort by file, then detect duplicates (same file, different agents)
    # For each file appearing 2+ times, first agent is primary
    # Outputs CONFLICTS: line first, then individual CONFLICT: lines
    sort -t'|' -k1,1 "$tmpfile" | awk -F'|' '
    {
        if ($1 == prev_file) {
            agents = agents "," $2
            count++
        } else {
            if (count > 1) {
                primary = substr(agents, 1, index(agents, ",") - 1)
                secondary = substr(agents, index(agents, ",") + 1)
                lines[++n] = "CONFLICT: " prev_file " PRIMARY=" primary " SECONDARY=" secondary
                conflicts++
            }
            prev_file = $1
            agents = $2
            count = 1
        }
    }
    END {
        if (count > 1) {
            primary = substr(agents, 1, index(agents, ",") - 1)
            secondary = substr(agents, index(agents, ",") + 1)
            lines[++n] = "CONFLICT: " prev_file " PRIMARY=" primary " SECONDARY=" secondary
            conflicts++
        }
        print "CONFLICTS: " conflicts + 0
        for (i = 1; i <= n; i++) print lines[i]
    }
    '

    # Return based on whether conflicts exist
    local has_conflicts
    has_conflicts=$(sort -t'|' -k1,1 "$tmpfile" | awk -F'|' '
    { if ($1 == prev) { found=1; exit } prev=$1 }
    END { print found+0 }
    ')
    return "$has_conflicts"
}

# ─── lock-acquire ────────────────────────────────────────────────────────────
#
# Acquires a ticket-CLI-based session lock. Used by debug-everything Phase B ONLY.
#
# Usage:
#   agent-batch-lifecycle.sh lock-acquire "debug-everything"
#
# Output:
#   LOCK_ID: <ticket-id>       (on success)
#   LOCK_BLOCKED: <ticket-id>  (if another session holds it)
#   LOCK_STALE: <ticket-id>    (reclaimed stale lock, then acquired new one)
#
# Exit 0 on acquire, 1 if blocked.

cmd_lock_acquire() {
    local label="${1:?Missing lock label}"

    # Check for existing lock using ticket CLI (v3): list all tickets, find open OR
    # in_progress lock tasks matching the label. Checking both statuses eliminates the
    # TOCTOU race window where a ticket is created (open) but not yet transitioned to
    # in_progress — two sessions could otherwise both see no in_progress lock and both
    # create duplicates.
    local lock_id=""
    # shellcheck disable=SC2030,SC2031
    # LOCK_LABEL is intentionally exported within the subshell so the python heredoc can read it.
    # The export does not need to persist outside the subshell.
    lock_id=$(export LOCK_LABEL="$label"; "$TICKET_CMD" list 2>/dev/null | python3 -c "
import json, sys, os
label = os.environ.get('LOCK_LABEL', '')
tickets = json.load(sys.stdin)
for t in tickets:
    if (t.get('ticket_type') == 'task'
            and t.get('status') in ('open', 'in_progress')
            and t.get('title', '') == '[LOCK] ' + label):
        print(t['ticket_id'])
        break
" 2>/dev/null || echo "")

    if [ -n "$lock_id" ]; then
        # Check if the lock's worktree still exists by reading ticket notes via ticket CLI
        local notes
        notes=$("$TICKET_CMD" show "$lock_id" 2>/dev/null | python3 -c "
import json, sys
t = json.load(sys.stdin)
for c in t.get('comments', []):
    body = c.get('body', '')
    if 'Worktree: ' in body:
        for part in body.split('|'):
            part = part.strip()
            if part.startswith('Worktree: '):
                print(part[len('Worktree: '):].strip())
                break
        break
" 2>/dev/null || echo "")
        if [ -n "$notes" ] && [ -d "$notes" ]; then
            # Live lock — blocked
            echo "LOCK_BLOCKED: $lock_id"
            echo "LOCK_WORKTREE: $notes"
            return 1
        else
            # Stale lock — reclaim (comment before close)
            "$TICKET_CMD" comment "$lock_id" "Stale lock — worktree no longer exists" 2>/dev/null || true
            # Read current status (ticket show) before: ticket transition <id> <current> closed
            local current_status
            current_status=$("$TICKET_CMD" show "$lock_id" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','in_progress'))" 2>/dev/null || echo "in_progress")
            "$TICKET_CMD" transition "$lock_id" "$current_status" closed 2>/dev/null || true
            echo "LOCK_STALE: $lock_id"
        fi
    fi

    # Create new lock using v3 ticket CLI (ticket create task "<title>")
    local new_id
    new_id=$("$TICKET_CMD" create task "[LOCK] $label" 2>&1 | tr -d '[:space:]')

    if [ -z "$new_id" ] || echo "$new_id" | grep -qiE 'error|fail'; then
        echo "ERROR: Failed to create lock ticket"
        echo "OUTPUT: $new_id"
        return 1
    fi

    # Read current status before transitioning to in_progress
    local new_status
    new_status=$("$TICKET_CMD" show "$new_id" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','open'))" 2>/dev/null || echo "open")
    "$TICKET_CMD" transition "$new_id" "$new_status" in_progress 2>/dev/null || true
    "$TICKET_CMD" comment "$new_id" "Session: $(date -Iseconds) | Worktree: $REPO_ROOT" 2>/dev/null || true

    echo "LOCK_ID: $new_id"
    return 0
}

# ─── lock-release ────────────────────────────────────────────────────────────
#
# Releases a tk-based session lock. Used by debug-everything Phase K ONLY.
#
# Usage:
#   agent-batch-lifecycle.sh lock-release <lock-ticket-id> [reason]

cmd_lock_release() {
    local lock_id="${1:?Missing lock ticket ID}"
    local reason="${2:-Session complete}"
    local label="${3:-}"

    # Comment before close (ticket CLI rejects comments on closed tickets)
    "$TICKET_CMD" comment "$lock_id" "Closed: $reason" 2>/dev/null || true
    # Read current status before transitioning to closed
    local current_status
    current_status=$("$TICKET_CMD" show "$lock_id" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','in_progress'))" 2>/dev/null || echo "in_progress")
    "$TICKET_CMD" transition "$lock_id" "$current_status" closed 2>/dev/null || true
    echo "LOCK_RELEASED: $lock_id"

    # Sweep: close all remaining orphaned LOCK tickets for this label.
    # Orphaned tickets accumulate from crashed sessions or TOCTOU races.
    # If no label provided, derive it from the ticket title.
    local sweep_label="$label"
    if [ -z "$sweep_label" ]; then
        sweep_label=$("$TICKET_CMD" show "$lock_id" 2>/dev/null | python3 -c "
import json, sys
t = json.load(sys.stdin)
title = t.get('title', '')
if title.startswith('[LOCK] '):
    print(title[len('[LOCK] '):])
" 2>/dev/null || echo "")
    fi

    if [ -n "$sweep_label" ]; then
        local _orphan_ids
        # Collect orphaned open tickets
        _orphan_ids=$(export SWEEP_LABEL="$sweep_label" SWEEP_LOCK_ID="$lock_id"; {
            "$TICKET_CMD" list --status=open 2>/dev/null || echo "[]"
            "$TICKET_CMD" list --status=in_progress 2>/dev/null || echo "[]"
        } | python3 -c "
import json, sys, os
label = os.environ.get('SWEEP_LABEL', '')
exclude_id = os.environ.get('SWEEP_LOCK_ID', '')
all_tickets = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        all_tickets.extend(json.loads(line))
    except Exception:
        pass
seen = set()
for t in all_tickets:
    tid = t.get('ticket_id', '')
    if (t.get('ticket_type') == 'task'
            and t.get('status') in ('open', 'in_progress')
            and t.get('title', '') == '[LOCK] ' + label
            and tid != exclude_id
            and tid not in seen):
        seen.add(tid)
        print(tid)
" 2>/dev/null || true)

        local _orphan_id
        while IFS= read -r _orphan_id; do
            [ -z "$_orphan_id" ] && continue
            local _orphan_status
            _orphan_status=$("$TICKET_CMD" show "$_orphan_id" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','open'))" 2>/dev/null || echo "open")
            "$TICKET_CMD" comment "$_orphan_id" "Stale lock swept by lock-release: $reason" 2>/dev/null || true
            "$TICKET_CMD" transition "$_orphan_id" "$_orphan_status" closed \
                --reason="Fixed: stale LOCK ticket swept by lock-release" 2>/dev/null || true
        done <<< "$_orphan_ids"
    fi

    return 0
}

# ─── lock-status ─────────────────────────────────────────────────────────────
#
# Check if a session lock exists.
#
# Usage:
#   agent-batch-lifecycle.sh lock-status "debug-everything"
#
# Exit 0 always (not an error condition). Outputs:
#   LOCKED: <ticket-id>   — lock is held
#   UNLOCKED              — no lock exists

cmd_lock_status() {
    local label="${1:?Missing lock label}"

    # Query ticket CLI (v3) for in_progress lock tasks matching the label
    local lock_id=""
    # shellcheck disable=SC2030,SC2031
    # LOCK_LABEL is intentionally exported within the subshell so the python heredoc can read it.
    # The export does not need to persist outside the subshell.
    lock_id=$(export LOCK_LABEL="$label"; "$TICKET_CMD" list 2>/dev/null | python3 -c "
import json, sys, os
label = os.environ.get('LOCK_LABEL', '')
tickets = json.load(sys.stdin)
for t in tickets:
    if (t.get('ticket_type') == 'task'
            and t.get('status') == 'in_progress'
            and t.get('title', '') == '[LOCK] ' + label):
        print(t['ticket_id'])
        break
" 2>/dev/null || echo "")

    if [ -n "$lock_id" ]; then
        echo "LOCKED: $lock_id"
        return 0
    fi

    echo "UNLOCKED"
    return 0
}

# ─── cleanup-stale-containers ────────────────────────────────────────────────
#
# Removes Docker containers for worktrees that no longer exist.
# Container name prefix and compose project prefix read from config.
#
# Usage:
#   agent-batch-lifecycle.sh cleanup-stale-containers
#
# Output:
#   STALE_CLEANED: <N>
#   (for each cleaned container):
#   CLEANED: <container-name>
#
# Exit 0 always (cleanup is best-effort).

cmd_cleanup_stale_containers() {
    local worktrees_parent
    worktrees_parent=$(dirname "$REPO_ROOT")
    local cleaned=0

    # Read container naming from config via read-config.sh infrastructure.container_prefix
    local container_prefix
    container_prefix=$(_read_cfg "infrastructure.container_prefix")
    # read-config.sh infrastructure.compose_project
    local compose_prefix
    compose_prefix=$(_read_cfg "infrastructure.compose_project")

    if [ -z "$container_prefix" ]; then
        # No infrastructure config — graceful no-op
        echo "WARN: cleanup-stale-containers skipped — infrastructure not configured" >&2
        echo "STALE_CLEANED: 0"
        return 0
    fi

    # Find all running or stopped containers matching the worktree naming pattern
    local containers
    containers=$(docker ps -a --filter "name=$container_prefix" --format "{{.Names}}" 2>/dev/null || true)

    if [ -z "$containers" ]; then
        echo "STALE_CLEANED: 0"
        return 0
    fi

    while IFS= read -r container_name; do
        [ -z "$container_name" ] && continue
        # Extract worktree dir name by stripping the container prefix
        # Strip the container prefix to get the worktree directory name
        local worktree_dir
        worktree_dir="${container_name#"$container_prefix"}"
        local worktree_path="$worktrees_parent/$worktree_dir"

        if [ ! -d "$worktree_path" ]; then
            # Also stop the compose project to clean up networks/volumes
            if [ -n "$compose_prefix" ]; then
                local compose_project="${compose_prefix}${worktree_dir}"
                docker compose -p "$compose_project" down --remove-orphans 2>/dev/null || true
            fi
            # Fallback: force-remove the container if compose down didn't get it
            if docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$" 2>/dev/null; then
                docker rm -f "$container_name" 2>/dev/null || true
            fi
            echo "CLEANED: $container_name"
            cleaned=$((cleaned + 1))
        fi
    done <<< "$containers"

    echo "STALE_CLEANED: $cleaned"
    return 0
}

# ─── cleanup-discoveries ────────────────────────────────────────────────────
#
# Removes all files in .agent-discoveries/ and ensures the directory exists.
# Idempotent — safe when directory is empty or doesn't exist.
#
# Usage:
#   agent-batch-lifecycle.sh cleanup-discoveries
#
# Output:
#   DISCOVERIES_CLEANED: <N>
#
# Exit 0 always (cleanup is best-effort).

cmd_cleanup_discoveries() {
    # Resolve discoveries dir via get_artifacts_dir (same source of truth as collect-discoveries.sh).
    # AGENT_DISCOVERIES_DIR env var overrides for test isolation.
    #
    # Defensive plugin-root resolution: CLAUDE_PLUGIN_ROOT may point to the main repo
    # root instead of the plugin subdirectory (e.g., ${CLAUDE_PLUGIN_ROOT}) when called from a
    # host project via the dso shim. Validate using plugin.json (always present in the
    # plugin dir) and fall back to $SCRIPT_DIR/.. (the plugin dir relative to this script).
    local _plugin_root="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
    [[ ! -f "${_plugin_root}/plugin.json" ]] && _plugin_root="$SCRIPT_DIR/.."
    local _deps_sh="${_plugin_root}/hooks/lib/deps.sh"
    if [ -f "$_deps_sh" ]; then
        # shellcheck source=hooks/lib/deps.sh
        source "$_deps_sh"
    fi
    local discoveries_dir="${AGENT_DISCOVERIES_DIR:-$(get_artifacts_dir)/agent-discoveries}"
    local cleaned=0

    # Remove existing discovery files (JSON artifacts from previous batch)
    if [ -d "$discoveries_dir" ]; then
        local count
        count=$(find "$discoveries_dir" -maxdepth 1 -type f -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            rm -f "$discoveries_dir"/*.json
            cleaned=$count
        fi
    fi

    # Ensure directory exists so agents can write to it immediately
    mkdir -p "$discoveries_dir"

    echo "DISCOVERIES_CLEANED: $cleaned"
    return 0
}

# ─── preflight ────────────────────────────────────────────────────────────────
#
# Pre-flight infrastructure check. Verifies Docker Desktop is running and
# optionally starts the database. Run BEFORE launching diagnostic sub-agents
# that need E2E tests or DB access.
#
# Usage:
#   agent-batch-lifecycle.sh preflight [--start-db]
#
# Options:
#   --start-db    If DB is not running, attempt to start it (up to 30s wait)
#
# Output:
#   DOCKER_STATUS: running | not_running
#   STALE_CLEANED: <N>  (from stale container cleanup)
#   DB_STATUS: running | stopped | started | failed_to_start | skipped
#
# Exit 0 if all checks pass, 1 if any check fails.

cmd_preflight() {
    local start_db=false
    for arg in "$@"; do
        case "$arg" in
            --start-db) start_db=true ;;
        esac
    done

    local any_fail=false
    local docker_running=false

    # 1. Docker Desktop check
    if docker info &>/dev/null; then
        echo "DOCKER_STATUS: running"
        docker_running=true
    else
        echo "DOCKER_STATUS: not_running"
        # Docker not running is only a hard failure when --start-db is given AND
        # a database is actually configured. Without a DB configured, Docker status
        # is informational only (tools like cleanup-stale-containers skip gracefully).
        if $start_db && [ -n "$(_read_cfg "database.status_cmd")" ]; then
            any_fail=true
        fi
    fi

    # 1b. Clean up stale worktree containers (only if Docker is running)
    if $docker_running; then
        cmd_cleanup_stale_containers
    fi

    # 1c. Clean up agent discoveries from previous batch
    cmd_cleanup_discoveries

    # 1d. Run env check command if configured (commands.env_check_cmd in dso-config.conf)
    local env_check_cmd
    env_check_cmd=$(_read_cfg "commands.env_check_cmd")
    if [ -n "$env_check_cmd" ]; then
        if ! eval "$env_check_cmd" >/dev/null 2>/dev/null; then
            echo "ENV_CHECK: failed"
            any_fail=true
        else
            echo "ENV_CHECK: passed"
        fi
    else
        echo "ENV_CHECK: skipped (not configured)"
    fi


    # 2. Database
    if $start_db; then
        # Check if database config exists before attempting any DB operations
        local db_status_cmd
        db_status_cmd=$(_read_cfg "database.status_cmd")
        if [ -z "$db_status_cmd" ]; then
            # No database config — graceful no-op
            echo "WARN: preflight --start-db skipped — database not configured" >&2
            echo "DB_STATUS: skipped"
        else
            local app_dir
            app_dir=$(_app_dir)

            # Resolve worktree DB port via config-driven port command
            local db_port="5432"
            local wt_name
            wt_name=$(basename "$REPO_ROOT")
            local port_cmd
            port_cmd=$(_read_cfg "database.port_cmd")
            if [ -f "$REPO_ROOT/.git" ] && [ -n "$port_cmd" ]; then
                # port_cmd is relative to repo root
                local port_script="$REPO_ROOT/$port_cmd"
                if [ -x "$port_script" ]; then
                    db_port=$("$port_script" "$wt_name" db 2>/dev/null || echo "5432")
                fi
            fi

            # Check if DB port is already listening (e.g., started by claude-safe's
            # `make start` which brings up its own DB via docker-compose.yml).
            # Skip DB ensure to avoid port conflict between the two compose stacks.
            if lsof -i :"$db_port" -sTCP:LISTEN >/dev/null 2>&1; then
                echo "DB_STATUS: running (port $db_port already listening)"
            elif (cd "$app_dir" && eval "$db_status_cmd" >/dev/null 2>&1); then
                echo "DB_STATUS: running"
            else
                echo "DB_STATUS: stopped"
                echo "DB_ACTION: starting"
                # Use read-config.sh database.ensure_cmd from config (combines start + wait)
                local db_ensure_cmd
                db_ensure_cmd=$(_read_cfg "database.ensure_cmd")
                if [ -n "$db_ensure_cmd" ]; then
                    (cd "$app_dir" && eval "$db_ensure_cmd" 2>&1) || true
                fi
                # Verify DB came up
                if (cd "$app_dir" && eval "$db_status_cmd" >/dev/null 2>&1); then
                    echo "DB_STATUS: started"
                else
                    echo "DB_STATUS: failed_to_start"
                    any_fail=true
                fi
            fi
        fi
    else
        echo "DB_STATUS: skipped"
    fi

    if $any_fail; then
        return 1
    fi
    return 0
}

# ─── context-check ───────────────────────────────────────────────────────────
#
# Checks the current session context window usage level.
# Used by: /dso:sprint Phase 6 Step 7b (proactive compaction between batches)
#
# Detection strategy:
#   1. First consult CLAUDE_CONTEXT_WINDOW_USAGE env var (fraction 0.0–1.0, set by some Claude Code
#      versions); if it indicates medium or high usage, that level is used directly.
#   2. Then consult session.usage_check_cmd from config (signals >90%),
#      which can escalate a "low" result from the env var if it detects higher usage; otherwise
#      the level stays at "low" — Claude's own self-assessment in the skill drives the decision.
#
# Output:
#   CONTEXT_LEVEL: normal — <70%, no action needed
#   CONTEXT_LEVEL: medium — 70–90%, compact before next batch
#   CONTEXT_LEVEL: high   — >90%, compact and limit to 1 agent
#
# Exit codes (non-standard — these are NOT error codes):
#   0  = normal (no compaction needed)
#   10 = medium (compaction recommended)
#   11 = high (compaction recommended, limit agents)
# Callers should check specific codes rather than testing for non-zero.

cmd_context_check() {
    local level="normal"

    # Method 1: CLAUDE_CONTEXT_WINDOW_USAGE env var (fraction, 0.0–1.0)
    if [ -n "${CLAUDE_CONTEXT_WINDOW_USAGE:-}" ]; then
        local is_high is_medium
        # Use awk -v to avoid injection via the env var value
        is_high=$(awk -v u="${CLAUDE_CONTEXT_WINDOW_USAGE}" 'BEGIN { print (u >= 0.90) ? 1 : 0 }' 2>/dev/null || echo 0)
        is_medium=$(awk -v u="${CLAUDE_CONTEXT_WINDOW_USAGE}" 'BEGIN { print (u >= 0.70) ? 1 : 0 }' 2>/dev/null || echo 0)
        if [ "$is_high" = "1" ]; then
            level="high"
        elif [ "$is_medium" = "1" ]; then
            level="medium"
        fi
    fi

    # Method 2: Session usage check from config (can escalate "low" to "high"; skipped if already medium/high).
    # Convention: exit 0 = usage IS high (>90%), exit non-zero = normal.
    if [ "$level" = "normal" ]; then
        local usage_check_cmd
        usage_check_cmd=$(_read_cfg "session.usage_check_cmd")
        if [ -n "$usage_check_cmd" ] && [ -x "$usage_check_cmd" ]; then
            if "$usage_check_cmd" 2>/dev/null; then
                level="high"
            fi
        fi
    fi

    echo "CONTEXT_LEVEL: $level"

    case "$level" in
        medium) return 10 ;;  # 10 = compaction recommended
        high)
            echo "MAX_AGENTS: 1"
            return 11 ;;  # 11 = compaction recommended, limit agents
        *)      return 0 ;;   #  0 = no compaction needed
    esac
}

# ─── check-error ─────────────────────────────────────────────────────────────
#
# Convenience subcommand: reads result text from stdin or first argument,
# calls _check_rate_limit_error(), and outputs CHECK_ERROR: match|no_match.
#
# Usage:
#   echo "some error text" | agent-batch-lifecycle.sh check-error
#   agent-batch-lifecycle.sh check-error "some error text"
#
# Exit 0 always.

cmd_check_error() {
    local text="${1:-}"
    if [ -z "$text" ] && [ ! -t 0 ]; then
        text=$(cat)
    fi
    if _check_rate_limit_error "$text"; then
        echo "CHECK_ERROR: match"
    else
        echo "CHECK_ERROR: no_match"
    fi
    return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

CMD="${1:-}"
shift || true

case "$CMD" in
    pre-check)      cmd_pre_check "$@" ;;
    preflight)      cmd_preflight "$@" ;;
    file-overlap)   cmd_file_overlap "$@" ;;
    context-check)  cmd_context_check "$@" ;;
    lock-acquire)               cmd_lock_acquire "$@" ;;
    lock-release)               cmd_lock_release "$@" ;;
    lock-status)                cmd_lock_status "$@" ;;
    cleanup-stale-containers)   cmd_cleanup_stale_containers "$@" ;;
    cleanup-discoveries)        cmd_cleanup_discoveries "$@" ;;
    check-error)                cmd_check_error "$@" ;;
    *)
        echo "Usage: agent-batch-lifecycle.sh {pre-check|preflight|file-overlap|context-check|check-error|lock-acquire|lock-release|lock-status|cleanup-stale-containers|cleanup-discoveries}"
        echo ""
        echo "Subcommands:"
        echo "  pre-check [--db]                     Pre-batch safety checks"
        echo "  preflight [--start-db]               Pre-flight Docker & DB check"
        echo "  file-overlap --agent=id:f1,f2 ...    Detect file conflicts between agents"
        echo "  context-check                        Check context window usage level (exit 0=low, 10=medium, 11=high)"
        echo "  check-error [text]                    Check result text for rate-limit errors (stdin or argument)"
        echo "  lock-acquire <label>                  Acquire session lock"
        echo "  lock-release <id> [reason]            Release session lock"
        echo "  lock-status <label>                   Check if session lock exists"
        echo "  cleanup-stale-containers              Remove Docker containers for deleted worktrees"
        echo "  cleanup-discoveries                   Remove agent discovery files and ensure directory exists"
        exit 2
        ;;
esac
