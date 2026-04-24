#!/usr/bin/env bash
# hooks/lib/pre-bash-functions.sh
# Sourceable function definitions for the PreToolUse Bash hooks.
#
# Each function follows the hook contract:
#   Input:  JSON string passed as $1
#   Return 0: allow — continue to next hook
#   Return 2: block/deny — dispatcher stops, outputs permissionDecision
#   stderr: warnings (always allowed; passed through by dispatcher)
#   stdout: permissionDecision message (only consumed when return 2)
#
# Functions defined:
#   hook_test_failure_guard      — block commit when test status files contain FAILED
#   hook_commit_failure_tracker  — warn at commit time about untracked failures
#   hook_worktree_bash_guard     — block cd into main repo from worktree
#   hook_worktree_edit_guard     — block mkdir targeting main repo from worktree
#   hook_review_integrity_guard  — block direct writes to review-status files
#   hook_blocked_test_command    — block broad test commands, redirect to validate.sh
#   hook_tickets_tracker_bash_guard — block Bash commands referencing .tickets-tracker/
#
# NOTE: The old PreToolUse review gate was removed in Story 1idf. Review gate
#   enforcement is now handled by the two-layer gate:
#   - Layer 1: hooks/pre-commit-review-gate.sh (git pre-commit hook)
#   - Layer 2: hooks/lib/review-gate-bypass-sentinel.sh (PreToolUse)
#
# Usage:
#   source hooks/lib/pre-bash-functions.sh

