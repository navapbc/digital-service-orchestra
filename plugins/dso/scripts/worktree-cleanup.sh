#!/usr/bin/env bash
set -euo pipefail
# Require bash 4+ for associative array support (declare -A).
# macOS ships with bash 3.2 at /bin/bash; install bash 4+ via Homebrew.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "Error: This script requires bash 4+. macOS ships with bash 3.2." >&2
    echo "Install a newer bash with: brew install bash" >&2
    exit 1
fi

# worktree-cleanup.sh — Interactive cleanup of stale git worktrees
#
# claude-safe auto-creates timestamped worktrees (e.g., worktree-20260205-182832)
# when concurrent Claude Code sessions are detected. These accumulate over time
# (~500MB each with venv). This script identifies and removes safe candidates.
#
# Safety checks (ALL must pass before a worktree is eligible for removal):
#   1. Older than 12 hours (age check)
#   2. Branch is merged to main (or only ticket-tracker changes, already synced)
#   3. No uncommitted changes (excluding ticket dir which syncs independently)
#   4. No unpushed commits (excluding ticket-dir-only branches synced to main)
#   5. No stashes
#   6. No active Claude session
#   - Never removes the main repo worktree
#   - Never removes the worktree you're currently in
#   - Creates patch backups before removing dirty worktrees (--force-dirty)
#   - Deletes both local and remote branches by default (--no-branches to skip)
#   - Ticket dir files are excluded from dirty/merge checks because the ticket
#     system pushes them to main independently
#
# Opt-in:
#   Set WORKTREE_CLEANUP_ENABLED=1 to allow non-interactive (scheduled) use.
#   Without this env var, --non-interactive mode exits with an error.
#   Interactive mode always works regardless of this setting.
#
# Logging:
#   All removal actions are logged to CLEANUP_LOG (default: ~/.claude-safe-cleanup.log).
#
# Usage:
#   worktree-cleanup.sh                      # Interactive cleanup
#   worktree-cleanup.sh --dry-run            # Show what would be removed
#   worktree-cleanup.sh --all                # Remove all safe candidates (with confirmation)
#   worktree-cleanup.sh --all --force        # Remove all safe candidates (no confirmation)
#   worktree-cleanup.sh --non-interactive    # Scheduled/automated mode (requires WORKTREE_CLEANUP_ENABLED=1)
#   worktree-cleanup.sh --no-branches        # Don't delete associated git branches (local+remote)
#   worktree-cleanup.sh --force-dirty        # Allow removing dirty worktrees (creates backups)
#   worktree-cleanup.sh --help               # Show this help

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────

DRY_RUN=false
FORCE=false
FORCE_DIRTY=false
INCLUDE_BRANCHES=true
SELECT_ALL=false
NON_INTERACTIVE=false
BACKUP_DIR="$HOME/.worktree-backups"
CLEANUP_LOG="${CLEANUP_LOG:-$HOME/.claude-safe-cleanup.log}"

# ── Project config (read once at startup via read-config.sh) ─────────────────
# REVIEW-DEFENSE: The CONFIG_* variables below appear unused because this is task 2 of 6
# in a linear implementation chain (parent story: lockpick-doc-to-logic-o364). This task
# specifically adds the startup config cache; follow-on tasks (pigg, e4f5, 7t7i, 4sfu)
# wire these values into the script logic (replacing the current hardcoded defaults for
# AGE_HOURS, branch-pattern grep, compose project name, etc.). Pre-declaring the variables
# here follows the established incremental-migration pattern used throughout this codebase.
# Removing them now would break the follow-on tasks.

PLUGIN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_COMPOSE_DB_FILE=$(bash "$PLUGIN_SCRIPTS/read-config.sh" infrastructure.compose_db_file 2>/dev/null || true)
CONFIG_COMPOSE_PROJECT=$(bash "$PLUGIN_SCRIPTS/read-config.sh" infrastructure.compose_project 2>/dev/null || true)
CONFIG_CONTAINER_PREFIX=$(bash "$PLUGIN_SCRIPTS/read-config.sh" infrastructure.container_prefix 2>/dev/null || true)
CONFIG_BRANCH_PATTERN=$(bash "$PLUGIN_SCRIPTS/read-config.sh" worktree.branch_pattern 2>/dev/null || true)
CONFIG_MAX_AGE_HOURS=$(bash "$PLUGIN_SCRIPTS/read-config.sh" worktree.max_age_hours 2>/dev/null || true)

# Capture whether AGE_HOURS was explicitly set in the environment before applying defaults.
_AGE_HOURS_FROM_ENV="${AGE_HOURS:-}"
AGE_HOURS=${AGE_HOURS:-${CONFIG_MAX_AGE_HOURS:-12}}  # env var > config > default (12 hours)

# ── Backward-compat: AGE_DAYS → AGE_HOURS migration ─────────────────────────
# AGE_DAYS was renamed to AGE_HOURS when the threshold unit changed from days
# to hours (default 2d → 12h). If a caller set AGE_DAYS but not AGE_HOURS,
# convert it automatically so existing scripts are not silently broken.
if [[ -n "${AGE_DAYS:-}" && -z "$_AGE_HOURS_FROM_ENV" ]]; then
    echo "Warning: AGE_DAYS is deprecated — use AGE_HOURS instead. Converting AGE_DAYS=${AGE_DAYS} to AGE_HOURS=$(( AGE_DAYS * 24 ))" >&2
    AGE_HOURS=$(( AGE_DAYS * 24 ))
fi

