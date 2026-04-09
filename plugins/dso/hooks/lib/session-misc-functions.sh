#!/usr/bin/env bash
# hooks/lib/session-misc-functions.sh
# Sourceable function definitions for misc hook dispatchers.
#
# Each function follows the hook contract:
#   Input:  JSON string passed as $1
#   Return 0: allow — continue to next hook
#   Return 2: block/deny — dispatcher stops, outputs permissionDecision
#   stderr: warnings (always allowed; passed through by dispatcher)
#   stdout: permissionDecision message (only consumed when return 2)
#
# Functions defined:
#   hook_inject_using_lockpick        — inject skill context at session start
#   hook_cleanup_stale_nohup          — reap stale/hung nohup processes from registry
#   hook_session_safety_check         — analyze hook error log and warn
#   hook_post_compact_review_check    — warn about review state after compaction
#   hook_review_stop_check            — warn about uncommitted unreviewed changes
#   hook_tool_logging_summary         — emit session tool usage summary on stop
#   hook_track_tool_errors            — track and categorize tool use errors
#   hook_plan_review_gate             — block ExitPlanMode without plan review
#   hook_brainstorm_gate              — block EnterPlanMode without brainstorm sentinel
#   hook_taskoutput_block_guard       — block TaskOutput calls with block=false
#
# Usage:
#   source hooks/lib/session-misc-functions.sh
#   hook_inject_using_lockpick "$INPUT_JSON"

