#!/usr/bin/env bash
# .claude/hooks/validation-gate.sh
# PreToolUse hook: force agents to see codebase health before starting work.
#
# Three-state model:
#   not_run  (no status file) → HARD BLOCK for new-work commands (exit 2)
#                              → SILENT ALLOW for everything else (exit 0)
#   failed   (status=failed)  → WARNING for Edit/Write (exit 0, needed for fixes)
#                              → HARD BLOCK for new-work Bash commands (exit 2)
#                              → WARNING for all other Bash commands (exit 0)
#   passed   (status=passed)  → SILENT ALLOW (exit 0)
#
# Validation runs automatically as part of /sprint (for epics) and at commit
# time (for code changes). The gate only hard-blocks sprint/epic discovery
# commands when validation hasn't run or has failed, preventing agents from
# starting new work on an unhealthy codebase. General edits are always allowed
# so agents can fix bugs, write docs, or do research without running validation.
#
# State file location: /tmp/workflow-plugin-<hash>/status (portable, see get_artifacts_dir in lib/deps.sh)
# Expected content: "passed" or "failed" (first line)
#
# Exempt Bash commands:
#   - validate.sh / ci-status.sh / agent-batch-lifecycle.sh
#   - read-only commands (pwd, ls, cat, head, tail, grep, find, tree, wc, file, stat, which, type)
#   - git, gh, bd, poetry, make (format|lint|test|db-*), docker, lsof
#   - Compound commands if they contain validate.sh/ci-status.sh, or if ALL sub-commands are exempt
#
# New-work Bash patterns (blocked when state=not_run or failed):
#   - bd list --type=epic (sprint discovery)
#   - bd epic (epic management)
#   - bd ready (without --parent; sprint task discovery)
#   - bd children <args> (sprint task analysis)
#   - sprint (sprint invocation, as first token only)

# Log unexpected errors to JSONL and exit cleanly (never surface to user)
HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
trap 'printf "{\"ts\":\"%s\",\"hook\":\"validation-gate.sh\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; exit 0' ERR

# Source shared dependency library
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HOOK_DIR/lib/deps.sh"

# Read configured validate command for error messages.
# Falls back to 'validate.sh --ci' when no config is present.
SCRIPTS_DIR="$HOOK_DIR/../scripts"
VALIDATE_CMD=$("$SCRIPTS_DIR/read-config.sh" commands.validate 2>/dev/null || echo 'validate.sh --ci')
VALIDATE_CMD=${VALIDATE_CMD:-'validate.sh --ci'}

# Read hook input from stdin
INPUT=$(cat)

