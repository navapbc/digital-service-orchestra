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
    local HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
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


    # Strip quoted string arguments before pattern matching (bug 63a6-50e8).
    # Quoted spans are user-supplied data (e.g. ticket descriptions). Matching patterns
    # against them causes false positives when descriptions mention bypass techniques.
    # parse_json_field returns raw JSON string content; quoted spans appear as
    # backslash-escaped \"...\" (JSON form) or unescaped \"...\" (real form).
    # Fail-safe: if python3 fails, fall back to original COMMAND (may over-block, never under-blocks).
    local COMMAND_STRIPPED
    COMMAND_STRIPPED=$(python3 - "$COMMAND" <<'_PY_EOF'
import re, sys
cmd = sys.argv[1]
# Step 1: Remove backslash-quote delimited spans (JSON-encoded form in cmd).
# Uses [^"\\]* to avoid consuming across multiple spans (non-greedy by exclusion).
result = re.sub(r'\\"[^"\\]*\\"', ' ', cmd)
# Step 2: Remove real double-quoted spans.
result = re.sub(r'"[^"]*"', ' ', result)
# Step 3: Remove single-quoted spans (no escapes inside single quotes in POSIX shell).
result = re.sub(r"'[^']*'", ' ', result)
# Step 4: Collapse repeated whitespace.
result = re.sub(r' {2,}', ' ', result)
print(result)
_PY_EOF
    ) || COMMAND_STRIPPED="$COMMAND"

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
    if [[ "$COMMAND_STRIPPED" == *"--no-verify"* ]]; then
        echo "BLOCKED [bypass-sentinel]: --no-verify flag detected. Use /dso:commit instead." >&2
        trap - ERR; return 2
    fi

    # --- Pattern b: -n short flag in git commit context ---
    # Only block -n when it appears as a flag to git commit, not in other contexts
    # (e.g., git log -n 5, grep -n). We check if the command contains a git commit
    # and has -n as a standalone flag.
    if [[ "$COMMAND_STRIPPED" =~ git[[:space:]]+(commit|[^[:space:]]*[[:space:]]+commit) ]]; then
        if [[ "$COMMAND_STRIPPED" =~ (^|[[:space:]])-n([[:space:]]|$) ]]; then
            echo "BLOCKED [bypass-sentinel]: -n flag (--no-verify shorthand) detected on git commit. Use /dso:commit instead." >&2
            trap - ERR; return 2
        fi
    fi

    # --- Pattern c: git -c core.hooksPath= ---
    if [[ "$COMMAND_STRIPPED" == *"core.hooksPath="* ]]; then
        echo "BLOCKED [bypass-sentinel]: core.hooksPath override detected. Use /dso:commit instead." >&2
        trap - ERR; return 2
    fi

    # --- Pattern d: git commit-tree ---
    if [[ "$COMMAND_STRIPPED" =~ git[[:space:]]+commit-tree ]]; then
        echo "BLOCKED [bypass-sentinel]: git commit-tree (low-level plumbing) detected. Use /dso:commit instead." >&2
        trap - ERR; return 2
    fi

    # --- Pattern e: git update-ref (unless in merge-to-main.sh) ---
    if [[ "$COMMAND_STRIPPED" =~ git[[:space:]]+update-ref ]]; then
        if [[ "$COMMAND_STRIPPED" != *"merge-to-main.sh"* ]]; then
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
    # Two-path detection to avoid false positives from quoted descriptions (bug 63a6-50e8):
    #   Path A: target appears OUTSIDE quotes (COMMAND_STRIPPED) - shell redirect writes.
    #   Path B: interpreter (python3/etc) runs and target appears anywhere in COMMAND -
    #           catches interpreter-based writes without shell redirects (bug 4600-02a3).
    local _g_path_a=0 _g_path_b=0
    if [[ "$COMMAND_STRIPPED" == *"test-gate-status"* ]] || [[ "$COMMAND_STRIPPED" == *"test-status/"* ]]; then
        _g_path_a=1
    fi
    if [[ "$COMMAND" =~ (python3?|perl|ruby|node)[[:space:]] ]] && \
       { [[ "$COMMAND" == *"test-gate-status"* ]] || [[ "$COMMAND" == *"test-status/"* ]]; }; then
        _g_path_b=1
    fi
    if (( _g_path_a || _g_path_b )); then
        # Exemption: the authorized writer
        if [[ "$COMMAND" == *"record-test-status.sh"* ]]; then
            return 0
        fi
        # For Path B: interpreter is the write vector; block immediately.
        # For Path A: check for shell-level write patterns.
        if (( _g_path_b )) || \
           [[ "$COMMAND" =~ \>[[:space:]]*[^[:space:]]*test-gate-status ]] || \
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

    # --- Pattern k: Direct writes/deletions to .tickets-tracker/ internals ---
    # Block commands that modify .tickets-tracker/ files directly (echo/cat/tee/printf
    # with redirect, cp/mv, rm) but allow read-only commands and authorized writers
    # (ticket CLI scripts: ticket*.sh, ticket-*.py).
    # Also protects .git/worktrees/-tickets-tracker/ (git worktree metadata).
    if [[ "$COMMAND" == *".tickets-tracker/"* ]] || [[ "$COMMAND" == *"worktrees/-tickets-tracker/"* ]]; then
        # Exemption: ticket CLI scripts are authorized writers
        if [[ "$COMMAND" == *"ticket-"*".sh"* ]] || [[ "$COMMAND" == *"ticket-"*".py"* ]] || \
           [[ "$COMMAND" == *"ticket init"* ]] || [[ "$COMMAND" == *"ticket-init"* ]] || \
           [[ "$COMMAND" == *"ticket-lib"* ]]; then
            return 0
        fi
        # Exemption: git operations within ticket scripts (git -C .tickets-tracker/ ...)
        if [[ "$COMMAND" =~ git[[:space:]]+-C[[:space:]]+[^[:space:]]*\.tickets-tracker ]]; then
            return 0
        fi
        # Exemption: read-only commands (cat, head, tail, ls, find, grep without redirect)
        if [[ "$COMMAND" =~ ^[[:space:]]*(cat|head|tail|ls|find|grep|wc|stat)[[:space:]] ]] && \
           [[ ! "$COMMAND" =~ \> ]]; then
            return 0
        fi
        # Check for write/delete patterns
        if [[ "$COMMAND" =~ \>[[:space:]]*[^[:space:]]*(\.tickets-tracker/|worktrees/-tickets-tracker/) ]] || \
           [[ "$COMMAND" =~ (tee)[[:space:]]*[^[:space:]]*(\.tickets-tracker/|worktrees/-tickets-tracker/) ]] || \
           [[ "$COMMAND" =~ (cp|mv)[[:space:]].*(\.tickets-tracker/|worktrees/-tickets-tracker/) ]] || \
           [[ "$COMMAND" =~ (echo|printf)[[:space:]].*\>.*(\.tickets-tracker/|worktrees/-tickets-tracker/) ]] || \
           [[ "$COMMAND" =~ rm[[:space:]].*(\.tickets-tracker/|worktrees/-tickets-tracker/) ]]; then
            echo "BLOCKED [bypass-sentinel]: direct modification of .tickets-tracker/ detected. Use ticket CLI commands (ticket create, ticket comment, etc.) instead." >&2
            trap - ERR; return 2
        fi
    fi

    return 0
}