# Guard: only load once
[[ "${_PRE_BASH_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_PRE_BASH_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_PRE_BASH_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PRE_BASH_FUNC_DIR/deps.sh"

# Source config-paths.sh for portable path resolution (idempotent via its own guard)
if [ -f "$_PRE_BASH_FUNC_DIR/config-paths.sh" ]; then
    source "$_PRE_BASH_FUNC_DIR/config-paths.sh"
fi

# ---------------------------------------------------------------------------
# hook_test_failure_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: block git commit when any test status file contains "FAILED".
#
# Reads $ARTIFACTS_DIR/test-status/*.status files. Each file's first line is
# checked — only the exact string "FAILED" triggers a block. Missing files,
# empty files, or other content (PASSED, ERROR, etc.) are silently allowed.
#
# Exempt commits: WIP, merge, pre-compact, checkpoint (same as review_gate).
hook_test_failure_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"test-failure-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Only act on Bash tool calls
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Bash" ]]; then
        return 0
    fi

    # Only act on git commit commands
    local COMMAND FIRST_LINE
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    FIRST_LINE=$(echo "$COMMAND" | head -1)
    if ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+commit([[:space:]]|$) ]] && \
       ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+-[^[:space:]]+.*[[:space:]]commit([[:space:]]|$) ]]; then
        return 0
    fi

    # Exempt: WIP, merge, pre-compact, checkpoint
    if [[ "$COMMAND" =~ [Ww][Ii][Pp] ]] || [[ "$COMMAND" =~ --no-edit ]] || \
       [[ "$COMMAND" =~ git[[:space:]].*merge[[:space:]] ]] || \
       [[ "$COMMAND" =~ pre-compact ]] || [[ "$COMMAND" =~ checkpoint ]]; then
        return 0
    fi

    # Resolve artifacts dir
    local ARTIFACTS_DIR_RESOLVED="${ARTIFACTS_DIR:-}"
    if [[ -z "$ARTIFACTS_DIR_RESOLVED" ]]; then
        ARTIFACTS_DIR_RESOLVED=$(get_artifacts_dir)
    fi
    local STATUS_DIR="$ARTIFACTS_DIR_RESOLVED/test-status"

    # No status directory or no status files → allow (tests never run — CI catches)
    if [[ ! -d "$STATUS_DIR" ]]; then
        return 0
    fi

    local -a FAILED_TARGETS=()
    local status_file first_line
    for status_file in "$STATUS_DIR"/*.status; do
        [[ -f "$status_file" ]] || continue
        first_line=$(head -n 1 "$status_file" 2>/dev/null || echo "")
        if [[ "$first_line" == "FAILED" ]]; then
            FAILED_TARGETS+=("$(basename "$status_file" .status)")
        fi
    done

    if [[ ${#FAILED_TARGETS[@]} -gt 0 ]]; then
        echo "BLOCKED: Test failures detected. Fix before committing." >&2
        echo "Failed targets: ${FAILED_TARGETS[*]}" >&2
        echo "Status files: $STATUS_DIR/*.status" >&2
        trap - ERR; return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_commit_failure_tracker
# ---------------------------------------------------------------------------
# PreToolUse hook: warn at git commit time if validation failures exist
# without corresponding open tracking issues.
# NEVER BLOCKS — warnings only.
hook_commit_failure_tracker() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"commit-failure-tracker\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Only act on Bash tool calls
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Bash" ]]; then
        return 0
    fi

    # Only act on git commit commands
    local COMMAND FIRST_LINE
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    FIRST_LINE=$(echo "$COMMAND" | head -1)
    if ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+commit([[:space:]]|$) ]] && \
       ! [[ "$FIRST_LINE" =~ (^|[[:space:]|&;])git[[:space:]]+-[^[:space:]]+.*[[:space:]]commit([[:space:]]|$) ]] && \
       [[ "$FIRST_LINE" != *"merge-to-main"* ]]; then
        return 0
    fi

    # Exempt: WIP, merge, pre-compact
    if [[ "$COMMAND" =~ [Ww][Ii][Pp] ]] || [[ "$COMMAND" =~ --no-edit ]] || \
       [[ "$COMMAND" =~ git[[:space:]].*merge[[:space:]] ]] || \
       [[ "$COMMAND" =~ pre-compact ]] || [[ "$COMMAND" =~ checkpoint ]]; then
        return 0
    fi

    # Read config-driven issue tracker commands (with fallback defaults)
    local _SEARCH_CMD_FROM_ENV="${SEARCH_CMD:-}"
    local _SEARCH_CMD="${SEARCH_CMD:-grep -rl}"
    local _READ_CONFIG=""
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh" ]]; then  # shim-exempt: hook lib resolves plugin scripts via CLAUDE_PLUGIN_ROOT, not repo shim
        _READ_CONFIG="$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh"  # shim-exempt: hook lib resolves plugin scripts via CLAUDE_PLUGIN_ROOT
    fi
    # Config file: prefer CLAUDE_PLUGIN_ROOT/.claude/dso-config.conf when set and present,
    # so tests can pass an isolated config without affecting the real repo config.
    local _CT_CONFIG_FILE=""
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf" ]]; then
        _CT_CONFIG_FILE="${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf"
    fi

    # Apply config overrides (defer Python spawn; don't override caller-supplied env vars)
    if [[ -n "$_READ_CONFIG" ]] && [[ -z "$_SEARCH_CMD_FROM_ENV" ]]; then
        local _SEARCH
        if [[ -n "$_CT_CONFIG_FILE" ]]; then
            _SEARCH=$("$_READ_CONFIG" issue_tracker.search_cmd "$_CT_CONFIG_FILE" 2>/dev/null || echo '')
        else
            _SEARCH=$("$_READ_CONFIG" issue_tracker.search_cmd 2>/dev/null || echo '')
        fi
        [[ -n "$_SEARCH" ]] && _SEARCH_CMD="$_SEARCH"
    fi
    if [[ "$_SEARCH_CMD" != "grep -rl" ]] && [[ "${_SEARCH_CMD:-}" != "" ]]; then
        echo "# issue_tracker.search_cmd: $_SEARCH_CMD" >&2
    fi

    # Check validation state
    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    local ARTIFACTS_DIR_RESOLVED="${ARTIFACTS_DIR:-}"
    if [[ -z "$ARTIFACTS_DIR_RESOLVED" ]]; then
        ARTIFACTS_DIR_RESOLVED=$(get_artifacts_dir)
    fi
    local VALIDATION_STATE_FILE="$ARTIFACTS_DIR_RESOLVED/status"

    # Backward-compat: also check old-style artifacts path
    local _OLD_ARTIFACTS_DIR
    _OLD_ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-$(basename "$REPO_ROOT")"
    if [[ ! -f "$VALIDATION_STATE_FILE" ]] && [[ -f "$_OLD_ARTIFACTS_DIR/status" ]]; then
        VALIDATION_STATE_FILE="$_OLD_ARTIFACTS_DIR/status"
    elif [[ -f "$VALIDATION_STATE_FILE" ]] && [[ -f "$_OLD_ARTIFACTS_DIR/status" ]]; then
        local _OLD_STATUS
        _OLD_STATUS=$(head -n 1 "$_OLD_ARTIFACTS_DIR/status" 2>/dev/null || echo "")
        if [[ "$_OLD_STATUS" == "failed" ]]; then
            VALIDATION_STATE_FILE="$_OLD_ARTIFACTS_DIR/status"
        fi
    fi

    if [[ ! -f "$VALIDATION_STATE_FILE" ]]; then
        return 0
    fi

    local VALIDATION_STATUS
    VALIDATION_STATUS=$(head -n 1 "$VALIDATION_STATE_FILE" 2>/dev/null || echo "")
    if [[ "$VALIDATION_STATUS" != "failed" ]]; then
        return 0
    fi

    # Read failed checks from status file
    local FAILED_CHECKS_RAW
    FAILED_CHECKS_RAW=$(grep '^failed_checks=' "$VALIDATION_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

    local -a FAILED_CATEGORIES=()
    if [[ -n "$FAILED_CHECKS_RAW" ]]; then
        IFS=',' read -ra FAILED_CATEGORIES <<< "$FAILED_CHECKS_RAW"
    else
        FAILED_CATEGORIES+=("validation")
    fi

    # Resolve tickets directory (TICKETS_DIR_OVERRIDE allows test injection)
    local TICKETS_DIR
    TICKETS_DIR="${TICKETS_DIR_OVERRIDE:-$(git rev-parse --show-toplevel 2>/dev/null)/.tickets}"

    # Quick check: do open issues exist for each category?
    local -a UNTRACKED=()
    local category
    for category in "${FAILED_CATEGORIES[@]}"; do
        local RESULT=""
        # Search tickets directory for matching ticket files
        RESULT=$($_SEARCH_CMD "$category failure" "$TICKETS_DIR" 2>/dev/null | head -1 || echo "")
        if [[ -z "$RESULT" ]]; then
            UNTRACKED+=("$category")
        fi
    done

    if [[ ${#UNTRACKED[@]} -eq 0 ]]; then
        return 0
    fi

    # Warn (never block) about untracked failures
    echo "# WARNING: UNTRACKED VALIDATION FAILURES" >&2
    echo "" >&2
    echo "These failures have no open tracking issues:" >&2
    for category in "${UNTRACKED[@]}"; do
        echo "  - $category" >&2
    done
    echo "" >&2
    echo "Tickets are auto-created by /dso:end Step 2.9 (sweep_validation_failures)." >&2
    echo "To create now: .claude/scripts/dso ticket create bug \"<check> validation failure\"" >&2
    echo "" >&2

    # Never block
    return 0
}

# ---------------------------------------------------------------------------
# is_formatting_only_change
# ---------------------------------------------------------------------------
# Returns 0 if the diff between old_diff and new_diff is whitespace/formatting only.
# Returns 1 if there are any substantive (non-whitespace) code changes.
#
# "Formatting only" means: after stripping trailing whitespace from every line
# and removing blank lines, the two diffs are identical.
#
# Usage:
#   is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF"
#   if is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF"; then
#       echo "formatting only"
#   fi
is_formatting_only_change() {
    local old_diff="$1"
    local new_diff="$2"

    # Normalize both diffs: strip trailing whitespace from each line, remove blank lines,
    # and remove 'index' lines (blob hashes change with any content change, even whitespace-only)
    local old_norm new_norm
    old_norm=$(printf '%s' "$old_diff" | sed 's/[[:space:]]*$//' | grep -v '^$' | grep -v '^index ' || true)
    new_norm=$(printf '%s' "$new_diff" | sed 's/[[:space:]]*$//' | grep -v '^$' | grep -v '^index ' || true)

    if [[ "$old_norm" == "$new_norm" ]]; then
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# hook_worktree_bash_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: block Bash commands that cd into the main repo from a worktree.
hook_worktree_bash_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"worktree-bash-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Not a worktree? Allow everything.
    if ! is_worktree; then
        return 0
    fi

    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        return 0
    fi

    # Resolve paths
    local WORKTREE_ROOT MAIN_GIT_DIR MAIN_REPO_ROOT
    WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$WORKTREE_ROOT" ]]; then
        return 0
    fi

    MAIN_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    if [[ -z "$MAIN_GIT_DIR" ]]; then
        return 0
    fi

    MAIN_GIT_DIR=$(cd "$WORKTREE_ROOT" && cd "$MAIN_GIT_DIR" && pwd)
    MAIN_REPO_ROOT=$(dirname "$MAIN_GIT_DIR")
    WORKTREE_ROOT="${WORKTREE_ROOT%/}"
    MAIN_REPO_ROOT="${MAIN_REPO_ROOT%/}"

    # Does the command reference the main repo at all?
    if [[ "$COMMAND" != *"$MAIN_REPO_ROOT"* ]]; then
        return 0
    fi

    # Allow-list: safe scripts
    if [[ "$COMMAND" == *"merge-to-main.sh"* ]] || \
       [[ "$COMMAND" == *"resolve-conflicts.sh"* ]]; then
        return 0
    fi

    # Allow-list: read-only patterns after cd to main repo
    local CMD_AFTER_CD
    CMD_AFTER_CD=$(echo "$COMMAND" | sed -n "s|.*cd[[:space:]]*['\"]\\?${MAIN_REPO_ROOT}['\"]\\?[[:space:]]*&&[[:space:]]*||p")
    if [[ -n "$CMD_AFTER_CD" ]]; then
        if echo "$CMD_AFTER_CD" | grep -qE "^[[:space:]]*(cat|head|tail|less|more|ls|find|stat|wc|file) " || \
           echo "$CMD_AFTER_CD" | grep -qE "git[[:space:]]+(log|diff|show|status|rev-parse|branch|tag|ls-files|describe|remote|fetch|symbolic-ref|for-each-ref)" || \
           echo "$CMD_AFTER_CD" | grep -qE "scripts/(validate|ci-status)"; then
            return 0
        fi
    fi

    # Check if command cd's into the main repo
    if echo "$COMMAND" | grep -qE "cd[[:space:]]+(\"$MAIN_REPO_ROOT\"|'$MAIN_REPO_ROOT'|$MAIN_REPO_ROOT)([[:space:]]|[;&\|]|$)"; then
        echo "BLOCKED: Bash command cd's into the main repo from a worktree session." >&2
        echo "" >&2
        echo "CLAUDE.md rule 11: \"Never edit main repo files from a worktree session.\"" >&2
        echo "  Command:   cd $MAIN_REPO_ROOT ..." >&2
        echo "  Main repo: $MAIN_REPO_ROOT" >&2
        echo "  Worktree:  $WORKTREE_ROOT" >&2
        echo "" >&2
        echo "HOW TO FIX:" >&2
        echo "  • Run the same command from the worktree root (current working directory)." >&2
        echo "  • Use REPO_ROOT=\$(git rev-parse --show-toplevel) instead of a hardcoded path." >&2
        echo "  • ticket commands work from any directory — drop 'cd MAIN_REPO && ticket ...' prefix." >&2
        echo "  • To merge worktree changes to main: \$REPO_ROOT/scripts/merge-to-main.sh (allow-listed)." >&2
        echo "  • To read a main-repo file: use the Read tool with the absolute path." >&2
        trap - ERR; return 2
    fi

    # Block git plumbing commands without -C targeting the main repo
    if echo "$COMMAND" | grep -qE "git[[:space:]]+(read-tree|write-tree|commit-tree)"; then
        if echo "$COMMAND" | grep -qE "git[[:space:]]+-C[[:space:]]+['\"]?${MAIN_REPO_ROOT}['\"]?[[:space:]]+(read-tree|write-tree|commit-tree)"; then
            return 0
        fi
        echo "BLOCKED: git plumbing command in worktree context without -C targeting the main repo." >&2
        echo "" >&2
        echo "git read-tree/write-tree/commit-tree can produce corrupt trees when run" >&2
        echo "directly in a worktree. Use 'git -C <main-repo-path>' to target the main repo." >&2
        echo "  Command:   $COMMAND" >&2
        echo "  Main repo: $MAIN_REPO_ROOT" >&2
        echo "  Worktree:  $WORKTREE_ROOT" >&2
        echo "" >&2
        echo "HOW TO FIX:" >&2
        echo "  • Use 'git -C $MAIN_REPO_ROOT read-tree ...' instead of bare 'git read-tree ...'" >&2
        echo "  • Use explicit '-C <repo-root>' to target the correct repository." >&2
        trap - ERR; return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_worktree_edit_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: block Edit/Write/Bash(mkdir) calls targeting main repo from a worktree.
hook_worktree_edit_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"worktree-edit-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Not a worktree? Allow everything.
    if ! is_worktree; then
        return 0
    fi

    # Resolve paths
    local WORKTREE_ROOT MAIN_GIT_DIR MAIN_REPO_ROOT
    WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$WORKTREE_ROOT" ]]; then
        return 0
    fi

    MAIN_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    if [[ -z "$MAIN_GIT_DIR" ]]; then
        return 0
    fi

    MAIN_GIT_DIR=$(cd "$WORKTREE_ROOT" && cd "$MAIN_GIT_DIR" && pwd)
    MAIN_REPO_ROOT=$(dirname "$MAIN_GIT_DIR")
    WORKTREE_ROOT="${WORKTREE_ROOT%/}"
    MAIN_REPO_ROOT="${MAIN_REPO_ROOT%/}"

    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')

    # Bash tool: block mkdir targeting main repo
    if [[ "$TOOL_NAME" == "Bash" ]]; then
        local COMMAND
        COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
        if [[ -z "$COMMAND" ]]; then
            return 0
        fi
        if echo "$COMMAND" | grep -qE "mkdir[[:space:]].*['\"]?${MAIN_REPO_ROOT}"; then
            echo "BLOCKED: Bash mkdir targeting main repo from worktree session." >&2
            echo "" >&2
            echo "CLAUDE.md rule 11: \"Never edit main repo files from a worktree session.\"" >&2
            echo "  Command:   $COMMAND" >&2
            echo "  Main repo: $MAIN_REPO_ROOT" >&2
            echo "  Worktree:  $WORKTREE_ROOT" >&2
            echo "" >&2
            echo "HOW TO FIX:" >&2
            echo "  Use REPO_ROOT=\$(git rev-parse --show-toplevel) to write to the worktree." >&2
            echo "  Example: mkdir -p \"\$REPO_ROOT/designs/<uuid>\"" >&2
            trap - ERR; return 2
        fi
        return 0
    fi

    local FILE_PATH
    FILE_PATH=$(parse_json_field "$INPUT" '.tool_input.file_path')
    if [[ -z "$FILE_PATH" ]]; then
        return 0
    fi

    # File is inside the worktree? Allow.
    if [[ "$FILE_PATH" == "$WORKTREE_ROOT"/* || "$FILE_PATH" == "$WORKTREE_ROOT" ]]; then
        return 0
    fi

    # File is inside a sub-agent worktree (.claude/worktrees/)? Allow.
    # Agent worktrees are isolated working directories, not main-repo files.
    if [[ "$FILE_PATH" == "$MAIN_REPO_ROOT/.claude/worktrees/"* ]]; then
        return 0
    fi

    # File is inside the main repo? Block.
    if [[ "$FILE_PATH" == "$MAIN_REPO_ROOT"/* || "$FILE_PATH" == "$MAIN_REPO_ROOT" ]]; then
        [[ -z "$TOOL_NAME" ]] && TOOL_NAME="Edit/Write"
        echo "BLOCKED: $TOOL_NAME targeting main repo from worktree session." >&2
        echo "" >&2
        echo "CLAUDE.md rule 11: \"Never edit main repo files from a worktree session.\"" >&2
        echo "  Target file: $FILE_PATH" >&2
        echo "  Main repo:   $MAIN_REPO_ROOT" >&2
        echo "  Worktree:    $WORKTREE_ROOT" >&2
        echo "" >&2
        echo "Edit the file on the worktree branch instead — the merge will propagate it to main." >&2
        trap - ERR; return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_tool_use_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: warn when cat/head/tail/grep/rg are used via Bash instead
# of the dedicated Read/Grep tools. WARNING ONLY.
hook_tool_use_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"tool-use-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Fast-path: extract first token without full JSON parse
    local QUICK_CMD=""
    if [[ "$INPUT" =~ \"command\"[[:space:]]*:[[:space:]]*\" ]]; then
        local _local_after="${INPUT#*\"command\"*:*\"}"
        QUICK_CMD="${_local_after%%[[:space:]\"]*}"
    fi

    # Fast exit if first token isn't one of our targets
    case "$QUICK_CMD" in
        cat|head|tail|grep|rg) ;;
        *) return 0 ;;
    esac

    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        return 0
    fi

    local FIRST_TOKEN="${COMMAND%%[[:space:]]*}"

    # cat/head/tail check
    if [[ "$FIRST_TOKEN" == "cat" || "$FIRST_TOKEN" == "head" || "$FIRST_TOKEN" == "tail" ]]; then
        if [[ "$COMMAND" == *"|"* || "$COMMAND" == *"<<"* || "$COMMAND" == *">"* ]]; then
            return 0
        fi
        echo "WARNING [tool-use-guard]: Consider using the Read tool instead of $FIRST_TOKEN. It provides line numbers and is more token-efficient." >&2
        return 0
    fi

    # grep/rg check
    if [[ "$FIRST_TOKEN" == "grep" || "$FIRST_TOKEN" == "rg" ]]; then
        if [[ "$COMMAND" == *"|"* || "$COMMAND" == *">"* ]]; then
            return 0
        fi
        if [[ "$COMMAND" == *"git "* || "$COMMAND" == *"make "* || \
              "$COMMAND" == *"validate"* || "$COMMAND" == *"ci-status"* || \
              "$COMMAND" == *"check_assertion_density"* ]]; then
            return 0
        fi
        echo "WARNING [tool-use-guard]: Consider using the Grep tool instead of $FIRST_TOKEN. It has structured output and optimized permissions." >&2
        return 0
    fi

    return 0
}



# ---------------------------------------------------------------------------
# hook_review_integrity_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: block direct writes to review-status files.
hook_review_integrity_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"review-integrity-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        return 0
    fi

    # Allow legitimate record-review.sh invocations
    if [[ "$COMMAND" == *"record-review.sh"* ]]; then
        return 0
    fi

    # Check for direct writes to review-status (but NOT plan-review-status)
    if [[ "$COMMAND" =~ (>|>>|tee)[[:space:]]*[^[:space:]]*review-status ]]; then
        if [[ "$COMMAND" == *"plan-review-status"* ]]; then
            return 0
        fi
        echo "BLOCKED [review-integrity-guard]: Direct write to review-status file." >&2
        echo "Use the review workflow (record-review.sh) instead." >&2
        echo "See CLAUDE.md rule #14: Never manually generate review JSON." >&2
        trap - ERR; return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_blocked_test_command
# ---------------------------------------------------------------------------
# PreToolUse hook: block broad test commands and redirect to validate.sh.
#
# Reads commands.test_unit and commands.test_e2e from config (via read-config.sh).
# If the Bash command matches a configured broad test command (after stripping
# cd prefixes and splitting on shell operators), blocks with exit 2 and emits
# a Structured Action-Required Block directing the user to validate.sh.
#
# Matching Contract:
#   1. Split input command on shell operators (&&, ||, ;, |)
#   2. From each segment, strip leading cd <path> && prefixes (zero or more)
#   3. Trim leading/trailing whitespace
#   4. Check if any segment equals a configured value verbatim (exact match)
#   5. Commands with additional arguments do NOT match
#
# Safety allowlist: validate.sh and test-batched.sh are never blocked.
hook_blocked_test_command() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"blocked-test-command\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Fast early-exit: skip unless INPUT contains "test" substring (performance)
    if [[ "$INPUT" != *"test"* ]]; then
        return 0
    fi

    # Only act on Bash tool calls
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Bash" ]]; then
        return 0
    fi

    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        return 0
    fi

    # Safety allowlist: validate.sh and test-batched.sh are never blocked
    if [[ "$COMMAND" == *"validate.sh"* ]] || [[ "$COMMAND" == *"test-batched.sh"* ]]; then
        return 0
    fi

    # Resolve plugin root for read-config.sh and validate.sh path
    local _PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
    if [[ -z "$_PLUGIN_ROOT" || ! -d "$_PLUGIN_ROOT" ]]; then
        # Fallback: derive from _PRE_BASH_FUNC_DIR (set at top of file to hooks/lib/)
        _PLUGIN_ROOT="$(cd "${_PRE_BASH_FUNC_DIR}" && pwd -P)" && _PLUGIN_ROOT="${_PLUGIN_ROOT%/hooks/lib}"
    fi

    # Read configured test commands via read-config.sh
    local _READ_CONFIG="$_PLUGIN_ROOT/scripts/read-config.sh"
    if [[ ! -f "$_READ_CONFIG" ]]; then
        return 0
    fi

    local _TEST_UNIT="" _TEST_E2E=""
    _TEST_UNIT=$("$_READ_CONFIG" commands.test_unit 2>/dev/null) || true
    _TEST_E2E=$("$_READ_CONFIG" commands.test_e2e 2>/dev/null) || true

    # If no configured commands, pass through (graceful degradation)
    if [[ -z "$_TEST_UNIT" && -z "$_TEST_E2E" ]]; then
        return 0
    fi

    # Build list of blocked commands
    local -a _BLOCKED_CMDS=()
    [[ -n "$_TEST_UNIT" ]] && _BLOCKED_CMDS+=("$_TEST_UNIT")
    [[ -n "$_TEST_E2E" ]] && _BLOCKED_CMDS+=("$_TEST_E2E")

    # Matching Contract: split on shell operators, strip cd prefixes, check exact match
    local _MATCHED=""
    local _segment _trimmed

    # Split COMMAND on shell operators: &&, ||, ;, |
    # Use python3 for reliable splitting (handles quoting edge cases)
    local _SEGMENTS
    _SEGMENTS=$(python3 -c "
import re, sys
cmd = sys.argv[1]
# Split on &&, ||, ;, | (but not ||)
# Order matters: split on && and || first, then ; and |
segments = re.split(r'\s*(?:&&|\|\||;|\|)\s*', cmd)
for s in segments:
    print(s)
" "$COMMAND" 2>/dev/null) || _SEGMENTS="$COMMAND"

    while IFS= read -r _segment; do
        [[ -z "$_segment" ]] && continue

        # Strip leading "cd <path>" segments — after splitting on shell operators,
        # cd prefixes appear as standalone segments. Skip them entirely.
        _trimmed="$_segment"
        # Trim leading whitespace first
        _trimmed="${_trimmed#"${_trimmed%%[![:space:]]*}"}"
        # If segment is just a cd command (no further command), skip it
        if [[ "$_trimmed" =~ ^cd[[:space:]] ]]; then
            continue
        fi

        # Trim leading/trailing whitespace
        _trimmed="${_trimmed#"${_trimmed%%[![:space:]]*}"}"
        _trimmed="${_trimmed%"${_trimmed##*[![:space:]]}"}"

        # Check exact match against each blocked command
        for _blocked in "${_BLOCKED_CMDS[@]}"; do
            if [[ "$_trimmed" == "$_blocked" ]]; then
                _MATCHED="$_blocked"
                break 2
            fi
        done
    done <<< "$_SEGMENTS"

    if [[ -z "$_MATCHED" ]]; then
        return 0
    fi

    # Write telemetry JSONL entry
    local _ARTIFACTS="${ARTIFACTS_DIR:-}"
    if [[ -z "$_ARTIFACTS" ]]; then
        _ARTIFACTS=$(get_artifacts_dir 2>/dev/null) || true
    fi
    if [[ -n "$_ARTIFACTS" ]]; then
        mkdir -p "$_ARTIFACTS"
        local _TS
        _TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown")
        local _TELEMETRY_ENTRY
        _TELEMETRY_ENTRY=$(python3 -c "
import json, sys
entry = {'ts': sys.argv[1], 'event': 'blocked_test_command', 'command': sys.argv[2]}
print(json.dumps(entry))
" "$_TS" "$COMMAND" 2>/dev/null) || true
        if [[ -n "$_TELEMETRY_ENTRY" ]]; then
            printf '%s\n' "$_TELEMETRY_ENTRY" >> "$_ARTIFACTS/hook-telemetry.jsonl"
        fi
    fi

    # Resolve absolute path to validate.sh
    local _VALIDATE_PATH="$_PLUGIN_ROOT/scripts/validate.sh"

    # Emit Structured Action-Required Block
    echo "ACTION REQUIRED: tests incomplete"
    echo "RUN: $_VALIDATE_PATH --ci"
    echo "DO NOT proceed without completing all test batches."
    trap - ERR; return 2
}

# ---------------------------------------------------------------------------
# hook_tickets_tracker_bash_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: block Bash commands that directly reference .tickets-tracker/.
#
# .tickets-tracker/ is an event-sourced log; direct Bash modifications bypass
# event sourcing invariants and may corrupt the event log. All mutations must
# go through ticket CLI commands (ticket *, .claude/scripts/dso ticket *).
#
# Logic:
#   1. Only fires on Bash tool calls
#   2. Extracts command from tool_input
#   3. If command contains .tickets-tracker/ AND is allowlisted (ticket CLI): return 0
#   4. If command contains .tickets-tracker/ AND NOT allowlisted: return 2 (block)
#   5. All other cases: return 0 (allow, fail-open)
#
# Allowlist: ticket CLI scripts (ticket, .claude/scripts/dso ticket) are the sanctioned write path.
#
# REVIEW-DEFENSE: This function is intentionally not wired into dispatchers yet.
# Task dso-280g ("Wire tickets-tracker guards into dispatchers") handles dispatcher
# integration as a separate task, dependent on this implementation (dso-hzwm).
hook_tickets_tracker_bash_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"tickets-tracker-bash-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Only act on Bash tool calls
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name') || return 0
    if [[ "$TOOL_NAME" != "Bash" ]]; then
        return 0
    fi

    # Extract command
    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command') || return 0
    if [[ -z "$COMMAND" ]]; then
        return 0
    fi

    # Fast-path: no .tickets-tracker/ reference → allow
    if [[ "$COMMAND" != *".tickets-tracker/"* ]]; then
        return 0
    fi

    # Secondary filter: allow commands where .tickets-tracker/ appears only in
    # string/read context, not as an actual write target.
    #
    # Use parameter expansion (not extglob) for whitespace trimming.
    local _CMD_TRIMMED="$COMMAND"
    while [[ "$_CMD_TRIMMED" == " "* || "$_CMD_TRIMMED" == $'\t'* ]]; do
        _CMD_TRIMMED="${_CMD_TRIMMED#?}"
    done
    local _CMD_FIRST="${_CMD_TRIMMED%%[[:space:]]*}"

    # Write-redirect check FIRST: if the command contains a redirect (> or >>)
    # targeting a .tickets-tracker/ path, it's a write operation — skip all
    # allow filters and fall through to the allowlist/block logic below.
    if [[ "$COMMAND" != *">"*".tickets-tracker/"* ]]; then
        # No redirect targeting .tickets-tracker/ — safe to apply allow filters.

        # Read-only command prefixes (grep, cat, ls, head, tail, find, wc): allow.
        case "$_CMD_FIRST" in
            grep|cat|ls|head|tail|find|wc)
                return 0
                ;;
        esac

        # Heredoc marker (<<) with no write redirect: content mention only.
        if [[ "$COMMAND" == *"<<"* ]]; then
            return 0
        fi

        # echo/printf without a write redirect: string output only.
        if [[ "$_CMD_FIRST" == "echo" || "$_CMD_FIRST" == "printf" ]]; then
            return 0
        fi
    fi

    # Allowlist: ticket CLI patterns — sanctioned write path.
    # Three invocation forms:
    #   1. "ticket <subcommand> ..." — bare ticket dispatcher
    #   2. ".claude/scripts/dso ticket <subcommand> ..." — via DSO shim
    #   3. "bash .claude/scripts/dso ticket <subcommand> ..." — shim via bash
    local _TRIMMED="$_CMD_TRIMMED"   # reuse already-trimmed value
    local _FIRST_TOKEN="${_TRIMMED%%[[:space:]]*}"
    # Form 1: bare "ticket" command
    if [[ "$_FIRST_TOKEN" == "ticket" ]]; then
        return 0
    fi
    # Form 2: DSO shim — command starts with the shim path + "ticket"
    if [[ "$_TRIMMED" == ".claude/scripts/dso ticket "* ]] || [[ "$_TRIMMED" == ".claude/scripts/dso ticket" ]]; then
        return 0
    fi
    # Form 3: shim invoked via bash
    if [[ "$_TRIMMED" == "bash .claude/scripts/dso ticket "* ]] || [[ "$_TRIMMED" == "bash .claude/scripts/dso ticket" ]]; then
        return 0
    fi

    # .tickets-tracker/ referenced and not allowlisted — block
    echo "BLOCKED [tickets-tracker-guard]: Direct Bash modifications to .tickets-tracker/ are not allowed." >&2
    echo "Use ticket commands (ticket create, ticket sync, etc.) instead." >&2
    echo "Direct modifications bypass event sourcing invariants and may corrupt the event log." >&2
    trap - ERR; return 2
}

# hook_record_test_status_guard
# Speed-bump against casual misuse of record-test-status.sh. Allows legitimate
# commit-workflow and worktree-harvest callers via sentinel allowlists.
# The load-bearing defense against status recorded on a mismatched diff is the
# diff_hash check inside pre-commit-test-gate.sh (lines 611-618) — this hook
# does not need to be load-bearing.
# Allowlist:
#   --attest flag            harvest-worktree.sh worktree trust transfer
#   DSO_COMMIT_WORKFLOW=1    env-var sentinel set by COMMIT-WORKFLOW.md Step 4.5
#                            and related commit-flow prompts (single-agent-integrate,
#                            per-worktree-review-commit)
hook_record_test_status_guard() {
    local _json="$1"
    local _cmd
    _cmd=$(parse_json_field "$_json" '.tool_input.command' 2>/dev/null || true)

    # Only applies to commands that reference record-test-status.sh
    if [[ "$_cmd" != *"record-test-status.sh"* ]]; then
        return 0
    fi

    # Allow --attest flag: legitimate worktree trust transfer by harvest-worktree.sh
    if [[ "$_cmd" == *"--attest"* ]]; then
        return 0
    fi

    # Allow DSO_COMMIT_WORKFLOW=1 sentinel: legitimate commit-workflow invocation.
    if [[ "$_cmd" == *"DSO_COMMIT_WORKFLOW=1"* ]]; then
        return 0
    fi

    echo "BLOCKED [record-test-status-guard]: Direct calls to record-test-status.sh are not allowed." >&2
    echo "Test status is recorded automatically by the test gate during commits." >&2
    echo "If you need to transfer test status from a worktree, use harvest-worktree.sh (--attest flag)." >&2
    echo "If you are executing the commit workflow, prefix the call with DSO_COMMIT_WORKFLOW=1." >&2
    trap - ERR; return 2
}