# ── Partial Docker config detection ──────────────────────────────────────────
# Warn when Docker config keys are inconsistently set, to prevent silent
# misconfiguration where some keys are present but critical ones are missing.
# These warnings go to stderr so they don't pollute output parsing.
if [[ -z "$CONFIG_COMPOSE_DB_FILE" ]]; then
    if [[ -n "$CONFIG_COMPOSE_PROJECT" || -n "$CONFIG_CONTAINER_PREFIX" ]]; then
        echo "Warning: Docker config is partially set — infrastructure.compose_project or infrastructure.container_prefix is configured but infrastructure.compose_db_file is absent. Docker cleanup steps will be skipped." >&2
    fi
elif [[ -z "$CONFIG_COMPOSE_PROJECT" ]]; then
    echo "Warning: Docker config is partially set — infrastructure.compose_db_file is configured but infrastructure.compose_project is absent. Docker Compose teardown will be skipped." >&2
fi

# ── Color / formatting ───────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    BOLD='\033[1m'
    DIM='\033[2m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    RED='\033[31m'
    CYAN='\033[36m'
    RESET='\033[0m'
else
    BOLD='' DIM='' GREEN='' YELLOW='' RED='' CYAN='' RESET=''
fi

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Interactive cleanup of stale git worktrees created by claude-safe.

A worktree is eligible for removal only when ALL safety criteria are met:
  1. Older than ${AGE_HOURS} hours
  2. Branch is merged to main (or only ticket-tracker changes, already synced)
  3. No uncommitted changes (excluding ticket dir)
  4. No unpushed commits (excluding ticket-dir-only)
  5. No stashes
  6. No active Claude session

Options:
  -n, --dry-run          Show what would be removed without doing it
  -f, --force            Skip confirmation prompts (respects safety checks)
  -a, --all              Select all removable worktrees (skip interactive selection)
      --non-interactive  Run in scheduled/automated mode (requires WORKTREE_CLEANUP_ENABLED=1)
      --force-dirty      Allow removing worktrees with uncommitted changes
                         (creates a patch backup first at ~/.worktree-backups/)
      --no-branches      Don't delete associated local and remote git branches
                         (by default, branches are deleted when worktrees are removed)
  -h, --help             Show this help message

Environment variables:
  WORKTREE_CLEANUP_ENABLED=1   Required for --non-interactive (scheduled/cron) mode
  CLEANUP_LOG=<path>           Log file path (default: ~/.claude-safe-cleanup.log)

Examples:
  $(basename "$0")                                  # Interactive mode
  $(basename "$0") --dry-run                        # Preview removals
  $(basename "$0") --all --force                    # Non-interactive, remove all safe
  $(basename "$0") --no-branches                    # Remove worktrees but keep branches
  $(basename "$0") --force-dirty --all              # Remove everything, backup dirty ones
  WORKTREE_CLEANUP_ENABLED=1 $(basename "$0") --non-interactive --all --force  # Cron/launchd
EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)       DRY_RUN=true; shift ;;
        -f|--force)         FORCE=true; shift ;;
        -a|--all)           SELECT_ALL=true; shift ;;
        --force-dirty)      FORCE_DIRTY=true; shift ;;
        --no-branches)      INCLUDE_BRANCHES=false; shift ;;
        --include-branches) INCLUDE_BRANCHES=true; shift ;; # backward compat (now default)
        --non-interactive)  NON_INTERACTIVE=true; shift ;;
        -h|--help)          usage ;;
        *)
            echo "Error: Unknown option '$1'"
            echo "Run '$(basename "$0") --help' for usage."
            exit 1 ;;
    esac
done

# ── Opt-in check for non-interactive (scheduled) mode ────────────────────────

if [[ "$NON_INTERACTIVE" == "true" ]]; then
    if [[ "${WORKTREE_CLEANUP_ENABLED:-0}" != "1" ]]; then
        echo "Error: Non-interactive worktree cleanup is not enabled."
        echo "Set WORKTREE_CLEANUP_ENABLED=1 to opt in to scheduled cleanup."
        echo "Run '$(basename "$0") --help' for usage."
        exit 1
    fi
fi

# ── Utility functions ─────────────────────────────────────────────────────────

# Estimate disk usage in kilobytes (for summing)
estimate_size_kb() {
    du -sk "$1" 2>/dev/null | awk '{print $1}' || echo "0"
}

# Format kilobytes into human-readable
format_kb() {
    local kb="$1"
    if [[ $kb -ge 1048576 ]]; then
        echo "$(echo "scale=1; $kb / 1048576" | bc)G"
    elif [[ $kb -ge 1024 ]]; then
        echo "$(( kb / 1024 ))M"
    else
        echo "${kb}K"
    fi
}

# Check if a branch is merged to a target branch, with fallbacks for post-merge
# amends and GitHub PR merges. When merge-to-main.sh times out and the
# orchestrator amends the worktree branch's HEAD during recovery, the branch tip
# SHA changes so merge-base --is-ancestor fails. The second fallback checks for
# the standard merge-to-main.sh message format ("... (merge $branch)"). The
# third fallback covers GitHub PR merge commits ("Merge pull request #N from
# org/branch") which contain the branch name but not in the parenthetical form.
# Args: $1=git_dir (main worktree), $2=branch_name, $3=target_branch
# Returns: 0 if merged, 1 if not
is_branch_merged() {
    local git_dir="$1" branch_name="$2" target_branch="$3"
    if git -C "$git_dir" merge-base --is-ancestor "$branch_name" "$target_branch" 2>/dev/null; then
        return 0
    fi
    if git -C "$git_dir" log "$target_branch" --oneline --grep="(merge $branch_name)" -1 2>/dev/null | grep -q .; then
        return 0
    fi
    if git -C "$git_dir" log "$target_branch" --oneline --grep="Merge pull request.*$branch_name" -1 2>/dev/null | grep -q .; then
        # Anchored to "Merge pull request" to avoid false positives from unrelated
        # commits that mention the branch name in their body text.
        return 0
    fi
    return 1
}

