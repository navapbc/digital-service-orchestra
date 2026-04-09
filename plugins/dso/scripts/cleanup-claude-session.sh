#!/bin/bash
set -uo pipefail
# scripts/cleanup-claude-session.sh
# Clean up orphaned processes, temp files, and stale state.
#
# This script cleans up:
#   1. Orphaned Claude shell wrapper processes (zombie zsh processes)
#   2. Stale validation log files in /tmp
#   3. Stale Claude task output files
#   4. Hung Docker test containers (report only) — skipped when session.artifact_prefix is absent
#   5. Timeout log summary (report only, not reset — retro triage resets these)
#   6. Cascade circuit breaker state for dead/stale sessions
#   7. Validation gate state for dead worktrees
#   8. Test artifact dirs for dead worktrees — skipped when session.artifact_prefix is absent
#   9. Legacy subagent counter migration cleanup
#  10. Claude debug logs older than 7 days
#  11. Prunable git worktrees
#  12. (removed — Python tool cache cleanup is tech-stack specific)
#  13. Playwright CLI state and worktree .tmp/ dirs
#  14. GC stale workflow plugin state files (>24h old)
#  15. Stale worktree isolation auth marker files (dead PID)
#
# NOT cleaned by this script (handled by /dso:retro triage phase):
#   - ~/.claude/hook-error-log.jsonl (must be triaged into bugs first)
#   - Timeout logs (must be reviewed before reset)
#
# Usage:
#   ./scripts/cleanup-claude-session.sh                # Normal cleanup with summary
#   ./scripts/cleanup-claude-session.sh --quiet        # Silent mode (for automation)
#   ./scripts/cleanup-claude-session.sh --summary-only # Suppress headers/zero results; 1 line when clean
#   ./scripts/cleanup-claude-session.sh --dry-run      # Show what would be cleaned without doing it
#
# This script does NOT require LLM - it's pure bash for efficiency.
# Run this between Claude sessions or when you notice orphaned processes.

set -e

QUIET=0
DRY_RUN=0
SUMMARY_ONLY=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        --quiet|-q) QUIET=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --summary-only|-s) SUMMARY_ONLY=1 ;;
        --help|-h)
            echo "Usage: ./scripts/cleanup-claude-session.sh [--quiet] [--summary-only] [--dry-run]"
            echo "  --quiet, -q        Silent mode (only errors)"
            echo "  --summary-only, -s Suppress headers/zero results; 1 line when clean"
            echo "  --dry-run, -n      Show what would be cleaned without doing it"
            exit 0
            ;;
    esac
done

# log: general messages (suppressed in --quiet and --summary-only modes)
log() {
    [ $QUIET -eq 0 ] && [ $SUMMARY_ONLY -eq 0 ] && echo "$1"
}

# log_action: non-zero result messages (suppressed only in --quiet mode)
log_action() {
    [ $QUIET -eq 0 ] && echo "$1"
}

# Resolve repo root (works from worktrees too)
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
WORKTREE_NAME=$(basename "$REPO_ROOT")