# Guard: only load once
[[ "${_SESSION_MISC_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_SESSION_MISC_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_SESSION_MISC_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SESSION_MISC_FUNC_DIR/deps.sh"

# ---------------------------------------------------------------------------
# hook_cleanup_orphaned_processes
# ---------------------------------------------------------------------------
# SessionStart hook: kill nohup-orphaned processes older than 30 minutes.
# These accumulate from the nohup + file-based polling pattern (INC-016
# workaround) and never get cleaned up. Uses process age to avoid killing
# processes from concurrent sessions.
hook_cleanup_orphaned_processes() {
    local AGE_THRESHOLD_MIN=30
    local NOW_EPOCH
    NOW_EPOCH=$(date +%s)

    # Patterns for known nohup-orphaned commands
    local PATTERNS=(
        "timeout.*make.*test-e2e"
        "timeout.*make.*test-unit"
        "timeout.*make.*test-integration"
        "timeout.*validate\.sh"
    )

    local KILLED=0
    for pattern in "${PATTERNS[@]}"; do
        # Get PIDs matching the pattern (exclude grep itself)
        local PIDS
        PIDS=$(pgrep -f "$pattern" 2>/dev/null || true)
        if [[ -z "$PIDS" ]]; then
            continue
        fi

        for pid in $PIDS; do
            # Get process start time (elapsed seconds since start)
            local ELAPSED
            if [[ "$(uname)" == "Darwin" ]]; then
                # macOS: ps -o etime gives [[dd-]hh:]mm:ss
                local ETIME
                ETIME=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ') || continue
                # Skip if process vanished between pgrep and ps
                [[ -z "$ETIME" ]] && continue
                # Parse etime to seconds
                local DAYS=0 HOURS=0 MINS=0 SECS=0
                if [[ "$ETIME" == *-* ]]; then
                    DAYS="${ETIME%%-*}"
                    ETIME="${ETIME#*-}"
                fi
                # Count colons to determine format
                local COLON_COUNT
                COLON_COUNT=$(echo "$ETIME" | tr -cd ':' | wc -c | tr -d ' ')
                if [[ "$COLON_COUNT" -eq 2 ]]; then
                    HOURS=$(echo "$ETIME" | cut -d: -f1)
                    MINS=$(echo "$ETIME" | cut -d: -f2)
                    SECS=$(echo "$ETIME" | cut -d: -f3)
                elif [[ "$COLON_COUNT" -eq 1 ]]; then
                    MINS=$(echo "$ETIME" | cut -d: -f1)
                    SECS=$(echo "$ETIME" | cut -d: -f2)
                fi
                # Remove leading zeros
                DAYS=$((10#$DAYS)) HOURS=$((10#$HOURS)) MINS=$((10#$MINS)) SECS=$((10#$SECS))
                ELAPSED=$(( DAYS*86400 + HOURS*3600 + MINS*60 + SECS ))
            else
                # Linux: use /proc
                local START_TIME
                START_TIME=$(stat -c %Y "/proc/$pid" 2>/dev/null) || continue
                ELAPSED=$(( NOW_EPOCH - START_TIME ))
            fi

            local AGE_MIN=$(( ELAPSED / 60 ))
            if [[ "$AGE_MIN" -ge "$AGE_THRESHOLD_MIN" ]]; then
                # Resolve actual PGID — do not assume PID == PGID
                local ACTUAL_PGID
                ACTUAL_PGID=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || ACTUAL_PGID=""
                if [[ -n "$ACTUAL_PGID" && "$ACTUAL_PGID" =~ ^[0-9]+$ ]]; then
                    # Kill the process group using resolved PGID
                    kill -- -"$ACTUAL_PGID" 2>/dev/null || kill "$pid" 2>/dev/null || true
                else
                    # Fallback: kill individual process if PGID lookup fails
                    kill "$pid" 2>/dev/null || true
                fi
                KILLED=$((KILLED + 1))
            fi
        done
    done

    if [[ "$KILLED" -gt 0 ]]; then
        echo "Cleaned up $KILLED orphaned background process(es) older than ${AGE_THRESHOLD_MIN} minutes." >&2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_cleanup_stale_nohup
# ---------------------------------------------------------------------------
# SessionStart hook: scan the nohup PID registry and clean up stale/hung
# processes. Only kills processes that are registered in the registry AND
# whose command matches the entry metadata (PID recycling protection).
#
# Registry: /tmp/workflow-nohup-pids/*.entry (override via NOHUP_PID_REGISTRY)
# Entry format (line-oriented key=value):
#   pid=<PID>
#   command=<original command line>
#   started=<epoch seconds>
#
# Cleanup rules:
#   - Process not running (dead PID): remove entry file
#   - Process running >1h AND command matches: kill process, remove entry
#   - Process running but command does NOT match (PID recycled): remove entry only
#   - Process running <1h with matching command: leave alone
hook_cleanup_stale_nohup() {
    local REGISTRY="${NOHUP_PID_REGISTRY:-/tmp/workflow-nohup-pids}"
    local AGE_THRESHOLD_SEC=3600  # 1 hour
    local NOW_EPOCH
    NOW_EPOCH=$(date +%s)

    # No registry directory or no entry files — nothing to do
    if [[ ! -d "$REGISTRY" ]]; then
        return 0
    fi

    local ENTRY_FILES
    ENTRY_FILES=$(ls "$REGISTRY"/*.entry 2>/dev/null || true)
    if [[ -z "$ENTRY_FILES" ]]; then
        return 0
    fi

    local CLEANED=0
    local entry_file
    for entry_file in $ENTRY_FILES; do
        [[ -f "$entry_file" ]] || continue

        # Parse entry file
        local entry_pid="" entry_command="" entry_started=""
        while IFS='=' read -r key val; do
            case "$key" in
                pid) entry_pid="$val" ;;
                command) entry_command="$val" ;;
                started) entry_started="$val" ;;
            esac
        done < "$entry_file"

        # Skip malformed entries
        if [[ -z "$entry_pid" || ! "$entry_pid" =~ ^[0-9]+$ ]]; then
            rm -f "$entry_file"
            continue
        fi

        # Check if process is still running
        if ! kill -0 "$entry_pid" 2>/dev/null; then
            # Process is dead — remove entry
            rm -f "$entry_file"
            CLEANED=$((CLEANED + 1))
            continue
        fi

        # Process is alive — check command match (PID recycling protection)
        local actual_cmd
        actual_cmd=$(ps -o command= -p "$entry_pid" 2>/dev/null | head -1) || actual_cmd=""

        if [[ -z "$entry_command" || "$actual_cmd" != *"$entry_command"* && "$entry_command" != *"$actual_cmd"* ]]; then
            # Command mismatch — PID was recycled. Remove stale entry but don't kill.
            rm -f "$entry_file"
            CLEANED=$((CLEANED + 1))
            continue
        fi

        # Command matches — check age
        if [[ -n "$entry_started" && "$entry_started" =~ ^[0-9]+$ ]]; then
            local age=$(( NOW_EPOCH - entry_started ))
            if [[ "$age" -ge "$AGE_THRESHOLD_SEC" ]]; then
                # Process has been running too long — kill process group if leader
                local actual_pgid
                actual_pgid=$(ps -o pgid= -p "$entry_pid" 2>/dev/null | tr -d ' ') || actual_pgid=""
                if [[ -n "$actual_pgid" && "$actual_pgid" == "$entry_pid" ]]; then
                    # Process is the group leader (typical for nohup) — kill the group
                    kill -- -"$actual_pgid" 2>/dev/null || kill "$entry_pid" 2>/dev/null || true
                else
                    # Not a group leader — kill only the registered PID
                    kill "$entry_pid" 2>/dev/null || true
                fi
                rm -f "$entry_file"
                CLEANED=$((CLEANED + 1))
                continue
            fi
        fi

        # Process is alive, command matches, and under threshold — leave it
    done

    if [[ "$CLEANED" -gt 0 ]]; then
        echo "Cleaned up $CLEANED stale nohup process(es) from registry." >&2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_inject_using_lockpick
# ---------------------------------------------------------------------------
# SessionStart hook: inject using-lockpick skill context into conversation
hook_inject_using_lockpick() {
    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    local PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
    local HOOK_FILE="$PLUGIN_ROOT/skills/using-lockpick/HOOK-INJECTION.md"
    local SKILL_FILE="$PLUGIN_ROOT/skills/using-lockpick/SKILL.md"

    if [[ -f "$HOOK_FILE" ]]; then
        cat "$HOOK_FILE"
    elif [[ -f "$SKILL_FILE" ]]; then
        cat "$SKILL_FILE"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_session_safety_check
# ---------------------------------------------------------------------------
# SessionStart hook: analyze hook error log and create bugs for recurring errors
hook_session_safety_check() {
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    local THRESHOLD=10

    if [[ ! -f "$HOOK_ERROR_LOG" ]]; then
        return 0
    fi

    check_tool python3 || return 0

    local CUTOFF=""
    if [[ "$(uname)" == "Darwin" ]]; then
        CUTOFF=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    else
        CUTOFF=$(date -u -d "24 hours ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    fi

    if [[ -z "$CUTOFF" ]]; then
        return 0
    fi

    local COUNTS
    COUNTS=$(python3 -c "
import sys, json
cutoff = sys.argv[1]
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        ts = obj.get('ts', '')
        hook = obj.get('hook', '')
        if ts and ts >= cutoff and hook:
            print(hook)
    except (json.JSONDecodeError, KeyError):
        pass
" "$CUTOFF" < "$HOOK_ERROR_LOG" 2>/dev/null | sort | uniq -c | sort -rn || echo "")

    if [[ -z "$COUNTS" ]]; then
        return 0
    fi

    local WARNINGS=""
    while IFS= read -r line; do
        local COUNT HOOK_NAME
        COUNT=$(echo "$line" | awk '{print $1}')
        HOOK_NAME=$(echo "$line" | awk '{print $2}')

        if [[ -z "$COUNT" || -z "$HOOK_NAME" ]]; then
            continue
        fi

        if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
            continue
        fi

        if (( COUNT >= THRESHOLD )); then
            WARNINGS="${WARNINGS}\n  - ${HOOK_NAME}: ${COUNT} errors in last 24h"
        fi
    done <<< "$COUNTS"

    if [[ -n "$WARNINGS" ]]; then
        echo "# Hook Error Report"
        echo ""
        echo "The following hooks have exceeded the error threshold (${THRESHOLD}/24h):"
        echo -e "$WARNINGS"
        echo ""
        echo "Review: ~/.claude/hook-error-log.jsonl"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_post_compact_review_check
# ---------------------------------------------------------------------------
# SessionStart hook: fires after compaction to warn about review state integrity.
# NOTE: Uses python3 for JSON parsing (matches original hook behavior).
hook_post_compact_review_check() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"

    local SOURCE
    SOURCE=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('source',''))" 2>/dev/null || echo "")
    [[ "$SOURCE" != "compact" ]] && return 0

    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || return 0

    local HEAD_MSG
    HEAD_MSG=$(git log -1 --format="%s" 2>/dev/null || echo "")
    if [[ "$HEAD_MSG" != *"pre-compaction"* && "$HEAD_MSG" != *"checkpoint"* ]]; then
        return 0
    fi

    local CHECKPOINT_FILES
    CHECKPOINT_FILES=$(git show --name-only --format="" HEAD 2>/dev/null)

    local CONTAINS_REVIEWER_FINDINGS=false
    if echo "$CHECKPOINT_FILES" | grep -q "reviewer-findings.json"; then
        CONTAINS_REVIEWER_FINDINGS=true
    fi

    local ARTIFACTS_GLOB="/tmp/workflow-plugin-*/review-diff-*.txt"
    local REVIEW_DIFF_EXISTS=false
    # shellcheck disable=SC2086
    find /tmp -maxdepth 2 -path '/tmp/workflow-plugin-*/review-diff-*.txt' 2>/dev/null | head -1 | grep -q . && REVIEW_DIFF_EXISTS=true

    if [[ "$CONTAINS_REVIEWER_FINDINGS" == "true" ]]; then
        cat <<'WARNING'
POST-COMPACT REVIEW INTEGRITY WARNING

The pre-compaction checkpoint commit (HEAD) contains `reviewer-findings.json`.
This file must NOT be committed — it is a review artifact verified by hash.

If you try to call record-review.sh now, --expected-hash will be REJECTED
because the staged diff includes reviewer-findings.json, which shifts the hash.

REQUIRED — do this BEFORE recording any review or making new commits:

  git show --stat HEAD          # Confirm what was committed
  git reset HEAD~1 --mixed      # Unstage (keeps all file changes)
  git add <only-the-intended-files>
  # Then record the review, then re-commit

WARNING
    elif [[ "$REVIEW_DIFF_EXISTS" == "true" ]]; then
        cat <<'INFO'
POST-COMPACT RECOVERY: review was in progress before compaction.

A pre-compaction checkpoint commit exists at HEAD. Verify it before recording
any review result — unexpected staged files will cause --expected-hash to fail:

  git show --stat HEAD    # Confirm only intended files are in the checkpoint

If unexpected files are present: git reset HEAD~1 --mixed, restage only the
intended files, then record the review and re-commit.

INFO
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_review_stop_check
# ---------------------------------------------------------------------------
# Stop hook: warn when there are uncommitted code changes that haven't been reviewed.
hook_review_stop_check() {
    local HOOK_DIR="$CLAUDE_PLUGIN_ROOT/hooks"

    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    local CHANGED_FILES STAGED_FILES UNTRACKED_FILES
    CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null || true)
    STAGED_FILES=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null || true)
    UNTRACKED_FILES=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null || true)

    if [[ -z "$CHANGED_FILES" ]] && [[ -z "$STAGED_FILES" ]] && [[ -z "$UNTRACKED_FILES" ]]; then
        return 0
    fi

    local ARTIFACTS_DIR
    ARTIFACTS_DIR=$(get_artifacts_dir)
    local REVIEW_STATE_FILE="$ARTIFACTS_DIR/review-status"

    if [[ -f "$REVIEW_STATE_FILE" ]]; then
        local REVIEW_STATUS
        REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
        if [[ "$REVIEW_STATUS" == "passed" ]]; then
            local RECORDED_HASH CURRENT_HASH
            RECORDED_HASH=$(grep '^diff_hash=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
            CURRENT_HASH=$("$HOOK_DIR/compute-diff-hash.sh")
            if [[ "$RECORDED_HASH" == "$CURRENT_HASH" ]]; then
                return 0
            fi
        fi
    fi

    local TOTAL_CHANGED
    TOTAL_CHANGED=$(
        {
            echo "$CHANGED_FILES"
            echo "$STAGED_FILES"
            echo "$UNTRACKED_FILES"
        } | sort -u | grep -cv '^$'
    )

    if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
        echo "# REMINDER: Uncommitted changes not reviewed"
        echo ""
        echo "There are **${TOTAL_CHANGED} changed file(s)** that have not been code-reviewed."
        echo ""
        echo "Before completing this task, follow the Task Completion Workflow:"
        echo "  1. Run \`/dso:review\` to review your changes"
        echo "  2. Fix any issues (scores must be >= 4)"
        echo "  3. Commit and push"
        echo "  4. Wait for CI to pass"
        echo ""
        return 0
    fi

    local REVIEW_STATUS
    REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$REVIEW_STATUS" == "failed" ]]; then
        echo "# REMINDER: Last review did not pass"
        echo ""
        echo "There are **${TOTAL_CHANGED} changed file(s)** and the last review **failed**."
        echo ""
        echo "Fix review issues, re-run \`/dso:review\`, then commit."
        echo ""
        return 0
    fi

    echo "# REMINDER: Code changed since last review"
    echo ""
    echo "There are **${TOTAL_CHANGED} changed file(s)** modified after the last review."
    echo ""
    echo "Re-run \`/dso:review\` before committing."
    echo ""
    return 0
}

# ---------------------------------------------------------------------------
# hook_tool_logging_summary
# ---------------------------------------------------------------------------
# Stop hook: output a session summary of tool usage from the JSONL tool-use log.
hook_tool_logging_summary() {
    local HOOK_DIR="$CLAUDE_PLUGIN_ROOT/hooks"

    check_tool python3 || return 0

    if ! test -f "$HOME/.claude/tool-logging-enabled"; then
        return 0
    fi

    local SESSION_ID
    SESSION_ID=$(cat "$HOME/.claude/current-session-id" 2>/dev/null || echo "")
    if [[ -z "$SESSION_ID" ]]; then
        return 0
    fi

    local LOG_FILE
    LOG_FILE="$HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
    if [[ ! -f "$LOG_FILE" ]]; then
        return 0
    fi

    # Process all JSONL data in a single python3 invocation (mirrors tool-logging-summary.sh)
    local SUMMARY_DATA
    SUMMARY_DATA=$(python3 -c "
import json, sys
from collections import Counter

session_id = sys.argv[1]
log_file = sys.argv[2]

entries = []
with open(log_file) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if obj.get('session_id') == session_id:
            entries.append(obj)

if not entries:
    sys.exit(1)

post_entries = [e for e in entries if e.get('hook_type') == 'post']
total_calls = len(post_entries)

if total_calls < 10:
    print('BELOW_THRESHOLD')
    sys.exit(0)

tool_counter = Counter(e.get('tool_name', 'unknown') for e in post_entries)
tool_counts = sorted(tool_counter.items(), key=lambda x: (-x[1], x[0]))

all_epochs = sorted(e.get('epoch_ms', 0) for e in entries if e.get('epoch_ms'))
first_epoch = all_epochs[0] if all_epochs else 0
last_epoch = all_epochs[-1] if all_epochs else 0
duration_secs = max(0, (last_epoch - first_epoch) // 1000) if last_epoch > first_epoch else 0

pre_entries = [e for e in entries if e.get('hook_type') == 'pre']
slow_calls = []
for p in post_entries:
    tool = p.get('tool_name', '')
    post_epoch = p.get('epoch_ms', 0)
    candidates = [
        pr for pr in pre_entries
        if pr.get('tool_name') == tool and pr.get('epoch_ms', 0) <= post_epoch
    ]
    if candidates:
        best = max(candidates, key=lambda x: x.get('epoch_ms', 0))
        delta_ms = post_epoch - best.get('epoch_ms', 0)
        slow_calls.append((tool, delta_ms))

slow_calls.sort(key=lambda x: -x[1])
slow_calls = slow_calls[:5]

print('TOTAL_CALLS={}'.format(total_calls))
print('DURATION_SECS={}'.format(duration_secs))
for tool, count in tool_counts:
    print('TOOL_COUNT={}:{}'.format(tool, count))
for tool, delta_ms in slow_calls:
    print('SLOW_CALL={}:{}'.format(tool, delta_ms // 1000))
print('DONE')
" "$SESSION_ID" "$LOG_FILE" 2>/dev/null || echo "")

    if [[ -z "$SUMMARY_DATA" ]]; then
        # No entries for this session — return without cleanup (matches original jq behavior)
        return 0
    fi

    if [[ "$SUMMARY_DATA" == "BELOW_THRESHOLD" ]]; then
        find "$HOME/.claude/logs/" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true
        return 0
    fi

    # Parse structured output
    local TOTAL_CALLS="" DURATION_SECS=0
    local TOOL_COUNTS_LINES="" SLOW_CALLS_LINES=""

    while IFS= read -r line; do
        case "$line" in
            TOTAL_CALLS=*)
                TOTAL_CALLS="${line#TOTAL_CALLS=}"
                ;;
            DURATION_SECS=*)
                DURATION_SECS="${line#DURATION_SECS=}"
                ;;
            TOOL_COUNT=*)
                local _tc_data="${line#TOOL_COUNT=}"
                local _tc_tool="${_tc_data%%:*}"
                local _tc_count="${_tc_data#*:}"
                TOOL_COUNTS_LINES="${TOOL_COUNTS_LINES}  - ${_tc_tool}: ${_tc_count}"$'\n'
                ;;
            SLOW_CALL=*)
                local _sc_data="${line#SLOW_CALL=}"
                local _sc_tool="${_sc_data%%:*}"
                local _sc_secs="${_sc_data#*:}"
                SLOW_CALLS_LINES="${SLOW_CALLS_LINES}  - ${_sc_tool}: ${_sc_secs}s"$'\n'
                ;;
            DONE)
                break
                ;;
        esac
    done <<< "$SUMMARY_DATA"

    local DURATION_MIN=$(( DURATION_SECS / 60 ))
    local DURATION_SEC=$(( DURATION_SECS % 60 ))

    echo "# Session Tool Usage Summary"
    echo ""
    echo "**Session:** \`${SESSION_ID}\`"
    if [[ "$DURATION_MIN" -gt 0 || "$DURATION_SEC" -gt 0 ]]; then
        echo "**Duration:** ${DURATION_MIN}m ${DURATION_SEC}s"
    fi
    echo "**Total tool calls:** ${TOTAL_CALLS}"
    echo ""
    echo "## Calls by Tool"
    echo ""
    printf '%s' "$TOOL_COUNTS_LINES"
    echo ""
    if [[ -n "$SLOW_CALLS_LINES" ]]; then
        echo "## Top 5 Slowest Calls (approx)"
        echo ""
        printf '%s' "$SLOW_CALLS_LINES"
        echo ""
    fi

    find "$HOME/.claude/logs/" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# hook_track_tool_errors
# ---------------------------------------------------------------------------
# PostToolUseFailure hook: track, categorize, and count tool use errors
hook_track_tool_errors() {
    local _HOOK_LIB_DIR; _HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # PATH-ANCHOR: _HOOK_LIB_DIR is anchored to plugins/dso/hooks/lib/ (this file's directory).
    # read-config.sh lives in plugins/dso/scripts/, which is two levels up from hooks/lib/.  # shim-exempt: comment explaining path resolution
    # The naive relative path would be $_HOOK_LIB_DIR/../../scripts/read-config.sh (two "..").
    # However, this function resolves _PLUGIN_ROOT via CLAUDE_PLUGIN_ROOT (preferred) or by
    # walking up two directories from _HOOK_LIB_DIR, then uses $_PLUGIN_ROOT/scripts/read-config.sh.
    # This is equivalent to the two-".." form but more readable and robust to symlinks.
    # Contrast with track-tool-errors.sh (at hooks/, one level shallower): it uses one "..".
    # The 2>/dev/null || echo 'false' guard silently suppresses path errors — always verify:
    #   ls "$(dirname "$(dirname "${BASH_SOURCE[0]}")")/../../scripts/read-config.sh"
    local _PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
    if [[ -z "$_PLUGIN_ROOT" || ! -d "$_PLUGIN_ROOT/hooks/lib" ]]; then
        _PLUGIN_ROOT="$(cd "$(dirname "$(dirname "$_HOOK_LIB_DIR")")" && pwd)"
    fi
    local _MONITORING; _MONITORING="${DSO_MONITORING_TOOL_ERRORS:-$(bash "$_PLUGIN_ROOT/scripts/read-config.sh" monitoring.tool_errors 2>/dev/null || echo "false")}"
    [[ "$_MONITORING" != "true" ]] && return 0
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"

    check_tool python3 || return 0

    local TOOL_NAME ERROR_MSG TOOL_INPUT SESSION_ID IS_INTERRUPT
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    ERROR_MSG=$(parse_json_field "$INPUT" '.error')
    TOOL_INPUT=$(parse_json_object "$INPUT" '.tool_input')
    [[ -z "$TOOL_INPUT" ]] && TOOL_INPUT="{}"
    SESSION_ID=$(parse_json_field "$INPUT" '.session_id')
    IS_INTERRUPT=$(parse_json_field "$INPUT" '.is_interrupt')
    [[ -z "$IS_INTERRUPT" ]] && IS_INTERRUPT="false"

    if [[ "$IS_INTERRUPT" == "true" ]]; then
        return 0
    fi

    if [[ -z "$ERROR_MSG" ]]; then
        return 0
    fi

    local COUNTER_FILE="$HOME/.claude/tool-error-counter.json"
    local THRESHOLD=50

    if [[ ! -f "$COUNTER_FILE" ]]; then
        echo '{"index":{},"errors":[]}' > "$COUNTER_FILE"
    fi

    local CATEGORY="" INPUT_SUMMARY=""
    local ERROR_LOWER
    ERROR_LOWER=$(echo "$ERROR_MSG" | tr '[:upper:]' '[:lower:]')
    if echo "$ERROR_LOWER" | grep -qE "file not found|no such file"; then
        CATEGORY="file_not_found"
    elif echo "$ERROR_LOWER" | grep -q "permission denied"; then
        CATEGORY="permission_denied"
    elif echo "$ERROR_LOWER" | grep -q "command not found"; then
        CATEGORY="command_not_found"
    elif echo "$ERROR_LOWER" | grep -qE "old_string.*not unique|not found uniquely|is not unique in the file"; then
        CATEGORY="edit_string_not_unique"
    elif echo "$ERROR_LOWER" | grep -q "not found"; then
        CATEGORY="edit_string_not_found"
    elif echo "$ERROR_LOWER" | grep -qE "timed out|timedout|deadline exceeded|timeout exceeded"; then
        CATEGORY="timeout"
    elif echo "$ERROR_LOWER" | grep -qE "failed.*passed|passed.*failed|pytest|test session starts"; then
        CATEGORY="test_failure"
    elif echo "$ERROR_LOWER" | grep -qE "ruff|mypy|format-check"; then
        CATEGORY="lint_failure"
    elif echo "$ERROR_LOWER" | grep -q "syntax error"; then
        CATEGORY="syntax_error"
    elif echo "$ERROR_LOWER" | grep -qE "lock.*blocked|blocked.*lock"; then
        CATEGORY="lock_blocked"
    elif echo "$ERROR_LOWER" | grep -qE "validate.*issues|issues.*valid"; then
        CATEGORY="validate_issues_warning"
    elif echo "$ERROR_LOWER" | grep -qE "non-zero|exit code"; then
        CATEGORY="command_exit_nonzero"
    else
        CATEGORY=$(echo "${TOOL_NAME}_${ERROR_MSG}" | tr '[:upper:]' '[:lower:]' | tr -cs '[:alnum:]' '_' | sed 's/__*/_/g' | cut -d_ -f1-4 | head -c 50)
    fi

    INPUT_SUMMARY="$TOOL_NAME: $(json_summarize_input "$TOOL_INPUT" 2>/dev/null | head -c 120)"

    local TIMESTAMP
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local COUNTER_DATA
    COUNTER_DATA=$(cat "$COUNTER_FILE" 2>/dev/null || echo '{"index":{},"errors":[]}')

    # Guard against malformed JSON
    local _VALID
    _VALID=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert 'errors' in d" <<< "$COUNTER_DATA" 2>/dev/null && echo "ok" || echo "bad")
    if [[ "$_VALID" != "ok" ]]; then
        COUNTER_DATA='{"index":{},"errors":[]}'
    fi

    # Append error detail and increment index count in a single python3 call
    COUNTER_DATA=$(python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
cat = sys.argv[1]
tool = sys.argv[2]
summary = sys.argv[3]
error = sys.argv[4]
session = sys.argv[5]
ts = sys.argv[6]
next_id = len(data.get('errors', [])) + 1
data.setdefault('errors', []).append({
    'id': next_id,
    'timestamp': ts,
    'category': cat,
    'tool_name': tool,
    'input_summary': summary,
    'error_message': error,
    'session_id': session
})
data.setdefault('index', {})[cat] = data['index'].get(cat, 0) + 1
print(json.dumps(data))
" "$CATEGORY" "$TOOL_NAME" "$INPUT_SUMMARY" "$ERROR_MSG" "$SESSION_ID" "$TIMESTAMP" <<< "$COUNTER_DATA")

    echo "$COUNTER_DATA" > "$COUNTER_FILE"

    local CURRENT_COUNT
    CURRENT_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('index',{}).get(sys.argv[1],0))" "$CATEGORY" <<< "$COUNTER_DATA" 2>/dev/null || echo 0)

    local NOISE_CATEGORIES="file_not_found command_exit_nonzero"
    local IS_NOISE=false
    local nc
    for nc in $NOISE_CATEGORIES; do
        if [[ "$CATEGORY" == "$nc" ]]; then IS_NOISE=true; break; fi
    done

    if [[ "$IS_NOISE" == "true" ]]; then
        return 0
    fi

    if [[ "$CURRENT_COUNT" -ge "$THRESHOLD" ]] && (( CURRENT_COUNT % THRESHOLD == 0 )); then
        echo "Recurring tool error detected: '$CATEGORY' has occurred $CURRENT_COUNT times (threshold: $THRESHOLD). Review: $COUNTER_FILE"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_plan_review_gate
# ---------------------------------------------------------------------------
# PreToolUse hook (ExitPlanMode matcher): blocks ExitPlanMode if no plan review
# has been recorded.
hook_plan_review_gate() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"plan-review-gate\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "ExitPlanMode" ]]; then
        return 0
    fi

    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    local ARTIFACTS_DIR
    ARTIFACTS_DIR=$(get_artifacts_dir)
    local REVIEW_STATE_FILE="$ARTIFACTS_DIR/plan-review-status"

    if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
        echo "# PLAN REVIEW GATE: BLOCKED" >&2
        echo "" >&2
        echo "**No plan review has been recorded for this session.**" >&2
        echo "" >&2
        echo "Before presenting a plan to the user, run the plan-review skill:" >&2
        echo "  Invoke \`/dso:plan-review\` with the plan content." >&2
        echo "" >&2
        echo "This ensures plans are reviewed by a sub-agent before user approval." >&2
        echo "" >&2
        return 2
    fi

    local REVIEW_STATUS
    REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$REVIEW_STATUS" != "passed" ]]; then
        echo "# PLAN REVIEW GATE: BLOCKED (REVIEW NOT PASSED)" >&2
        echo "" >&2
        echo "**The plan review did not pass.**" >&2
        echo "" >&2
        echo "Address the review findings and re-run \`/dso:plan-review\`." >&2
        echo "" >&2
        return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_brainstorm_gate
# ---------------------------------------------------------------------------
# PreToolUse hook (EnterPlanMode matcher): blocks EnterPlanMode if no
# brainstorm sentinel has been recorded for this session.
#
# The sentinel is written by /dso:brainstorm when it completes successfully.
# Sentinel path: $ARTIFACTS_DIR/brainstorm-sentinel
# (session-scoping comes from get_artifacts_dir() which is unique per repo —
# session ID in the filename is unnecessary complexity)
#
# Config: brainstorm.enforce_entry_gate (default: true)
#   Set to false to disable the gate (e.g., for sessions that don't require brainstorm).
hook_brainstorm_gate() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"brainstorm-gate\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "EnterPlanMode" ]]; then
        return 0
    fi

    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    # Check config: brainstorm.enforce_entry_gate (default true)
    local _PLUGIN_ROOT
    _PLUGIN_ROOT=$(resolve_plugin_root)
    local ENFORCE_GATE
    ENFORCE_GATE=$(bash "$_PLUGIN_ROOT/scripts/read-config.sh" brainstorm.enforce_entry_gate 2>/dev/null || echo "")
    if [[ "$ENFORCE_GATE" == "false" ]]; then
        return 0
    fi

    local ARTIFACTS_DIR
    ARTIFACTS_DIR=$(get_artifacts_dir)

    # REVIEW-DEFENSE: The allowlist bypass reads $ARTIFACTS_DIR/active-skill-context, which
    # is written by each skill's SKILL.md at entry (e.g., "echo 'sprint' > $ARTIFACTS_DIR/active-skill-context").
    # No production writer exists yet — this is Phase 1 infrastructure. Skills adopt the
    # writer in their own enhancement cycles. The mechanism is tested via unit tests that
    # create the file directly. This is the same pattern as the brainstorm sentinel: the
    # hook (reader) ships before all writers are wired.
    #
    # Allowlist bypass: skills that legitimately invoke EnterPlanMode as part of
    # their workflow do not need a prior brainstorm sentinel.
    # To update this list: add the skill's short name (the part after "dso:") to the
    # BRAINSTORM_GATE_ALLOWLIST array below, then add a corresponding test in
    # tests/hooks/test-brainstorm-gate-hook.sh.
    # Writers: each allowlisted skill writes active-skill-context at entry via:
    #   source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
    #   echo "<skill-short-name>" > "$(get_artifacts_dir)/active-skill-context"
    local -a BRAINSTORM_GATE_ALLOWLIST
    BRAINSTORM_GATE_ALLOWLIST=(
        fix-bug
        debug-everything
        sprint
        implementation-plan
        preplanning
        resolve-conflicts
        architect-foundation
        retro
    )

    local SKILL_CONTEXT_FILE="$ARTIFACTS_DIR/active-skill-context"
    if [[ -f "$SKILL_CONTEXT_FILE" ]]; then
        local SKILL_NAME
        SKILL_NAME=$(< "$SKILL_CONTEXT_FILE")
        local _skill
        for _skill in "${BRAINSTORM_GATE_ALLOWLIST[@]}"; do
            if [[ "$SKILL_NAME" == "$_skill" ]]; then
                echo "Brainstorm gate: bypassed (allowlisted skill: $SKILL_NAME)" >&2
                return 0
            fi
        done
    fi

    local SENTINEL_FILE="$ARTIFACTS_DIR/brainstorm-sentinel"

    if [[ ! -f "$SENTINEL_FILE" ]]; then
        echo "# BRAINSTORM GATE: BLOCKED" >&2
        echo "" >&2
        echo "**No brainstorm sentinel recorded for this session.**" >&2
        echo "" >&2
        echo "Before entering plan mode for a new feature or epic, run the brainstorm skill:" >&2
        echo "  Invoke \`/dso:brainstorm\` with the feature idea." >&2
        echo "" >&2
        echo "This ensures ideas are properly scoped and refined before planning begins." >&2
        echo "" >&2
        return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_taskoutput_block_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: block TaskOutput calls with block=false
hook_taskoutput_block_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"taskoutput-block-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    local BLOCK_VALUE=""
    if echo "$INPUT" | grep -qE '"block"\s*:\s*false'; then
        BLOCK_VALUE="false"
    elif echo "$INPUT" | grep -qE '"block"\s*:\s*true'; then
        BLOCK_VALUE="true"
    fi

    if [[ "$BLOCK_VALUE" != "false" ]]; then
        return 0
    fi

    echo "BLOCKED: TaskOutput with block=false is not supported." >&2
    echo "" >&2
    echo "The TaskOutput tool API does not support non-blocking (block=false) operation." >&2
    echo "Using block=false causes errors or silent failures." >&2
    echo "" >&2
    echo "Fix: Remove the block parameter (defaults to true) or set block=true." >&2
    echo "To check on a background task, use block=true with a short timeout instead." >&2
    return 2
}