# Log an action to the cleanup log file
log_action() {
    local message="$1"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$timestamp] $message" >> "$CLEANUP_LOG" 2>/dev/null || true
}

# Check if a worktree is older than AGE_HOURS hours
# Returns 0 (true) if old enough to be eligible, 1 if too recent
is_old_enough() {
    local wt_path="$1"
    local age_hours="${AGE_HOURS:-12}"

    # Agent worktrees (created by Agent tool dispatches with isolation:"worktree")
    # are transient by design — minutes-long, not human sessions. The age gate is
    # inappropriate for them, and without this exemption they accumulate
    # indefinitely (bug afdb-8418). Any path under `.claude/worktrees/agent-*`
    # is eligible for reclamation immediately.
    case "$wt_path" in
        */.claude/worktrees/agent-*) return 0 ;;
    esac

    # Use the creation time of the worktree directory as the age reference.
    # On macOS, stat -f %B gives the birth time (seconds since epoch).
    # On Linux, stat -c %W gives birth time (may be 0 if unsupported; fall back to mtime).
    local created_epoch=0
    if [[ "$(uname)" == "Darwin" ]]; then
        created_epoch=$(stat -f %B "$wt_path" 2>/dev/null || echo "0")
    else
        created_epoch=$(stat -c %W "$wt_path" 2>/dev/null || echo "0")
    fi

    if [[ "$created_epoch" -eq 0 ]]; then
        # Fall back to mtime of the directory
        if [[ "$(uname)" == "Darwin" ]]; then
            created_epoch=$(stat -f %m "$wt_path" 2>/dev/null || echo "0")
        else
            created_epoch=$(stat -c %Y "$wt_path" 2>/dev/null || echo "0")
        fi
    fi

    local now_epoch
    now_epoch=$(date +%s)
    local age_seconds=$(( now_epoch - created_epoch ))
    local threshold_seconds=$(( age_hours * 3600 ))

    [[ "$age_seconds" -ge "$threshold_seconds" ]]
}

# Check if a worktree has any stashes
has_stashes() {
    local wt_path="$1"
    local stash_count
    stash_count=$(git -C "$wt_path" stash list 2>/dev/null | wc -l | tr -d ' ')
    [[ "$stash_count" -gt 0 ]]
}

# Check if a worktree has unpushed commits (commits not on remote)
has_unpushed_commits() {
    local wt_path="$1"
    local branch="$2"

    # If there's no upstream tracking branch, we can't push — treat as unpushed
    if ! git -C "$wt_path" rev-parse --abbrev-ref "@{upstream}" &>/dev/null 2>&1; then
        # No tracking branch: check if the branch exists on origin
        if git -C "$wt_path" ls-remote --exit-code origin "$branch" &>/dev/null 2>&1; then
            # Branch exists on remote; count commits ahead
            local ahead
            ahead=$(git -C "$wt_path" rev-list "origin/${branch}..HEAD" 2>/dev/null | wc -l | tr -d ' ')
            [[ "$ahead" -gt 0 ]]
        else
            # Branch not on remote at all — no unpushed commits by convention
            # (it was never pushed, so there's nothing to push that hasn't been accounted for)
            return 1
        fi
    else
        # Has upstream; count commits ahead of it
        local ahead
        ahead=$(git -C "$wt_path" rev-list "@{upstream}..HEAD" 2>/dev/null | wc -l | tr -d ' ')
        [[ "$ahead" -gt 0 ]]
    fi
}

# Check if a Claude process is active in a worktree path
is_claude_active() {
    local wt_path="$1"

    # Check 1: Look for .claude-session.lock with a live PID in the worktree
    local lock_file="$wt_path/.claude-session.lock"
    if [[ -f "$lock_file" ]]; then
        local lock_pid
        lock_pid=$(cat "$lock_file" 2>/dev/null || echo "")
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            return 0
        fi
    fi

    # Check 2: Look for claude processes whose working directory is within the worktree
    local pids
    pids=$(pgrep -f "[Cc]laude" 2>/dev/null || true)
    if [[ -z "$pids" ]]; then
        return 1
    fi

    local pid
    for pid in $pids; do
        # Check if this process has the worktree as its cwd (macOS: lsof -d cwd)
        local cwd
        cwd=$(lsof -p "$pid" -d cwd -Fn 2>/dev/null | grep "^n" | sed 's/^n//' || true)
        if [[ -n "$cwd" && ( "$cwd" == "$wt_path" || "$cwd" == "$wt_path/"* ) ]]; then
            return 0
        fi
        # Broader check: any open files in the worktree path (match exact prefix with /)
        if lsof -p "$pid" -Fn 2>/dev/null | grep -qE "^n${wt_path}/|^n${wt_path}$"; then
            return 0
        fi
    done

    return 1
}

# Delete a local branch, falling back to -D if -d fails (needed for branches
# whose only unmerged commits are ticket dir files already synced to main).
_delete_local_branch() {
    local repo="$1" branch="$2"
    git -C "$repo" branch -d "$branch" 2>/dev/null || \
    git -C "$repo" branch -D "$branch" 2>/dev/null
}

