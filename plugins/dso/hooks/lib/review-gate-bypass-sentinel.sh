#!/usr/bin/env bash
# hooks/lib/review-gate-bypass-sentinel.sh
# Sourceable function library for the review-gate bypass sentinel.
#
# Detects and blocks commands that attempt to circumvent the review gate
# (e.g., --no-verify, core.hooksPath override, git plumbing commands,
# writing to .git/hooks/).
#
# Function defined:
#   hook_review_bypass_sentinel — block review gate bypass vectors
#
# Hook contract:
#   Input:  JSON string passed as $1
#   Return 0: allow — continue to next hook
#   Return 2: block/deny — dispatcher stops, outputs permissionDecision
#   stderr: error messages (always allowed)
#
# Usage:
#   source hooks/lib/review-gate-bypass-sentinel.sh
#   hook_review_bypass_sentinel "$INPUT_JSON"

# Guard: only load once
[[ "${_REVIEW_GATE_BYPASS_SENTINEL_LOADED:-}" == "1" ]] && return 0
_REVIEW_GATE_BYPASS_SENTINEL_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LIB_DIR/deps.sh"

hook_review_bypass_sentinel() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"review-bypass-sentinel\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Only act on Bash tool calls
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Bash" ]]; then
        return 0
    fi

    # Extract the full command string
    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        return 0
    fi

    # WIP exemption: if command contains WIP as a standalone word (case-insensitive), allow.
    # Uses word-boundary matching to avoid false positives on substrings like "wiper".
    if [[ "$COMMAND" =~ (^|[^[:alnum:]])[Ww][Ii][Pp]([^[:alnum:]]|$) ]]; then
        return 0
    fi

    # --- Pattern j: DSO_MECHANICAL_AMEND on non-amend commits ---
    # DSO_MECHANICAL_AMEND=1 is an internal bypass for merge-to-main.sh's mechanical
    # git commit --amend --no-edit calls. Block it on raw (non-amend) git commits to
    # prevent misuse as a general gate bypass.
    #
    # NOTE: This sentinel runs as a PreToolUse hook in Claude Code's process, NOT as
    # a child of the git subprocess. The inline env-var prefix (DSO_MECHANICAL_AMEND=1
    # git commit ...) is scoped to the git child process (Layer 1), so the sentinel's
    # process environment never contains this var. We must parse the COMMAND string
    # directly to detect the pattern.
    if [[ "$COMMAND" =~ DSO_MECHANICAL_AMEND=1 ]]; then
        # REVIEW-DEFENSE: Use `git[[:space:]].*commit` (word-boundary via [[:space:]].*) instead of
        # `git[[:space:]]+(commit|[^[:space:]]*[[:space:]]+commit)` so that `git -C /path commit`
        # is also matched. The existing Pattern b has the same regex limitation for -n detection,
        # but fixing it there risks false positives (git log -n). Here, since we already know
        # DSO_MECHANICAL_AMEND=1 is present, the broader match is safe and more correct.
        if [[ "$COMMAND" =~ git[[:space:]].*commit ]]; then
            if [[ "$COMMAND" != *"--amend"* ]]; then
                echo "BLOCKED [bypass-sentinel]: DSO_MECHANICAL_AMEND=1 on non-amend commit. This env var is only valid with git commit --amend --no-edit." >&2
                trap - ERR; return 2
            fi
        fi
    fi

    # --- Pattern a: --no-verify ---
    if [[ "$COMMAND" == *"--no-verify"* ]]; then
        echo "BLOCKED [bypass-sentinel]: --no-verify flag detected. Use /dso:commit instead." >&2
        trap - ERR; return 2
    fi

    # --- Pattern b: -n short flag in git commit context ---
    # Only block -n when it appears as a flag to git commit, not in other contexts
    # (e.g., git log -n 5, grep -n). We check if the command contains a git commit
    # and has -n as a standalone flag.
    if [[ "$COMMAND" =~ git[[:space:]]+(commit|[^[:space:]]*[[:space:]]+commit) ]]; then
        if [[ "$COMMAND" =~ (^|[[:space:]])-n([[:space:]]|$) ]]; then
            echo "BLOCKED [bypass-sentinel]: -n flag (--no-verify shorthand) detected on git commit. Use /dso:commit instead." >&2
            trap - ERR; return 2
        fi
    fi

    # --- Pattern c: git -c core.hooksPath= ---
    if [[ "$COMMAND" == *"core.hooksPath="* ]]; then
        echo "BLOCKED [bypass-sentinel]: core.hooksPath override detected. Use /dso:commit instead." >&2
        trap - ERR; return 2
    fi

    # --- Pattern d: git commit-tree ---
    if [[ "$COMMAND" =~ git[[:space:]]+commit-tree ]]; then
        echo "BLOCKED [bypass-sentinel]: git commit-tree (low-level plumbing) detected. Use /dso:commit instead." >&2
        trap - ERR; return 2
    fi

    # --- Pattern e: git update-ref (unless in merge-to-main.sh) ---
    if [[ "$COMMAND" =~ git[[:space:]]+update-ref ]]; then
        if [[ "$COMMAND" != *"merge-to-main.sh"* ]]; then
            echo "BLOCKED [bypass-sentinel]: git update-ref detected. Use /dso:commit instead." >&2
            trap - ERR; return 2
        fi
    fi

    # --- Pattern f: Write to .git/hooks/ ---
    # Block commands that write to .git/hooks/ (echo/cat/cp/mv/tee/chmod with redirect or target)
    # but allow read-only commands (cat without redirect, ls, etc.)
    if [[ "$COMMAND" =~ \.git/hooks/ ]]; then
        # Check for write patterns: redirect operators or write commands targeting .git/hooks/
        if [[ "$COMMAND" =~ (\>|tee)[[:space:]]*[^[:space:]]*\.git/hooks/ ]] || \
           [[ "$COMMAND" =~ (cp|mv|chmod|install)[[:space:]].*\.git/hooks/ ]] || \
           [[ "$COMMAND" =~ (echo|printf)[[:space:]].*\>[[:space:]]*[^[:space:]]*\.git/hooks/ ]]; then
            echo "BLOCKED [bypass-sentinel]: write to .git/hooks/ detected. Use /dso:commit instead." >&2
            trap - ERR; return 2
        fi
    fi

    # --- Pattern g: Direct writes to test-gate-status or test-status/ ---
    # Block commands that write to test-gate-status (echo/cat/tee/printf with redirect, cp/mv)
    # but allow read-only commands and the authorized writer (record-test-status.sh).
    if [[ "$COMMAND" == *"test-gate-status"* ]] || [[ "$COMMAND" == *"test-status/"* ]]; then
        # Exemption: record-test-status.sh is the authorized writer
        if [[ "$COMMAND" == *"record-test-status.sh"* ]]; then
            return 0
        fi
        # Check for write patterns: redirect operators, cp, mv, tee, echo/printf with redirect
        if [[ "$COMMAND" =~ \>[[:space:]]*[^[:space:]]*test-gate-status ]] || \
           [[ "$COMMAND" =~ \>[[:space:]]*[^[:space:]]*test-status/ ]] || \
           [[ "$COMMAND" =~ (tee)[[:space:]]*[^[:space:]]*test-gate-status ]] || \
           [[ "$COMMAND" =~ (tee)[[:space:]]*[^[:space:]]*test-status/ ]] || \
           [[ "$COMMAND" =~ (cp|mv)[[:space:]].*test-gate-status ]] || \
           [[ "$COMMAND" =~ (cp|mv)[[:space:]].*test-status/ ]] || \
           [[ "$COMMAND" =~ (echo|printf)[[:space:]].*\>.*test-gate-status ]] || \
           [[ "$COMMAND" =~ (echo|printf)[[:space:]].*\>.*test-status/ ]]; then
            echo "BLOCKED [bypass-sentinel]: direct write to test-gate-status detected. Use record-test-status.sh to record test results." >&2
            trap - ERR; return 2
        fi
    fi

    # --- Pattern h: Direct deletion of test-gate-status or test-status/ ---
    # Block rm commands targeting test-gate-status or test-status/ (cannot delete to reset gate state).
    if [[ "$COMMAND" =~ rm[[:space:]].*test-gate-status ]] || \
       [[ "$COMMAND" =~ rm[[:space:]].*test-status/ ]]; then
        # Exemption: record-test-status.sh is the authorized writer
        if [[ "$COMMAND" == *"record-test-status.sh"* ]]; then
            return 0
        fi
        echo "BLOCKED [bypass-sentinel]: direct deletion of test-gate-status detected. Use record-test-status.sh to manage test gate state." >&2
        trap - ERR; return 2
    fi

    # --- Pattern i: Direct writes to test-exemptions ---
    # Block commands that write to test-exemptions (echo/cat/tee/printf with redirect, cp/mv, rm)
    # but allow read-only commands and the authorized writer (record-test-exemption.sh).
    if [[ "$COMMAND" == *"test-exemptions"* ]]; then
        # Exemption: record-test-exemption.sh is the authorized writer
        if [[ "$COMMAND" == *"record-test-exemption.sh"* ]]; then
            return 0
        fi
        # Check for write patterns: redirect operators, cp, mv, tee, echo/printf with redirect, rm
        if [[ "$COMMAND" =~ \>[[:space:]]*[^[:space:]]*test-exemptions ]] || \
           [[ "$COMMAND" =~ (tee)[[:space:]]*[^[:space:]]*test-exemptions ]] || \
           [[ "$COMMAND" =~ (cp|mv)[[:space:]].*test-exemptions ]] || \
           [[ "$COMMAND" =~ (echo|printf)[[:space:]].*\>.*test-exemptions ]] || \
           [[ "$COMMAND" =~ rm[[:space:]].*test-exemptions ]]; then
            echo "BLOCKED [bypass-sentinel]: direct write to test-exemption file detected. Use record-test-exemption.sh to record test exemptions." >&2
            trap - ERR; return 2
        fi
    fi

    return 0
}