# Only act on Edit, Write, and Bash tools
TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
if [[ "$TOOL_NAME" != "Edit" ]] && [[ "$TOOL_NAME" != "Write" ]] && [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Read state file BEFORE exemption logic so we can use
# VALIDATION_STATUS in the new-work guard checks.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
    # If not in a git repo, can't determine state file location - skip check
    exit 0
fi

ARTIFACTS_DIR=$(get_artifacts_dir)
VALIDATION_STATE_FILE="$ARTIFACTS_DIR/status"

# Read validation state (empty string if file doesn't exist)
if [[ -f "$VALIDATION_STATE_FILE" ]]; then
    VALIDATION_STATUS=$(head -n 1 "$VALIDATION_STATE_FILE" 2>/dev/null || echo "")
else
    VALIDATION_STATUS=""
fi

# New-work guard: returns 0 (true) if the command is a new-work pattern.
# These are commands that start sprints or discover epics — blocked when
# validation hasn't run or has failed to prevent starting on an unhealthy codebase.
is_new_work_command() {
    local cmd="$1"
    # Trim leading whitespace
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
    [[ "$cmd" =~ ^bd[[:space:]]+list.*--type[=[:space:]]+epic($|[[:space:]]) ]] && return 0
    [[ "$cmd" =~ ^bd[[:space:]]+epic($|[[:space:]]) ]] && return 0
    [[ "$cmd" =~ ^bd[[:space:]]+ready($|[[:space:]]) ]] && ! [[ "$cmd" =~ --parent ]] && return 0
    [[ "$cmd" =~ ^bd[[:space:]]+children[[:space:]]+ ]] && return 0
    [[ "$cmd" =~ ^sprint($|[[:space:]]) ]] && return 0
    return 1
}

# Helper: emit hard-block message for new-work commands in failed state
block_new_work() {
    echo "BLOCKED: Fix validation failures before sprint/epic discovery. Re-run $VALIDATE_CMD first." >&2
    exit 2
}

# For Bash commands, check if it's an exempt command
if [[ "$TOOL_NAME" == "Bash" ]]; then
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')

    # --- Compound command guard ---
    # Commands with write-capable operators (&&, ||, ;) are only exempt if they
    # include validate.sh or ci-status.sh. This prevents chaining writes after
    # exempt prefixes (e.g., "git status && rm -rf /").
    # Pipes (|) are treated separately: exempt if left-hand command is read-only.
    if [[ "$COMMAND" =~ \&\& ]] || [[ "$COMMAND" =~ \|\| ]] || [[ "$COMMAND" =~ \; ]]; then
        if [[ "$COMMAND" =~ (^|[[:space:]/])validate\.sh($|[[:space:]]) ]] || [[ "$COMMAND" =~ (^|[[:space:]/])ci-status\.sh($|[[:space:]]) ]] || [[ "$COMMAND" =~ (^|[[:space:]/])agent-batch-lifecycle\.sh($|[[:space:]]) ]]; then
            exit 0
        fi
        # Allow compound commands where all executables are read-only/exempt
        # Extract individual commands, strip shell keywords and variable assignments
        EXEMPT_PATTERN='^(pwd|ls|cat|head|tail|grep|find|tree|wc|file|stat|which|type|cd|lsof|docker|gh|git|bd|echo|printf|test|true|false|make|poetry|record-review\.sh)($|[[:space:]])'
        ALL_EXEMPT=true
        HAS_NEW_WORK=false
        while IFS= read -r subcmd; do
            # Trim leading whitespace
            subcmd="${subcmd#"${subcmd%%[![:space:]]*}"}"
            [[ -z "$subcmd" ]] && continue
            # Skip shell keywords (for/do/done/if/then/else/fi/while/in/[)
            [[ "$subcmd" =~ ^(for|do|done|if|then|else|fi|while|until|in|case|esac|\[)($|[[:space:]]) ]] && continue
            # Skip variable assignments (FOO=bar)
            [[ "$subcmd" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
            # Check for new-work commands in compound expressions (blocked in not_run and failed)
            if [[ "$VALIDATION_STATUS" != "passed" ]] && is_new_work_command "$subcmd"; then
                HAS_NEW_WORK=true
                break
            fi
            # Check against exempt pattern
            if ! [[ "$subcmd" =~ $EXEMPT_PATTERN ]]; then
                ALL_EXEMPT=false
                break
            fi
        done <<< "$(echo "$COMMAND" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g')"
        # Block compound commands containing new-work patterns when failed
        if [[ "$HAS_NEW_WORK" == "true" ]]; then
            block_new_work
        fi
        if [[ "$ALL_EXEMPT" == "true" ]]; then
            exit 0
        fi
        # Write-capable compound without validation scripts — fall through to state check
    elif [[ "$COMMAND" =~ \| ]]; then
        # Pipe-only: check for new-work in first command when not_run or failed
        if [[ "$VALIDATION_STATUS" != "passed" ]]; then
            FIRST_CMD="${COMMAND%%|*}"
            if is_new_work_command "$FIRST_CMD"; then
                block_new_work
            fi
        fi
        # Pipe-only: exempt if the first command is a read-only tool
        if [[ "$COMMAND" =~ ^(pwd|ls|cat|head|tail|grep|find|tree|wc|file|stat|which|type|cd|lsof|docker|gh|git|bd)($|[[:space:]]) ]]; then
            exit 0
        fi
        if [[ "$COMMAND" =~ (^|[[:space:]/])validate\.sh($|[[:space:]]) ]] || [[ "$COMMAND" =~ (^|[[:space:]/])ci-status\.sh($|[[:space:]]) ]] || [[ "$COMMAND" =~ (^|[[:space:]/])agent-batch-lifecycle\.sh($|[[:space:]]) ]]; then
            exit 0
        fi
        if [[ "$COMMAND" =~ (^|[[:space:]/])record-review\.sh($|[[:space:]]) ]]; then
            exit 0
        fi
        # Pipe with non-exempt left-hand command — fall through to state check
    else
        # --- New-work guard for simple commands ---
        # Check BEFORE exemptions so that "bd list --type=epic" is caught
        # even though "bd" is normally exempt. Blocks in both not_run and failed states.
        if [[ "$VALIDATION_STATUS" != "passed" ]] && is_new_work_command "$COMMAND"; then
            block_new_work
        fi

        # --- E2E failure guard for git push ---
        # If E2E tests were run and failed, block git push to prevent pushing broken code.
        if [[ "$COMMAND" =~ ^git[[:space:]]+push($|[[:space:]]) ]]; then
            if [[ -f "$VALIDATION_STATE_FILE" ]] && grep -q '^e2e_failed=true' "$VALIDATION_STATE_FILE" 2>/dev/null; then
                echo "BLOCKED: E2E tests failed. Fix E2E failures before pushing. Run 'make test-e2e' to verify." >&2
                exit 2
            fi
        fi

        # Simple (non-compound) command exemptions
        # Match "cmd" (bare) or "cmd ..." (with args) using (cmd$|cmd[[:space:]])
        # Allow writes to /tmp/ (subagent counters, validation state, etc.)
        if [[ "$COMMAND" =~ ^echo[[:space:]].*\>[[:space:]]*/tmp/ ]] || \
           [[ "$COMMAND" =~ (^|[[:space:]/])validate\.sh($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ (^|[[:space:]/])ci-status\.sh($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ (^|[[:space:]/])agent-batch-lifecycle\.sh($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ ^(pwd|ls|cat|head|tail|grep|find|tree|wc|file|stat|which|type|cd)($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ ^git($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ ^bd($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ ^make[[:space:]]+(format|lint|test|db-) ]] || \
           [[ "$COMMAND" =~ ^poetry($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ ^docker($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ ^gh($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ ^lsof($|[[:space:]]) ]] || \
           [[ "$COMMAND" =~ (^|[[:space:]/])record-review\.sh($|[[:space:]]) ]]; then
            exit 0
        fi
    fi
fi

# --- State: not_run — SILENT ALLOW ---
# Validation is no longer required before all tasks. It runs automatically as
# part of /sprint for epics and at commit time for code changes. New-work
# commands (sprint/epic discovery) are already blocked above.
if [[ -z "$VALIDATION_STATUS" ]]; then
    exit 0
fi

# --- State: failed — WARNING (allows fixes) ---
if [[ "$VALIDATION_STATUS" == "failed" ]]; then
    if [[ "$TOOL_NAME" == "Bash" ]]; then
        # Non-exempt Bash command while validation failed → WARNING ONLY
        echo "WARNING: Validation failures exist. Fix before starting new work ($VALIDATE_CMD)." >&2
        exit 0
    else
        # Edit/Write while validation failed → WARNING ONLY (needed for fixing code)
        echo "WARNING: $VALIDATE_CMD reported failures. Fix before starting new work." >&2
        exit 0
    fi
fi

# --- State: passed — SILENT ALLOW ---
exit 0