# ── Find main repo root ──────────────────────────────────────────────────────

# Resolve the repo root via git (works from any nested directory).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_REPO="$(git rev-parse --show-toplevel)"

# Verify this is a git repo
if ! git -C "$MAIN_REPO" rev-parse --git-dir &>/dev/null; then
    echo "Error: $MAIN_REPO is not a git repository."
    exit 1
fi

# Get the actual main worktree (might differ from MAIN_REPO if script is in a worktree)
MAIN_WORKTREE=$(git -C "$MAIN_REPO" worktree list --porcelain | head -1 | sed 's/^worktree //')

# Derive the main branch name from git symbolic-ref; fall back to actual HEAD branch, then 'main'
MAIN_BRANCH=$(git -C "$MAIN_WORKTREE" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||') || true
if [[ -z "$MAIN_BRANCH" ]]; then
    MAIN_BRANCH=$(git -C "$MAIN_WORKTREE" symbolic-ref --short HEAD 2>/dev/null || echo 'main')
fi

# Current directory (to avoid removing the worktree we're in)
CURRENT_DIR="$(pwd -P)"

# ── Gather worktree info ─────────────────────────────────────────────────────

# Arrays to hold worktree data
declare -a WT_NAMES=()
declare -a WT_PATHS=()
declare -a WT_BRANCHES=()
declare -a WT_MERGED=()      # "yes" or "no"
declare -a WT_CLEAN=()       # "yes" or "no"
declare -a WT_ACTIVE=()      # "yes" or "no"
declare -a WT_OLD_ENOUGH=()  # "yes" or "no" (older than AGE_HOURS hours)
declare -a WT_STASHED=()     # "yes" or "no" (has stashes)
declare -a WT_UNPUSHED=()    # "yes" or "no" (has unpushed commits)
declare -a WT_ACTIONS=()     # "remove" or reason to keep
declare -a WT_REMOVABLE=()   # "true" or "false"

# Count non-main worktrees for progress reporting. Each worktree block in
# --porcelain output starts with "worktree <path>"; one of those is main.
_wt_scan_total=$(($(git -C "$MAIN_WORKTREE" worktree list --porcelain | grep -c '^worktree ') - 1))
[[ "$_wt_scan_total" -lt 0 ]] && _wt_scan_total=0
_wt_scan_index=0
echo "Scanning $_wt_scan_total worktree(s)..." >&2

# Parse porcelain output
current_path=""
current_branch=""
while IFS= read -r line; do
    if [[ "$line" =~ ^worktree\ (.+) ]]; then
        current_path="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^branch\ refs/heads/(.+) ]]; then
        current_branch="${BASH_REMATCH[1]}"
    elif [[ -z "$line" && -n "$current_path" ]]; then
        # End of a worktree block — process it

        # Skip the main worktree
        if [[ "$current_path" == "$MAIN_WORKTREE" ]]; then
            current_path=""
            current_branch=""
            continue
        fi

        # Skip the .tickets-tracker worktree -- it holds the ticket system orphan
        # branch ("tickets") and must never be removed by cleanup (cf6d-54fd).
        _skip_tickets=false
        [[ "$current_branch" == "tickets" ]] && _skip_tickets=true
        case "$current_path" in
            */.tickets-tracker) _skip_tickets=true ;;
        esac
        if [[ "$_skip_tickets" == "true" ]]; then
            current_path=""
            current_branch=""
            continue
        fi

        local_name=$(basename "$current_path")
        _wt_scan_index=$((_wt_scan_index + 1))
        printf '  [%d/%d] %s\n' "$_wt_scan_index" "$_wt_scan_total" "$local_name" >&2
        WT_NAMES+=("$local_name")
        WT_PATHS+=("$current_path")
        WT_BRANCHES+=("${current_branch:-detached}")

        # Merge status: is the branch merged to main?
        if [[ -n "$current_branch" && "$current_branch" != "detached" ]]; then
            if is_branch_merged "$MAIN_WORKTREE" "$current_branch" "$MAIN_BRANCH"; then
                WT_MERGED+=("yes")
            else
                WT_MERGED+=("no")
            fi
        else
            WT_MERGED+=("no")
        fi

        # Clean status (no uncommitted changes)
        if [[ -z $(git -C "$current_path" status --porcelain 2>/dev/null || true) ]]; then
            WT_CLEAN+=("yes")
        else
            WT_CLEAN+=("no")
        fi

        # Active session
        if is_claude_active "$current_path"; then
            WT_ACTIVE+=("yes")
        else
            WT_ACTIVE+=("no")
        fi

        # Age check: must be older than AGE_HOURS to be eligible
        if is_old_enough "$current_path"; then
            WT_OLD_ENOUGH+=("yes")
        else
            WT_OLD_ENOUGH+=("no")
        fi

        # Stash check
        if has_stashes "$current_path"; then
            WT_STASHED+=("yes")
        else
            WT_STASHED+=("no")
        fi

        # Unpushed commits check
        if has_unpushed_commits "$current_path" "${current_branch:-}"; then
            WT_UNPUSHED+=("yes")
        else
            WT_UNPUSHED+=("no")
        fi


        current_path=""
        current_branch=""
    fi
done < <(git -C "$MAIN_WORKTREE" worktree list --porcelain; echo "")

# ── Determine actions ─────────────────────────────────────────────────────────