# Resolve CLAUDE_PLUGIN_ROOT if not set by the caller (e.g., running outside Claude Code)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _cfg="$REPO_ROOT/.claude/dso-config.conf"
    if [[ -f "$_cfg" ]]; then
        _raw_root="$(grep '^dso\.plugin_root=' "$_cfg" 2>/dev/null | cut -d= -f2-)"
        if [[ -n "$_raw_root" ]]; then
            # Resolve relative paths against REPO_ROOT
            if [[ "$_raw_root" != /* ]]; then
                CLAUDE_PLUGIN_ROOT="$REPO_ROOT/$_raw_root"
            else
                CLAUDE_PLUGIN_ROOT="$_raw_root"
            fi
        fi
    fi
    if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso"
    fi
fi

# Source config-driven paths (CFG_APP_DIR defaults to "app")
_CONFIG_PATHS="${CLAUDE_PLUGIN_ROOT}/hooks/lib/config-paths.sh"
if [ -f "$_CONFIG_PATHS" ]; then
    # shellcheck source=../../hooks/lib/config-paths.sh
    source "$_CONFIG_PATHS"
else
    CFG_APP_DIR="app"
fi

# Read session.artifact_prefix from .claude/dso-config.conf via read-config.sh.
# When absent, steps 4 (Docker filter) and 8 (artifact dirs) are skipped.
PLUGIN_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"
ARTIFACT_PREFIX=$(bash "$PLUGIN_SCRIPTS/read-config.sh" session.artifact_prefix 2>/dev/null || true)

if [ -z "$ARTIFACT_PREFIX" ]; then
    log_action "Warning: session.artifact_prefix not set in .claude/dso-config.conf — skipping Docker filter and artifact dir cleanup"
fi

# Get list of active worktree paths for cross-referencing
ACTIVE_WORKTREES=$(git worktree list --porcelain 2>/dev/null | grep "^worktree " | sed 's/^worktree //' || true)

# Helper: check if a worktree name corresponds to an active worktree
is_active_worktree() {
    local name="$1"
    echo "$ACTIVE_WORKTREES" | grep -q "/${name}$" 2>/dev/null
}

# Track cleanup counts
PROCS_KILLED=0
LOGS_CLEANED=0
TASKS_CLEANED=0
CASCADE_CLEANED=0
VALIDATION_DIRS_CLEANED=0
ARTIFACT_DIRS_CLEANED=0
DEBUG_LOGS_CLEANED=0
WORKTREES_PRUNED=0
PLAYWRIGHT_CLEANED=0
TMP_DIRS_CLEANED=0
STATE_FILES_CLEANED=0

# gc_stale_state_files
# Removes state files older than 24 hours from /tmp/workflow-plugin-*/
# directories and prunes empty plugin dirs after cleanup.
#
# Affected file patterns:
#   review-status, validation-status, reviewer-findings.json,
#   commit-breadcrumbs.log, review-diff-*.txt, review-stat-*.txt
#
# The GC_PLUGIN_GLOB environment variable overrides the default glob
# (/tmp/workflow-plugin-*/) to allow isolated testing without touching
# real /tmp directories.
#
# Safe to call multiple times (idempotent). Logs to stderr.
gc_stale_state_files() {
    local glob="${GC_PLUGIN_GLOB:-/tmp/workflow-plugin-*/}"
    local age_minutes=1440  # 24 hours

    local stale_count=0

    # Expand the glob to find matching directories.
    # Top-level match is intentional — get_artifacts_dir() creates /tmp/workflow-plugin-<hash>/
    # at the top level only. Override GC_PLUGIN_GLOB for custom search paths.
    local dirs=()
    # shellcheck disable=SC2086
    for d in $glob; do
        [[ -d "$d" ]] && dirs+=("$d")
    done

    if [[ ${#dirs[@]} -eq 0 ]]; then
        return 0
    fi

    for plugin_dir in "${dirs[@]}"; do
        [[ -d "$plugin_dir" ]] || continue

        # Find state files matching known patterns older than 24 hours
        local stale_files
        stale_files=$(find "$plugin_dir" -maxdepth 1 \( \
            -name "review-status" \
            -o -name "validation-status" \
            -o -name "reviewer-findings.json" \
            -o -name "commit-breadcrumbs.log" \
            -o -name "review-diff-*.txt" \
            -o -name "review-stat-*.txt" \
        \) -mmin "+${age_minutes}" 2>/dev/null || true)

        if [[ -n "$stale_files" ]]; then
            local count
            count=$(echo "$stale_files" | wc -l | tr -d ' ')
            stale_count=$((stale_count + count))
            echo "$stale_files" | xargs rm -f 2>/dev/null || true
            echo "  gc_stale_state_files: removed $count stale state file(s) from $plugin_dir" >&2
        fi

        # Remove the plugin dir if it is now empty
        if [[ -d "$plugin_dir" ]]; then
            local remaining
            remaining=$(find "$plugin_dir" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
            if [[ "$remaining" -eq 0 ]]; then
                rmdir "$plugin_dir" 2>/dev/null || true
                echo "  gc_stale_state_files: removed empty plugin dir $plugin_dir" >&2
            fi
        fi
    done

    # Export count for summary (use default 0 in case function is sourced in isolation)
    STATE_FILES_CLEANED=$(( ${STATE_FILES_CLEANED:-0} + stale_count ))
    return 0
}

log "=== Claude Session Cleanup ==="

# 1. Kill orphaned Claude shell wrapper processes
log ""
log "Checking for orphaned Claude shell processes..."

ORPHAN_PIDS=$(pgrep -f "shell-snapshots.*claude" 2>/dev/null || true)
if [ -n "$ORPHAN_PIDS" ]; then
    PROCS_KILLED=$(echo "$ORPHAN_PIDS" | wc -l | tr -d ' ')
    if [ $DRY_RUN -eq 1 ]; then
        log_action "  Would kill $PROCS_KILLED orphaned shell process(es)"
        log_action "  PIDs: $(echo "$ORPHAN_PIDS" | tr '\n' ' ')"
    else
        echo "$ORPHAN_PIDS" | xargs kill 2>/dev/null || true
        log_action "  Killed $PROCS_KILLED orphaned shell process(es)"
    fi
else
    log "  No orphaned shell processes found"
fi

# 2. Clean up stale validation log files (older than 1 hour)
log ""
log "Checking for stale validation logs..."

STALE_LOGS=$(find /tmp -maxdepth 1 -name "validation-*.log" -mmin +60 2>/dev/null || true)
if [ -n "$STALE_LOGS" ]; then
    LOGS_CLEANED=$(echo "$STALE_LOGS" | wc -l | tr -d ' ')
    if [ $DRY_RUN -eq 1 ]; then
        log_action "  Would remove $LOGS_CLEANED stale validation log(s)"
    else
        echo "$STALE_LOGS" | xargs rm -f 2>/dev/null || true
        log_action "  Removed $LOGS_CLEANED stale validation log(s)"
    fi
else
    log "  No stale validation logs found"
fi

# 3. Clean up stale Claude task output files (older than 2 hours)
log ""
log "Checking for stale task output files..."

CLAUDE_TASK_DIRS=$(find /private/tmp -maxdepth 2 -type d -name "claude-*" 2>/dev/null || true)
if [ -n "$CLAUDE_TASK_DIRS" ]; then
    for dir in $CLAUDE_TASK_DIRS; do
        TASK_DIR="$dir/tasks"
        if [ -d "$TASK_DIR" ]; then
            STALE_TASKS=$(find "$TASK_DIR" -name "*.output" -mmin +120 2>/dev/null || true)
            if [ -n "$STALE_TASKS" ]; then
                COUNT=$(echo "$STALE_TASKS" | wc -l | tr -d ' ')
                TASKS_CLEANED=$((TASKS_CLEANED + COUNT))
                if [ $DRY_RUN -eq 0 ]; then
                    echo "$STALE_TASKS" | xargs rm -f 2>/dev/null || true
                fi
            fi
        fi
    done
    if [ $TASKS_CLEANED -gt 0 ]; then
        if [ $DRY_RUN -eq 1 ]; then
            log_action "  Would remove $TASKS_CLEANED stale task output file(s)"
        else
            log_action "  Removed $TASKS_CLEANED stale task output file(s)"
        fi
    else
        log "  No stale task output files found"
    fi
else
    log "  No Claude task directories found"
fi

# 3b. Clean up stale agent JSONL files (backing files for task output symlinks)
# The *.output files in step 3 are symlinks to ~/.claude/projects/*/subagents/agent-*.jsonl.
# Step 3 deletes the symlinks but not the backing files, which grow unbounded.
log ""
log "Checking for stale agent JSONL files..."
JSONL_CLEANED=0
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
if [ -d "$CLAUDE_PROJECTS_DIR" ]; then
    # Find agent JSONL files older than 2 hours (scoped to subagents/ dirs)
    STALE_JSONL=$(find "$CLAUDE_PROJECTS_DIR" -path "*/subagents/agent-*.jsonl" -mmin +120 2>/dev/null || true)
    if [ -n "$STALE_JSONL" ]; then
        JSONL_CLEANED=$(echo "$STALE_JSONL" | wc -l | tr -d ' ')
        if [ $DRY_RUN -eq 0 ]; then
            echo "$STALE_JSONL" | xargs rm -f 2>/dev/null || true
        fi
    fi
    # Also find oversized JSONL files (>500MB) that weren't already deleted (not stale)
    LARGE_JSONL=$(find "$CLAUDE_PROJECTS_DIR" -path "*/subagents/agent-*.jsonl" -size +500M -not -mmin +120 2>/dev/null || true)
    if [ -n "$LARGE_JSONL" ]; then
        LARGE_COUNT=$(echo "$LARGE_JSONL" | wc -l | tr -d ' ')
        JSONL_CLEANED=$((JSONL_CLEANED + LARGE_COUNT))
        if [ $DRY_RUN -eq 0 ]; then
            echo "$LARGE_JSONL" | xargs rm -f 2>/dev/null || true
        else
            log_action "  WARNING: Found $LARGE_COUNT agent JSONL file(s) >500MB"
        fi
    fi
    if [ $JSONL_CLEANED -gt 0 ]; then
        if [ $DRY_RUN -eq 1 ]; then
            log_action "  Would remove $JSONL_CLEANED stale/oversized agent JSONL file(s)"
        else
            log_action "  Removed $JSONL_CLEANED stale/oversized agent JSONL file(s)"
        fi
    else
        log "  No stale agent JSONL files found"
    fi
else
    log "  No Claude projects directory found"
fi

# 4. Clean up any hung Docker processes related to tests (report only)
# Skipped when session.artifact_prefix is absent from .claude/dso-config.conf
log ""
log "Checking for hung test containers..."

if [ -z "$ARTIFACT_PREFIX" ]; then
    log "  Skipping Docker check (session.artifact_prefix not configured)"
else
    HUNG_CONTAINERS=$(docker ps --filter "name=${ARTIFACT_PREFIX}" --filter "status=running" --format "{{.Names}}: {{.Status}}" 2>/dev/null | grep -E "hours|days" || true)
    if [ -n "$HUNG_CONTAINERS" ]; then
        log_action "  Found potentially hung containers:"
        log_action "  $HUNG_CONTAINERS"
        log_action "  (Run 'docker compose down' in ${CFG_APP_DIR}/ to clean up if needed)"
    else
        log "  No hung containers found"
    fi
fi

# 5. Show timeout log summary (report only — retro triage resets these)
log ""
log "Checking timeout logs..."

# Path scheme mirrors validate.sh's get_artifacts_dir(): /tmp/<prefix>-<worktree-name>
if [ -n "$ARTIFACT_PREFIX" ]; then
    TIMEOUT_LOG_BASE_DIR="/tmp/${ARTIFACT_PREFIX}-${WORKTREE_NAME}"
else
    TIMEOUT_LOG_BASE_DIR=""
fi
TIMEOUT_ENTRIES=0

if [ -n "$TIMEOUT_LOG_BASE_DIR" ]; then
    VALIDATION_TIMEOUT_LOG="$TIMEOUT_LOG_BASE_DIR/validation-timeouts.log"
    PRECOMMIT_TIMEOUT_LOG="$TIMEOUT_LOG_BASE_DIR/precommit-timeouts.log"

    for timeout_log in "$VALIDATION_TIMEOUT_LOG" "$PRECOMMIT_TIMEOUT_LOG"; do
        if [ -f "$timeout_log" ]; then
            RECENT_TIMEOUTS=$(tail -5 "$timeout_log" 2>/dev/null || true)
            if [ -n "$RECENT_TIMEOUTS" ]; then
                COUNT=$(wc -l < "$timeout_log" | tr -d ' ')
                TIMEOUT_ENTRIES=$((TIMEOUT_ENTRIES + COUNT))
                log_action "  Found $COUNT timeout(s) in $(basename "$timeout_log"):"
                log_action "  Last 5 entries:"
                echo "$RECENT_TIMEOUTS" | while read -r line; do
                    log_action "    $line"
                done
            fi
        fi
    done
fi

if [ $TIMEOUT_ENTRIES -eq 0 ]; then
    log "  No timeout events recorded"
else
    log_action ""
    log_action "  TIP: Run /dso:retro to triage timeout logs into bugs before reset"
fi

# 6. Clean cascade circuit breaker state (>30 min old)
log ""
log "Checking for stale cascade circuit breaker state..."

STALE_CASCADE=$(find /tmp -maxdepth 1 -type d -name "claude-cascade-*" -mmin +30 2>/dev/null || true)
if [ -n "$STALE_CASCADE" ]; then
    CASCADE_CLEANED=$(echo "$STALE_CASCADE" | wc -l | tr -d ' ')
    if [ $DRY_RUN -eq 1 ]; then
        log_action "  Would remove $CASCADE_CLEANED stale cascade state dir(s)"
    else
        echo "$STALE_CASCADE" | xargs rm -rf 2>/dev/null || true
        log_action "  Removed $CASCADE_CLEANED stale cascade state dir(s)"
    fi
else
    log "  No stale cascade state found"
fi

# 7. Clean validation gate state for dead worktrees
log ""
log "Checking for validation state of dead worktrees..."

for dir in /tmp/claude-validation-*/ ; do
    [ -d "$dir" ] || continue
    wt_name=$(basename "$dir")
    wt_name="${wt_name#claude-validation-}"
    if ! is_active_worktree "$wt_name"; then
        VALIDATION_DIRS_CLEANED=$((VALIDATION_DIRS_CLEANED + 1))
        if [ $DRY_RUN -eq 0 ]; then
            rm -rf "$dir"
        fi
    fi
done

if [ $VALIDATION_DIRS_CLEANED -gt 0 ]; then
    if [ $DRY_RUN -eq 1 ]; then
        log_action "  Would remove $VALIDATION_DIRS_CLEANED validation state dir(s) for dead worktrees"
    else
        log_action "  Removed $VALIDATION_DIRS_CLEANED validation state dir(s) for dead worktrees"
    fi
else
    log "  No dead worktree validation state found"
fi

# 8. Clean test artifact dirs for dead worktrees
# Skipped when session.artifact_prefix is absent from .claude/dso-config.conf
log ""
log "Checking for test artifacts of dead worktrees..."

if [ -z "$ARTIFACT_PREFIX" ]; then
    log "  Skipping artifact dir check (session.artifact_prefix not configured)"
else
    for dir in /tmp/"${ARTIFACT_PREFIX}"-*/ ; do
        [ -d "$dir" ] || continue
        wt_name=$(basename "$dir")
        wt_name="${wt_name#"${ARTIFACT_PREFIX}"-}"
        # Keep "app" (main repo) and any active worktree
        if [ "$wt_name" = "app" ]; then
            continue
        fi
        if ! is_active_worktree "$wt_name"; then
            ARTIFACT_DIRS_CLEANED=$((ARTIFACT_DIRS_CLEANED + 1))
            if [ $DRY_RUN -eq 0 ]; then
                rm -rf "$dir"
            fi
        fi
    done

    if [ $ARTIFACT_DIRS_CLEANED -gt 0 ]; then
        if [ $DRY_RUN -eq 1 ]; then
            log_action "  Would remove $ARTIFACT_DIRS_CLEANED test artifact dir(s) for dead worktrees"
        else
            log_action "  Removed $ARTIFACT_DIRS_CLEANED test artifact dir(s) for dead worktrees"
        fi
    else
        log "  No dead worktree test artifacts found"
    fi
fi

# 9. Migration: remove legacy subagent counter file
if [ $DRY_RUN -eq 1 ]; then
    [ -f /tmp/claude-subagent-active-count ] && log_action "  Would remove legacy subagent counter file"
else
    rm -f /tmp/claude-subagent-active-count 2>/dev/null || true
fi

# 10. Clean Claude debug logs older than 7 days
log ""
log "Checking for stale Claude debug logs..."

CLAUDE_DEBUG_DIR="$HOME/.claude/debug"
if [ -d "$CLAUDE_DEBUG_DIR" ]; then
    STALE_DEBUG=$(find "$CLAUDE_DEBUG_DIR" -name "*.txt" -mtime +7 2>/dev/null || true)
    if [ -n "$STALE_DEBUG" ]; then
        DEBUG_LOGS_CLEANED=$(echo "$STALE_DEBUG" | wc -l | tr -d ' ')
        if [ $DRY_RUN -eq 1 ]; then
            STALE_SIZE=$(echo "$STALE_DEBUG" | xargs du -ch 2>/dev/null | tail -1 | cut -f1)
            log_action "  Would remove $DEBUG_LOGS_CLEANED debug log(s) ($STALE_SIZE)"
        else
            echo "$STALE_DEBUG" | xargs rm -f 2>/dev/null || true
            log_action "  Removed $DEBUG_LOGS_CLEANED stale debug log(s)"
        fi
    else
        log "  No stale debug logs found"
    fi
else
    log "  No debug log directory found"
fi

# 11. Prune dead git worktrees
log ""
log "Checking for prunable git worktrees..."

# Go to the main repo root (not a worktree) for pruning
MAIN_REPO=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
if [ -n "$MAIN_REPO" ]; then
    PRUNABLE=$(git -C "$MAIN_REPO" worktree list 2>/dev/null | grep "prunable" || true)
    if [ -n "$PRUNABLE" ]; then
        WORKTREES_PRUNED=$(echo "$PRUNABLE" | wc -l | tr -d ' ')
        if [ $DRY_RUN -eq 1 ]; then
            log_action "  Would prune $WORKTREES_PRUNED dead worktree(s):"
            echo "$PRUNABLE" | while read -r line; do
                log_action "    $line"
            done
        else
            git -C "$MAIN_REPO" worktree prune 2>/dev/null || true
            log_action "  Pruned $WORKTREES_PRUNED dead worktree reference(s)"
        fi
    else
        log "  No prunable worktrees found"
    fi
fi

# ── 12. (removed — Python tool cache cleanup is tech-stack specific) ────────

# 13. Clean Playwright CLI state and .tmp/ dirs
# Also detects and removes orphaned Playwright CLI browser processes and stale sessions.
log ""
log "Checking for Playwright CLI state and .tmp/ dirs..."

# Configurable stale session threshold in minutes (default: 120 minutes)
PLAYWRIGHT_CLI_SESSION_MAX_AGE="${PLAYWRIGHT_CLI_SESSION_MAX_AGE:-120}"

if [ -d "$REPO_ROOT/.playwright-cli" ]; then
    PLAYWRIGHT_CLEANED=1
    if [ $DRY_RUN -eq 0 ]; then
        rm -rf "$REPO_ROOT/.playwright-cli"
    fi
fi

if [ -d "$REPO_ROOT/.tmp" ]; then
    TMP_CONTENTS=$(find "$REPO_ROOT/.tmp" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$TMP_CONTENTS" -gt 0 ]; then
        TMP_DIRS_CLEANED=1
        if [ $DRY_RUN -eq 0 ]; then
            rm -rf "$REPO_ROOT/.tmp"
            mkdir -p "$REPO_ROOT/.tmp"
        fi
    fi
fi

if [ $PLAYWRIGHT_CLEANED -gt 0 ] || [ $TMP_DIRS_CLEANED -gt 0 ]; then
    if [ $DRY_RUN -eq 1 ]; then
        [ $PLAYWRIGHT_CLEANED -gt 0 ] && log_action "  Would remove .playwright-cli/ state"
        [ $TMP_DIRS_CLEANED -gt 0 ] && log_action "  Would clean .tmp/ contents ($TMP_CONTENTS files)"
    else
        [ $PLAYWRIGHT_CLEANED -gt 0 ] && log_action "  Removed .playwright-cli/ state"
        [ $TMP_DIRS_CLEANED -gt 0 ] && log_action "  Cleaned .tmp/ contents"
    fi
else
    log "  No Playwright/tmp state found"
fi

# Detect orphaned Playwright CLI browser processes (Chromium spawned by @playwright/cli sub-agents)
# Note: @playwright/cli auto-detects system Chrome before falling back to ms-playwright Chromium.
# When system Chrome is used, the process path is /Applications/Google Chrome.app/... which does
# NOT contain "playwright" or "ms-playwright". Playwright always passes --remote-debugging-pipe
# to launched browsers, so we use that as a reliable fingerprint alongside the path-based patterns.
log ""
log "Checking for orphaned Playwright CLI browser processes..."
# Path-based patterns (ms-playwright bundled Chromium):
#   playwright.*cli.*chromium, chromium.*playwright.*cli, .playwright-cli.*chrome, ms-playwright.*chromium
# Fingerprint-based pattern (system Chrome launched by Playwright — requires both chrom + remote-debugging-pipe):
#   chrom.*remote-debugging-pipe, remote-debugging-pipe.*chrom
PLAYWRIGHT_CLI_PROCS=$(pgrep -u "$(id -u)" -f "playwright.*cli.*chromium|chromium.*playwright.*cli|\.playwright-cli.*chrome|ms-playwright.*chromium|chrom.*remote-debugging-pipe|remote-debugging-pipe.*chrom" 2>/dev/null || true)
if [ -n "$PLAYWRIGHT_CLI_PROCS" ]; then
    CLI_PROC_COUNT=$(echo "$PLAYWRIGHT_CLI_PROCS" | wc -l | tr -d ' ')
    if [ $DRY_RUN -eq 1 ]; then
        log_action "  Would kill $CLI_PROC_COUNT orphaned Playwright CLI browser process(es)"
        log_action "  PIDs: $(echo "$PLAYWRIGHT_CLI_PROCS" | tr '\n' ' ')"
    else
        echo "$PLAYWRIGHT_CLI_PROCS" | xargs kill 2>/dev/null || true
        log_action "  Killed $CLI_PROC_COUNT orphaned Playwright CLI browser process(es)"
    fi
else
    log "  No orphaned Playwright CLI browser processes found"
fi

# Detect stale Playwright CLI sessions older than threshold
log ""
log "Checking for stale Playwright CLI sessions (older than ${PLAYWRIGHT_CLI_SESSION_MAX_AGE}m)..."
STALE_CLI_SESSIONS_FOUND=0
if [ -d "$HOME/.playwright-cli" ]; then
    STALE_CLI_SESSIONS=$(find "$HOME/.playwright-cli" -maxdepth 2 -type d -mmin "+${PLAYWRIGHT_CLI_SESSION_MAX_AGE}" 2>/dev/null || true)
    if [ -n "$STALE_CLI_SESSIONS" ]; then
        STALE_CLI_SESSIONS_FOUND=$(echo "$STALE_CLI_SESSIONS" | wc -l | tr -d ' ')
        if [ $DRY_RUN -eq 1 ]; then
            log_action "  Would remove $STALE_CLI_SESSIONS_FOUND stale Playwright CLI session dir(s) (>${PLAYWRIGHT_CLI_SESSION_MAX_AGE}m old)"
        else
            while IFS= read -r dir; do rm -rf "$dir" 2>/dev/null; done <<< "$STALE_CLI_SESSIONS" || true
            log_action "  Removed $STALE_CLI_SESSIONS_FOUND stale Playwright CLI session dir(s)"
        fi
    else
        log "  No stale Playwright CLI sessions found"
    fi
else
    log "  No Playwright CLI session directory found"
fi

# 14. GC stale workflow plugin state files (>24h old)
log ""
log "Checking for stale workflow plugin state files..."

if [ $DRY_RUN -eq 1 ]; then
    # Dry-run: report what would be removed without deleting
    _DRY_STALE=$(find /tmp/workflow-plugin-*/ -maxdepth 1 \( \
        -name "review-status" \
        -o -name "validation-status" \
        -o -name "reviewer-findings.json" \
        -o -name "commit-breadcrumbs.log" \
        -o -name "review-diff-*.txt" \
        -o -name "review-stat-*.txt" \
    \) -mmin +1440 2>/dev/null || true)
    if [ -n "$_DRY_STALE" ]; then
        _DRY_COUNT=$(echo "$_DRY_STALE" | wc -l | tr -d ' ')
        log_action "  Would remove $_DRY_COUNT stale plugin state file(s)"
    else
        log "  No stale plugin state files found"
    fi
else
    gc_stale_state_files 2>&1 | while IFS= read -r line; do log_action "$line"; done
    if [ $STATE_FILES_CLEANED -gt 0 ]; then
        log_action "  Removed $STATE_FILES_CLEANED stale plugin state file(s)"
    else
        log "  No stale plugin state files found"
    fi
fi

# Summary
TOTAL_CLEANED=$((PROCS_KILLED + LOGS_CLEANED + TASKS_CLEANED + CASCADE_CLEANED + VALIDATION_DIRS_CLEANED + ARTIFACT_DIRS_CLEANED + DEBUG_LOGS_CLEANED + WORKTREES_PRUNED + PLAYWRIGHT_CLEANED + TMP_DIRS_CLEANED + STATE_FILES_CLEANED))

if [ $SUMMARY_ONLY -eq 1 ] && [ $QUIET -eq 0 ]; then
    # Summary-only mode: single line when clean, brief list when not
    if [ $TOTAL_CLEANED -eq 0 ] && [ $TIMEOUT_ENTRIES -eq 0 ]; then
        echo "Environment is clean!"
    else
        [ "$PROCS_KILLED" -gt 0 ] && echo "  Processes killed: $PROCS_KILLED"
        [ "$LOGS_CLEANED" -gt 0 ] && echo "  Validation logs removed: $LOGS_CLEANED"
        [ "$TASKS_CLEANED" -gt 0 ] && echo "  Task outputs removed: $TASKS_CLEANED"
        [ "$CASCADE_CLEANED" -gt 0 ] && echo "  Cascade state removed: $CASCADE_CLEANED"
        [ $((VALIDATION_DIRS_CLEANED + ARTIFACT_DIRS_CLEANED)) -gt 0 ] && echo "  Dead worktree state removed: $((VALIDATION_DIRS_CLEANED + ARTIFACT_DIRS_CLEANED)) dirs"
        [ "$DEBUG_LOGS_CLEANED" -gt 0 ] && echo "  Debug logs removed: $DEBUG_LOGS_CLEANED"
        [ "$WORKTREES_PRUNED" -gt 0 ] && echo "  Worktrees pruned: $WORKTREES_PRUNED"
        [ "$TIMEOUT_ENTRIES" -gt 0 ] && echo "  Timeout events found: $TIMEOUT_ENTRIES (use /dso:retro to triage)"
    fi
else
    log ""
    log "=== Cleanup Summary ==="
    if [ $DRY_RUN -eq 1 ]; then
        log "  DRY RUN - no changes made"
    fi
    log "  Processes killed:         $PROCS_KILLED"
    log "  Validation logs removed:  $LOGS_CLEANED"
    log "  Task outputs removed:     $TASKS_CLEANED"
    log "  Cascade state removed:    $CASCADE_CLEANED"
    log "  Dead worktree state:      $((VALIDATION_DIRS_CLEANED + ARTIFACT_DIRS_CLEANED)) dirs"
    log "  Debug logs removed:       $DEBUG_LOGS_CLEANED"
    log "  Worktrees pruned:         $WORKTREES_PRUNED"
    log "  Timeout events found:     $TIMEOUT_ENTRIES (not reset — use /dso:retro to triage)"
    log "========================"
    if [ $TOTAL_CLEANED -eq 0 ]; then
        log ""
        log "Environment is clean!"
    fi
fi

exit 0