for i in "${!WT_NAMES[@]}"; do
    path="${WT_PATHS[$i]}"
    removable=true
    reason=""

    # Agent worktrees (.claude/worktrees/agent-*) are transient dispatch worktrees
    # created by the Agent tool. Discarded worktrees (harvest exit 1/2/3) are NOT
    # merged to main but should still be reclaimed (89fa-8baa, e4a3-2df7).
    _is_agent_worktree=false
    case "$path" in
        */.claude/worktrees/agent-*) _is_agent_worktree=true ;;
    esac

    # Safety: never remove the worktree we're currently in
    if [[ "$CURRENT_DIR" == "$path" || "$CURRENT_DIR" == "$path/"* ]]; then
        removable=false
        reason="current session"
    elif [[ "${WT_ACTIVE[$i]}" == "yes" ]]; then
        removable=false
        reason="active session"
    elif [[ "${WT_OLD_ENOUGH[$i]}" == "no" && "$_is_agent_worktree" == "false" ]]; then
        removable=false
        reason="too recent (<${AGE_HOURS}h)"
    elif [[ "${WT_MERGED[$i]}" == "no" && "$_is_agent_worktree" == "false" ]]; then
        removable=false
        reason="not merged"
    elif [[ "${WT_CLEAN[$i]}" == "no" && "$FORCE_DIRTY" != "true" && "$_is_agent_worktree" == "false" ]]; then
        removable=false
        reason="uncommitted changes"
    elif [[ "${WT_UNPUSHED[$i]}" == "yes" && "$_is_agent_worktree" == "false" ]]; then
        removable=false
        reason="unpushed commits"
    elif [[ "${WT_STASHED[$i]}" == "yes" ]]; then
        removable=false
        reason="has stashes"
    fi

    if [[ "$removable" == "true" ]]; then
        WT_ACTIONS+=("remove")
        WT_REMOVABLE+=("true")
    else
        WT_ACTIONS+=("keep ($reason)")
        WT_REMOVABLE+=("false")
    fi
done

# Log the start of this cleanup run
log_action "Cleanup run started (dry_run=${DRY_RUN}, non_interactive=${NON_INTERACTIVE}, worktrees_found=${#WT_NAMES[@]})"

# ── Display table ─────────────────────────────────────────────────────────────

count=${#WT_NAMES[@]}

if [[ $count -eq 0 ]]; then
    echo "No worktrees found (besides the main repo)."
    exit 0
fi

echo ""
echo -e "${BOLD}Worktree Cleanup${RESET}"
echo "================"
echo ""

# Color-pad: print text with color, padded to a fixed width.
# printf's width specifiers count ANSI escape bytes, so we pad the plain
# text first and then wrap with color codes.
cpad() {
    local width="$1" color="$2" text="$3"
    printf -v padded "%-${width}s" "$text"
    printf "%b" "${color}${padded}${RESET}"
}

# Column widths
W_NUM=4 W_NAME=32 W_MERGED=9 W_CLEAN=8 W_ACTIVE=9

# Header
printf "  "
cpad $W_NUM "$DIM" "#"
cpad $W_NAME "$DIM" "Name"
cpad $W_MERGED "$DIM" "Merged"
cpad $W_CLEAN "$DIM" "Clean"
cpad $W_ACTIVE "$DIM" "Active"
printf "%b\n" "${DIM}Action${RESET}"

# Rows
safe_count=0
safe_indices=()
for i in "${!WT_NAMES[@]}"; do
    num=$((i + 1))

    # Determine colors
    if [[ "${WT_REMOVABLE[$i]}" == "true" ]]; then
        action_display="${GREEN}✓ remove${RESET}"
        safe_count=$((safe_count + 1))
        safe_indices+=("$i")
    else
        action_display="${DIM}- ${WT_ACTIONS[$i]}${RESET}"
    fi

    merged_color="$YELLOW"
    clean_color="$YELLOW"
    merged_display="${WT_MERGED[$i]}"
    [[ "${WT_MERGED[$i]}" == "yes" ]] && merged_color="$GREEN"
    [[ "${WT_CLEAN[$i]}" == "yes" ]] && clean_color="$GREEN"

    printf "  "
    cpad $W_NUM "" "$num"
    cpad $W_NAME "" "${WT_NAMES[$i]}"
    cpad $W_MERGED "$merged_color" "$merged_display"
    cpad $W_CLEAN "$clean_color" "${WT_CLEAN[$i]}"
    if [[ "${WT_ACTIVE[$i]}" == "yes" ]]; then
        cpad $W_ACTIVE "$RED" "YES"
    else
        cpad $W_ACTIVE "" "no"
    fi
    printf "%b\n" "$action_display"
done

echo ""

if [[ $safe_count -eq 0 ]]; then
    echo "No worktrees are safe to remove."
    exit 0
fi

echo -e "${safe_count} worktree(s) safe to remove."
echo ""

# ── Selection ─────────────────────────────────────────────────────────────────

selected_indices=()

if [[ "$DRY_RUN" == "true" ]]; then
    # In dry-run mode, select all safe candidates to show what would happen
    selected_indices=("${safe_indices[@]}")
elif [[ "$SELECT_ALL" == "true" ]]; then
    if [[ "$FORCE" == "true" ]]; then
        selected_indices=("${safe_indices[@]}")
    else
        read -rp "Remove $safe_count safe worktree(s)? [y/N] " answer
        case "$answer" in
            [yY]|[yY][eE][sS]) selected_indices=("${safe_indices[@]}") ;;
            *) echo "Aborted."; exit 0 ;;
        esac
    fi
else
    # Interactive mode
    read -rp "Remove $safe_count safe worktree(s)? [y/N/s(elect)] " answer
    case "$answer" in
        [yY]|[yY][eE][sS])
            selected_indices=("${safe_indices[@]}")
            ;;
        [sS]|select)
            echo ""
            echo "Select worktrees to remove (enter numbers separated by spaces):"
            for idx in "${safe_indices[@]}"; do
                num=$((idx + 1))
                echo "  $num) ${WT_NAMES[$idx]}"
            done
            echo ""
            read -rp "Numbers (e.g., 1 3): " selections
            for sel in $selections; do
                sel_idx=$((sel - 1))
                # Verify this is a safe candidate
                for safe_idx in "${safe_indices[@]}"; do
                    if [[ $sel_idx -eq $safe_idx ]]; then
                        selected_indices+=("$sel_idx")
                        break
                    fi
                done
            done
            if [[ ${#selected_indices[@]} -eq 0 ]]; then
                echo "No valid selections. Aborted."
                exit 0
            fi
            ;;
        *)
            echo "Aborted."
            exit 0
            ;;
    esac
fi

if [[ ${#selected_indices[@]} -eq 0 ]]; then
    echo "Nothing to remove."
    exit 0
fi

# ── Removal ───────────────────────────────────────────────────────────────────

removed_count=0
total_freed_kb=0
removed_branches=()

for idx in "${selected_indices[@]}"; do
    name="${WT_NAMES[$idx]}"
    path="${WT_PATHS[$idx]}"
    branch="${WT_BRANCHES[$idx]}"
    clean="${WT_CLEAN[$idx]}"

    prefix=""
    if [[ "$DRY_RUN" == "true" ]]; then
        prefix="${CYAN}[DRY RUN]${RESET} "
    fi

    # If dirty and --force-dirty, create backup first
    if [[ "$clean" == "no" && "$FORCE_DIRTY" == "true" ]]; then
        backup_file="${BACKUP_DIR}/${name}-$(date +%Y%m%d-%H%M%S).patch"
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${prefix}Would backup uncommitted changes to: $backup_file"
        else
            mkdir -p "$BACKUP_DIR"
            # Create a combined diff of staged + unstaged changes
            (
                cd "$path"
                git diff HEAD 2>/dev/null || true
                git diff --cached 2>/dev/null || true
                # Include untracked files
                git ls-files --others --exclude-standard | while IFS= read -r f; do
                    echo "--- /dev/null"
                    echo "+++ b/$f"
                    cat "$f" 2>/dev/null | sed 's/^/+/' || true
                done
            ) > "$backup_file" 2>/dev/null || true
            echo -e "  Backed up uncommitted changes to: ${CYAN}${backup_file}${RESET}"
        fi
    fi

    # Estimate size before removal
    size_kb=$(estimate_size_kb "$path")

    # Stop Docker containers/networks for this worktree to prevent network exhaustion
    if [[ "$DRY_RUN" != "true" ]] && command -v docker &>/dev/null && [[ -n "$CONFIG_COMPOSE_DB_FILE" ]] && [[ -n "$CONFIG_COMPOSE_PROJECT" ]]; then
        compose_file="$path/$CONFIG_COMPOSE_DB_FILE"
        if [[ -f "$compose_file" ]]; then
            COMPOSE_PROJECT_NAME="${CONFIG_COMPOSE_PROJECT}${name}" docker compose -f "$compose_file" down 2>/dev/null || true
        fi
    fi

    echo -ne "${prefix}Removing ${name}... "

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "would remove (~$(format_kb "$size_kb"))"
        log_action "DRY RUN: would remove worktree '${name}' (~$(format_kb "$size_kb"), branch=${branch})"
        total_freed_kb=$((total_freed_kb + size_kb))
        removed_branches+=("$branch")
    else
        remove_ok=false
        # Belt-and-suspenders unlock before remove: Claude Code agent worktrees
        # carry a harness-written lock file whose PID is dead once the sub-agent
        # exits. `git worktree remove --force` handles locks in modern git, but
        # an explicit unlock is a harmless no-op when unlocked and removes any
        # remaining doubt for older git versions.
        git worktree unlock "$path" 2>/dev/null || true
        if git worktree remove "$path" --force 2>/dev/null; then
            remove_ok=true
        else
            echo -e "${RED}failed${RESET}"
            log_action "FAILED to remove worktree '${name}' (branch=${branch})"
            continue
        fi

        if [[ "$remove_ok" == "true" ]]; then
            echo -e "${GREEN}done${RESET} (~$(format_kb "$size_kb"))"
            log_action "REMOVED worktree '${name}' (~$(format_kb "$size_kb"), branch=${branch})"
            removed_count=$((removed_count + 1))
            total_freed_kb=$((total_freed_kb + size_kb))
            removed_branches+=("$branch")
            # Clean up per-worktree merge state file to prevent stale state accumulation
            rm -f "/tmp/merge-to-main-state-${name}.json"
        fi
    fi
done

# Prune worktree metadata
if [[ "$DRY_RUN" != "true" && $removed_count -gt 0 ]]; then
    git -C "$MAIN_WORKTREE" worktree prune 2>/dev/null || true
fi

# ── Branch cleanup ────────────────────────────────────────────────────────────

if [[ "$INCLUDE_BRANCHES" == "true" && ${#removed_branches[@]} -gt 0 ]]; then
    echo ""
    branches_deleted=0
    for branch in "${removed_branches[@]}"; do
        [[ "$branch" == "detached" || "$branch" == "$MAIN_BRANCH" || "$branch" == "master" ]] && continue

        # Check if branch is merged
        merged_label=""
        if is_branch_merged "$MAIN_WORKTREE" "$branch" "$MAIN_BRANCH"; then
            merged_label=" (merged to main)"
        else
            merged_label=" (NOT merged to main)"
        fi

        # Check if remote branch exists
        has_remote=false
        if git -C "$MAIN_WORKTREE" ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
            has_remote=true
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            prefix="${CYAN}[DRY RUN]${RESET} "
            local_remote_label="local"
            [[ "$has_remote" == "true" ]] && local_remote_label="local + remote"
            echo -e "${prefix}Would delete branch '${branch}' (${local_remote_label})${merged_label}"
            continue
        fi

        if [[ "$FORCE" == "true" ]]; then
            if _delete_local_branch "$MAIN_WORKTREE" "$branch"; then
                echo -e "Deleted local branch '${branch}'${merged_label}"
                branches_deleted=$((branches_deleted + 1))
            fi
            if [[ "$has_remote" == "true" ]]; then
                if git -C "$MAIN_WORKTREE" push origin --delete "$branch" 2>/dev/null; then
                    echo -e "Deleted remote branch 'origin/${branch}'"
                else
                    echo -e "${RED}Failed to delete remote branch 'origin/${branch}'${RESET}"
                fi
            fi
        else
            local_remote_label="local"
            [[ "$has_remote" == "true" ]] && local_remote_label="local + remote"
            read -rp "Delete branch '${branch}' (${local_remote_label})?${merged_label} [y/N] " answer
            case "$answer" in
                [yY]|[yY][eE][sS])
                    if _delete_local_branch "$MAIN_WORKTREE" "$branch"; then
                        echo -e "Deleted local branch '${branch}'${merged_label}"
                        branches_deleted=$((branches_deleted + 1))
                    else
                        echo -e "${RED}Failed to delete local branch '${branch}'${RESET}"
                    fi
                    if [[ "$has_remote" == "true" ]]; then
                        if git -C "$MAIN_WORKTREE" push origin --delete "$branch" 2>/dev/null; then
                            echo -e "Deleted remote branch 'origin/${branch}'"
                        else
                            echo -e "${RED}Failed to delete remote branch 'origin/${branch}'${RESET}"
                        fi
                    fi
                    ;;
                *) echo "Skipped branch '${branch}'" ;;
            esac
        fi
    done

    if [[ $branches_deleted -gt 0 && "$DRY_RUN" != "true" ]]; then
        echo -e "Deleted $branches_deleted branch(es)."
    fi
fi

# ── Clean up orphaned worktree-* branches ────────────────────────────────

# Local branches named worktree-* can linger after worktrees are removed by
# other means (manual git worktree remove, session crashes, etc.). Find any
# that no longer have an associated worktree and offer to delete them.
if [[ "$INCLUDE_BRANCHES" == "true" ]]; then
    # Build set of branch names still associated with a live worktree
    declare -A live_wt_branches=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^branch\ refs/heads/(.+) ]]; then
            live_wt_branches["${BASH_REMATCH[1]}"]=1
        fi
    done < <(git -C "$MAIN_WORKTREE" worktree list --porcelain 2>/dev/null)

    # Also exclude branches we already handled above (removed_branches)
    declare -A already_handled=()
    if [[ ${#removed_branches[@]} -gt 0 ]]; then
        for b in "${removed_branches[@]}"; do
            already_handled["$b"]=1
        done
    fi

    # Find orphaned worktree-* branches
    orphan_branches=()
    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        # Skip if still associated with a live worktree
        [[ -n "${live_wt_branches[$branch]+x}" ]] && continue
        # Skip if already handled in the section above
        [[ -n "${already_handled[$branch]+x}" ]] && continue
        orphan_branches+=("$branch")
    done < <(git -C "$MAIN_WORKTREE" branch --list "${CONFIG_BRANCH_PATTERN:-worktree-*}" --format='%(refname:short)' 2>/dev/null)

    if [[ ${#orphan_branches[@]} -gt 0 ]]; then
        echo ""
        echo -e "${BOLD}Orphaned worktree-* branches (no associated worktree):${RESET}"
        orphan_deleted=0
        for branch in "${orphan_branches[@]}"; do
            merged_label=""
            if is_branch_merged "$MAIN_WORKTREE" "$branch" "$MAIN_BRANCH"; then
                merged_label=" (merged to main)"
            else
                merged_label=" (NOT merged to main)"
            fi

            has_remote=false
            if git -C "$MAIN_WORKTREE" ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
                has_remote=true
            fi

            if [[ "$DRY_RUN" == "true" ]]; then
                prefix="${CYAN}[DRY RUN]${RESET} "
                local_remote_label="local"
                [[ "$has_remote" == "true" ]] && local_remote_label="local + remote"
                echo -e "${prefix}Would delete orphaned branch '${branch}' (${local_remote_label})${merged_label}"
                continue
            fi

            if [[ "$FORCE" == "true" ]]; then
                if git -C "$MAIN_WORKTREE" branch -d "$branch" 2>/dev/null; then
                    echo -e "Deleted orphaned local branch '${branch}'${merged_label}"
                    orphan_deleted=$((orphan_deleted + 1))
                    if [[ "$has_remote" == "true" ]]; then
                        if git -C "$MAIN_WORKTREE" push origin --delete "$branch" 2>/dev/null; then
                            echo -e "Deleted orphaned remote branch 'origin/${branch}'"
                        else
                            echo -e "${RED}Failed to delete remote branch 'origin/${branch}'${RESET}"
                        fi
                    fi
                else
                    echo -e "${YELLOW}Skipped '${branch}' — not fully merged (use git branch -D to force)${RESET}"
                fi
            else
                local_remote_label="local"
                [[ "$has_remote" == "true" ]] && local_remote_label="local + remote"
                read -rp "Delete orphaned branch '${branch}' (${local_remote_label})?${merged_label} [y/N] " answer
                case "$answer" in
                    [yY]|[yY][eE][sS])
                        if git -C "$MAIN_WORKTREE" branch -d "$branch" 2>/dev/null; then
                            echo -e "Deleted orphaned local branch '${branch}'${merged_label}"
                            orphan_deleted=$((orphan_deleted + 1))
                            if [[ "$has_remote" == "true" ]]; then
                                if git -C "$MAIN_WORKTREE" push origin --delete "$branch" 2>/dev/null; then
                                    echo -e "Deleted orphaned remote branch 'origin/${branch}'"
                                else
                                    echo -e "${RED}Failed to delete remote branch 'origin/${branch}'${RESET}"
                                fi
                            fi
                        else
                            echo -e "${YELLOW}Skipped '${branch}' — not fully merged (use git branch -D to force)${RESET}"
                        fi
                        ;;
                    *) echo "Skipped branch '${branch}'" ;;
                esac
            fi
        done

        if [[ $orphan_deleted -gt 0 && "$DRY_RUN" != "true" ]]; then
            echo -e "Deleted $orphan_deleted orphaned branch(es)."
        fi
    fi
fi

# ── Clean up orphaned Docker networks ────────────────────────────────────

# Docker networks named ${CONFIG_COMPOSE_PROJECT}worktree-*_default accumulate when worktrees
# are removed without running `docker compose down` first. Prune any that no
# longer have a corresponding worktree.
if [[ "$DRY_RUN" != "true" && $removed_count -gt 0 ]] && command -v docker &>/dev/null && [[ -n "$CONFIG_COMPOSE_DB_FILE" ]] && [[ -n "$CONFIG_COMPOSE_PROJECT" ]]; then
    orphaned=$(docker network ls --filter "name=${CONFIG_COMPOSE_PROJECT}" --format '{{.Name}}' 2>/dev/null || true)
    if [[ -n "$orphaned" ]]; then
        # Get list of remaining worktree names
        remaining_wts=$(git -C "$MAIN_WORKTREE" worktree list --porcelain 2>/dev/null \
            | grep '^worktree ' | sed 's/^worktree //' | xargs -I{} basename {} || true)
        while IFS= read -r net; do
            # Extract worktree name: ${CONFIG_COMPOSE_PROJECT}<name>_default → <name>
            wt_from_net=$(echo "$net" | sed "s/^${CONFIG_COMPOSE_PROJECT}//; s/_default\$//")
            if ! echo "$remaining_wts" | grep -qx "$wt_from_net"; then
                docker network rm "$net" 2>/dev/null && \
                    echo -e "Removed orphaned Docker network: $net" || true
            fi
        done <<< "$orphaned"
    fi
fi

# ── Clean up .gitignore ──────────────────────────────────────────────────

# Remove specific branch-pattern entries from .gitignore (the wildcard pattern covers them).
# The branch pattern prefix is derived from CONFIG_BRANCH_PATTERN (default: worktree-*).
GITIGNORE="$MAIN_WORKTREE/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
    # Derive the prefix and wildcard from CONFIG_BRANCH_PATTERN:
    #   CONFIG_BRANCH_PATTERN=worktree-*  →  _bp_prefix=worktree-  _bp_wildcard=worktree-*/
    _bp_pattern="${CONFIG_BRANCH_PATTERN:-worktree-*}"
    _bp_prefix="${_bp_pattern%\*}"        # strip trailing '*' to get the prefix
    _bp_wildcard="${_bp_pattern}/"        # e.g. 'worktree-*/'
    # Remove lines starting with the branch prefix EXCEPT the wildcard pattern line
    # Also remove comment lines that immediately precede a removed branch line
    tmp_gitignore=$(mktemp)
    awk -v wildcard="^${_bp_wildcard//\*/\\*}" -v prefix="^${_bp_prefix}" '
        $0 ~ wildcard { print; next }
        $0 ~ prefix { skipped=1; next }
        { print }
    ' "$GITIGNORE" > "$tmp_gitignore"

    if ! diff -q "$GITIGNORE" "$tmp_gitignore" &>/dev/null; then
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${CYAN}[DRY RUN]${RESET} Would clean up specific worktree entries from .gitignore"
        else
            mv "$tmp_gitignore" "$GITIGNORE"
            echo -e "Cleaned up specific worktree entries from .gitignore"
        fi
    else
        rm -f "$tmp_gitignore"
    fi
    rm -f "$tmp_gitignore" 2>/dev/null || true
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${CYAN}[DRY RUN]${RESET} Would remove ${#selected_indices[@]} worktree(s), freeing ~$(format_kb "$total_freed_kb") estimated disk space."
    log_action "DRY RUN complete: ${#selected_indices[@]} worktree(s) would be removed (~$(format_kb "$total_freed_kb"))"
else
    echo -e "Removed ${removed_count} worktree(s), freed ~$(format_kb "$total_freed_kb") estimated disk space."
    log_action "Cleanup complete: removed ${removed_count} worktree(s), freed ~$(format_kb "$total_freed_kb")"
fi
