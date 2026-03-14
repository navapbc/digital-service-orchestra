#!/usr/bin/env bash
# lockpick-workflow/hooks/lib/pre-bash-functions.sh
# Sourceable function definitions for the 8 PreToolUse Bash hooks.
#
# Each function follows the hook contract:
#   Input:  JSON string passed as $1
#   Return 0: allow — continue to next hook
#   Return 2: block/deny — dispatcher stops, outputs permissionDecision
#   stderr: warnings (always allowed; passed through by dispatcher)
#   stdout: permissionDecision message (only consumed when return 2)
#
# Functions defined:
#   hook_validation_gate         — block sprint/new-work when validation not run
#   hook_commit_failure_tracker  — warn at commit time about untracked failures
#   hook_review_gate             — block git commit when review is missing/stale
#   hook_worktree_bash_guard     — block cd into main repo from worktree
#   hook_worktree_edit_guard     — block mkdir targeting main repo from worktree
#   hook_bug_close_guard         — require --reason flag on bug ticket closes
#   hook_tool_use_guard          — warn when cat/grep used instead of Read/Grep tools
#   hook_review_integrity_guard  — block direct writes to review-status files
#
# Usage:
#   source lockpick-workflow/hooks/lib/pre-bash-functions.sh
#   hook_validation_gate "$INPUT_JSON"
#   hook_review_gate "$INPUT_JSON"

# Guard: only load once
[[ "${_PRE_BASH_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_PRE_BASH_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_PRE_BASH_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PRE_BASH_FUNC_DIR/deps.sh"

# ---------------------------------------------------------------------------
# hook_validation_gate
# ---------------------------------------------------------------------------
# PreToolUse hook: force agents to see codebase health before starting work.
#
# Three-state model:
#   not_run  → HARD BLOCK for new-work commands; SILENT ALLOW for everything else
#   failed   → WARNING for all commands (allows fixes)
#   passed   → SILENT ALLOW
#
# New-work patterns (blocked when state=not_run or failed):
#   sprint-list-epics, sprint (as first token)
hook_validation_gate() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"validation-gate\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Only act on Edit, Write, and Bash tools
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Edit" ]] && [[ "$TOOL_NAME" != "Write" ]] && [[ "$TOOL_NAME" != "Bash" ]]; then
        return 0
    fi

    # Resolve repo root
    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    # Determine artifacts dir (support override via env var for tests)
    local ARTIFACTS_DIR_RESOLVED="${ARTIFACTS_DIR:-}"
    if [[ -z "$ARTIFACTS_DIR_RESOLVED" ]]; then
        ARTIFACTS_DIR_RESOLVED=$(get_artifacts_dir)
    fi
    local VALIDATION_STATE_FILE="$ARTIFACTS_DIR_RESOLVED/status"

    # Read validation state
    local VALIDATION_STATUS=""
    if [[ -f "$VALIDATION_STATE_FILE" ]]; then
        VALIDATION_STATUS=$(head -n 1 "$VALIDATION_STATE_FILE" 2>/dev/null || echo "")
    fi

    # Lazily resolve validate command (avoid spawning Python unless needed)
    local _VG_SCRIPTS_DIR=""
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh" ]]; then
        _VG_SCRIPTS_DIR="$CLAUDE_PLUGIN_ROOT/scripts"
    fi
    local VALIDATE_CMD=""
    _vg_get_validate_cmd() {
        if [[ -z "$VALIDATE_CMD" ]]; then
            if [[ -n "$_VG_SCRIPTS_DIR" ]]; then
                VALIDATE_CMD=$("$_VG_SCRIPTS_DIR/read-config.sh" commands.validate 2>/dev/null || echo 'validate.sh --ci')
            fi
            VALIDATE_CMD=${VALIDATE_CMD:-'validate.sh --ci'}
        fi
        echo "$VALIDATE_CMD"
    }

    # New-work guard helper
    _vg_is_new_work_command() {
        local cmd="$1"
        cmd="${cmd#"${cmd%%[![:space:]]*}"}"
        [[ "$cmd" =~ sprint-list-epics($|[[:space:]]) ]] && return 0
        [[ "$cmd" =~ ^sprint($|[[:space:]]) ]] && return 0
        return 1
    }

    # Helper: emit hard-block for new-work commands
    _vg_block_new_work() {
        if [[ -z "$VALIDATION_STATUS" ]]; then
            echo "BLOCKED: Validation has not been run yet. Run $(_vg_get_validate_cmd) first to check project health." >&2
        else
            echo "BLOCKED: Fix validation failures before sprint/epic discovery. Re-run $(_vg_get_validate_cmd) first." >&2
        fi
        return 2
    }

    # For Bash commands
    if [[ "$TOOL_NAME" == "Bash" ]]; then
        local COMMAND
        COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')

        # Compound command guard
        if [[ "$COMMAND" =~ \&\& ]] || [[ "$COMMAND" =~ \|\| ]] || [[ "$COMMAND" =~ \; ]]; then
            if [[ "$COMMAND" =~ (^|[[:space:]/])validate\.sh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])ci-status\.sh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])agent-batch-lifecycle\.sh($|[[:space:]]) ]]; then
                return 0
            fi
            local EXEMPT_PATTERN='^(pwd|ls|cat|head|tail|grep|find|tree|wc|file|stat|which|type|cd|lsof|docker|gh|git|tk|echo|printf|test|true|false|make|poetry|record-review\.sh)($|[[:space:]])'
            local ALL_EXEMPT=true
            local HAS_NEW_WORK=false
            while IFS= read -r subcmd; do
                subcmd="${subcmd#"${subcmd%%[![:space:]]*}"}"
                [[ -z "$subcmd" ]] && continue
                [[ "$subcmd" =~ ^(for|do|done|if|then|else|fi|while|until|in|case|esac|\[)($|[[:space:]]) ]] && continue
                [[ "$subcmd" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
                if [[ "$VALIDATION_STATUS" != "passed" ]] && _vg_is_new_work_command "$subcmd"; then
                    HAS_NEW_WORK=true
                    break
                fi
                if ! [[ "$subcmd" =~ $EXEMPT_PATTERN ]]; then
                    ALL_EXEMPT=false
                    break
                fi
            done <<< "$(echo "$COMMAND" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g')"
            if [[ "$HAS_NEW_WORK" == "true" ]]; then
                _vg_block_new_work || true  # || true prevents ERR trap from firing on return 2
                return 2
            fi
            if [[ "$ALL_EXEMPT" == "true" ]]; then
                return 0
            fi
        elif [[ "$COMMAND" =~ \| ]]; then
            if [[ "$VALIDATION_STATUS" != "passed" ]]; then
                local FIRST_CMD="${COMMAND%%|*}"
                if _vg_is_new_work_command "$FIRST_CMD"; then
                    _vg_block_new_work || true  # || true prevents ERR trap from firing on return 2
                    return 2
                fi
            fi
            if [[ "$COMMAND" =~ ^(pwd|ls|cat|head|tail|grep|find|tree|wc|file|stat|which|type|cd|lsof|docker|gh|git|tk)($|[[:space:]]) ]]; then
                return 0
            fi
            if [[ "$COMMAND" =~ (^|[[:space:]/])validate\.sh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])ci-status\.sh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])agent-batch-lifecycle\.sh($|[[:space:]]) ]]; then
                return 0
            fi
            if [[ "$COMMAND" =~ (^|[[:space:]/])record-review\.sh($|[[:space:]]) ]]; then
                return 0
            fi
        else
            # Simple command
            if [[ "$VALIDATION_STATUS" != "passed" ]] && _vg_is_new_work_command "$COMMAND"; then
                _vg_block_new_work || true  # || true prevents ERR trap from firing on return 2
                return 2
            fi

            # E2E failure guard for git push
            if [[ "$COMMAND" =~ ^git[[:space:]]+push($|[[:space:]]) ]]; then
                if [[ -f "$VALIDATION_STATE_FILE" ]] && grep -q '^e2e_failed=true' "$VALIDATION_STATE_FILE" 2>/dev/null; then
                    echo "BLOCKED: E2E tests failed. Fix E2E failures before pushing. Run 'make test-e2e' to verify." >&2
                    trap - ERR; return 2
                fi
            fi

            # Simple command exemptions
            if [[ "$COMMAND" =~ ^echo[[:space:]].*\>[[:space:]]*/tmp/ ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])validate\.sh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])ci-status\.sh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])agent-batch-lifecycle\.sh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ ^(pwd|ls|cat|head|tail|grep|find|tree|wc|file|stat|which|type|cd)($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ ^git($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ ^tk($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ ^make[[:space:]]+(format|lint|test|db-) ]] || \
               [[ "$COMMAND" =~ ^poetry($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ ^docker($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ ^gh($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ ^lsof($|[[:space:]]) ]] || \
               [[ "$COMMAND" =~ (^|[[:space:]/])record-review\.sh($|[[:space:]]) ]]; then
                return 0
            fi
        fi
    fi

    # State: not_run — SILENT ALLOW (new-work already blocked above)
    if [[ -z "$VALIDATION_STATUS" ]]; then
        return 0
    fi

    # State: failed — WARNING (allows fixes)
    if [[ "$VALIDATION_STATUS" == "failed" ]]; then
        if [[ "$TOOL_NAME" == "Bash" ]]; then
            echo "WARNING: Validation failures exist. Fix before starting new work ($(_vg_get_validate_cmd))." >&2
            return 0
        else
            echo "WARNING: $(_vg_get_validate_cmd) reported failures. Fix before starting new work." >&2
            return 0
        fi
    fi

    # State: passed — SILENT ALLOW
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
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
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
    local _CREATE_CMD_FROM_ENV="${CREATE_CMD:-}"
    local _SEARCH_CMD="${SEARCH_CMD:-grep -rl}"
    local _CREATE_CMD="${CREATE_CMD:-tk create}"
    local _READ_CONFIG=""
    if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh" ]]; then
        _READ_CONFIG="$CLAUDE_PLUGIN_ROOT/scripts/read-config.sh"
    fi

    # Apply config overrides (defer Python spawn; don't override caller-supplied env vars)
    if [[ -n "$_READ_CONFIG" ]] && [[ -z "$_SEARCH_CMD_FROM_ENV" ]]; then
        local _SEARCH
        _SEARCH=$("$_READ_CONFIG" issue_tracker.search_cmd 2>/dev/null || echo '')
        [[ -n "$_SEARCH" ]] && _SEARCH_CMD="$_SEARCH"
    fi
    if [[ -n "$_READ_CONFIG" ]] && [[ -z "$_CREATE_CMD_FROM_ENV" ]]; then
        local _CREATE
        _CREATE=$("$_READ_CONFIG" issue_tracker.create_cmd 2>/dev/null || echo '')
        [[ -n "$_CREATE" ]] && _CREATE_CMD="$_CREATE"
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
    local _OLD_ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-$(basename "$REPO_ROOT")"
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

    # Quick check: do open issues exist for each category?
    local -a UNTRACKED=()
    local category
    for category in "${FAILED_CATEGORIES[@]}"; do
        local RESULT
        RESULT=$($_SEARCH_CMD "$category failure" "$(git rev-parse --show-toplevel)/.tickets" 2>/dev/null | head -1 || echo "")
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
    echo "Issues should have been auto-created by check-validation-failures.sh." >&2
    echo "Search: $_SEARCH_CMD '<check> failure' $(git rev-parse --show-toplevel)/.tickets" >&2
    echo "Create manually if needed: tk create \"Fix <check> failure\" -t bug -p 1" >&2
    echo "" >&2

    # Never block
    return 0
}

# ---------------------------------------------------------------------------
# hook_review_gate
# ---------------------------------------------------------------------------
# PreToolUse hook: HARD GATE that blocks git commit if code review hasn't
# passed for the current working tree state.
hook_review_gate() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"review-gate\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    # Only act on Bash tool calls
    local TOOL_NAME
    TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
    if [[ "$TOOL_NAME" != "Bash" ]]; then
        return 0
    fi

    # Only act on git commit commands
    local COMMAND FIRST_LINE FIRST_LINE_UNQUOTED
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    FIRST_LINE=$(echo "$COMMAND" | head -1)
    FIRST_LINE_UNQUOTED=$(echo "$FIRST_LINE" | sed "s/'[^']*'//g" | sed 's/"[^"]*"//g')
    if ! [[ "$FIRST_LINE_UNQUOTED" =~ (^|[[:space:]|&;])git[[:space:]]+commit([[:space:]]|$) ]] && \
       ! [[ "$FIRST_LINE_UNQUOTED" =~ (^|[[:space:]|&;])git[[:space:]]+-[^[:space:]]+.*[[:space:]]commit([[:space:]]|$) ]]; then
        return 0
    fi

    # Exempt: WIP commits
    if [[ "$COMMAND" =~ [Ww][Ii][Pp] ]]; then
        return 0
    fi

    # Exempt: git merge commands
    if [[ "$COMMAND" =~ git[[:space:]].*merge[[:space:]] ]]; then
        return 0
    fi

    # Exempt: pre-compact checkpoint
    if [[ "$COMMAND" =~ pre-compact ]] || [[ "$COMMAND" =~ checkpoint ]]; then
        return 0
    fi

    # Exempt: completing a merge after conflict resolution (MERGE_HEAD exists)
    local GIT_DIR_PATH
    GIT_DIR_PATH=$(git rev-parse --git-dir 2>/dev/null || echo "")
    if [[ -n "$GIT_DIR_PATH" && -f "$GIT_DIR_PATH/MERGE_HEAD" ]]; then
        return 0
    fi

    # If command contains "git add" before "git commit", check targets and execute
    if [[ "$FIRST_LINE" =~ git[[:space:]]+add[[:space:]] ]]; then
        local GIT_ADD_CMD
        GIT_ADD_CMD=$(echo "$FIRST_LINE" | sed 's/&&[[:space:]]*git[[:space:]].*commit.*//')

        # Exempt: if ALL git add targets are .tickets/ paths, skip review entirely.
        # This handles the PreToolUse timing issue: the hook fires BEFORE git add
        # executes, so git diff --cached shows nothing staged. By inspecting the
        # command's intended targets, we can exempt ticket-only commits without
        # relying on index state.
        if [[ -n "$GIT_ADD_CMD" ]]; then
            local _ADD_TARGETS _NON_TICKET_TARGETS
            # Extract paths from the git add command (strip flags like -A, -u, -f, --)
            _ADD_TARGETS=$(echo "$GIT_ADD_CMD" | sed 's/git[[:space:]]*add//' | sed 's/[[:space:]]*--[[:space:]]*//' | sed 's/[[:space:]]*-[AufpneNv]*//g' | xargs 2>/dev/null || echo "")
            if [[ -n "$_ADD_TARGETS" ]]; then
                _NON_TICKET_TARGETS=$(echo "$_ADD_TARGETS" | tr ' ' '\n' | grep -v '^\.\?tickets/' | grep -v '^\.sync-state\.json$' || true)
                if [[ -z "$_NON_TICKET_TARGETS" ]]; then
                    return 0
                fi
            fi
            eval "$GIT_ADD_CMD" 2>/dev/null || true
        fi
    fi

    # Exempt: commits that only touch issue tracker metadata
    local STAGED_ALL STAGED_NON_TRACKER
    STAGED_ALL=$(git diff --cached --name-only 2>/dev/null || true)
    STAGED_NON_TRACKER=$(echo "$STAGED_ALL" | grep -v '^\.tickets/' | grep -v '^\.sync-state\.json$' || true)
    if [[ -n "$STAGED_ALL" && -z "$STAGED_NON_TRACKER" ]]; then
        return 0
    fi

    # Exempt: commits that only touch non-reviewable binary/snapshot files
    local STAGED_NON_SNAPSHOTS
    STAGED_NON_SNAPSHOTS=$(echo "$STAGED_NON_TRACKER" \
        | grep -v -E '^app/tests/e2e/snapshots/' \
        | grep -v -E '^app/tests/unit/templates/snapshots/.*\.html$' \
        | grep -v -E '\.(png|jpg|jpeg|gif|svg|ico|webp)$' \
        | grep -v -E '\.(pdf|docx)$' \
        || true)
    if [[ -n "$STAGED_ALL" && -z "$STAGED_NON_SNAPSHOTS" ]]; then
        return 0
    fi

    # Exempt: commits that only touch docs/logs
    local STAGED_NON_DOCS STAGED_AGENT_FILES
    STAGED_NON_DOCS=$(echo "$STAGED_NON_SNAPSHOTS" | grep -v -E '^(\.claude/session-logs/|\.claude/docs/|docs/)' || true)
    STAGED_AGENT_FILES=$(echo "$STAGED_ALL" | grep -E '^(\.claude/hooks/|\.claude/hookify\.|lockpick-workflow/skills/|lockpick-workflow/hooks/|lockpick-workflow/docs/workflows/|CLAUDE\.md)' || true)
    if [[ -n "$STAGED_ALL" && -z "$STAGED_NON_DOCS" && -z "$STAGED_AGENT_FILES" ]]; then
        return 0
    fi

    # Determine worktree and state file location
    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    local ARTIFACTS_DIR_RESOLVED="${ARTIFACTS_DIR:-}"
    if [[ -z "$ARTIFACTS_DIR_RESOLVED" ]]; then
        ARTIFACTS_DIR_RESOLVED=$(get_artifacts_dir)
    fi
    local REVIEW_STATE_FILE="$ARTIFACTS_DIR_RESOLVED/review-status"

    # If no review has ever been recorded, block
    if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
        echo "BLOCKED: No code review recorded. Use /commit (runs review automatically) or /review first." >&2
        trap - ERR; return 2
    fi

    # Read review status
    local REVIEW_STATUS
    REVIEW_STATUS=$(head -n 1 "$REVIEW_STATE_FILE" 2>/dev/null || echo "")

    # If review failed, block
    if [[ "$REVIEW_STATUS" == "failed" ]]; then
        local SCORE
        SCORE=$(grep '^score=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        echo "BLOCKED: Code review failed (score: ${SCORE:-unknown}). Fix issues, then use /commit." >&2
        trap - ERR; return 2
    fi

    # Review passed — check if still current
    local RECORDED_HASH CURRENT_HASH
    RECORDED_HASH=$(grep '^diff_hash=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)

    local _HOOK_DIR_FOR_DIFF _SNAPSHOT_ARGS
    _HOOK_DIR_FOR_DIFF="${CLAUDE_PLUGIN_ROOT:-}/hooks"
    _SNAPSHOT_ARGS=()
    # Reuse untracked snapshot if available for deterministic hashing
    local _ARTIFACTS_DIR
    _ARTIFACTS_DIR=$(get_artifacts_dir 2>/dev/null || echo "")
    if [[ -n "$_ARTIFACTS_DIR" && -f "$_ARTIFACTS_DIR/untracked-snapshot.txt" ]]; then
        _SNAPSHOT_ARGS=(--snapshot "$_ARTIFACTS_DIR/untracked-snapshot.txt")
    fi
    CURRENT_HASH=$("$_HOOK_DIR_FOR_DIFF/compute-diff-hash.sh" "${_SNAPSHOT_ARGS[@]}")

    if [[ "$RECORDED_HASH" != "$CURRENT_HASH" ]]; then
        local REVIEW_TS
        REVIEW_TS=$(grep '^timestamp=' "$REVIEW_STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
        echo "BLOCKED: Review is stale (${REVIEW_TS:-unknown}; hash ${RECORDED_HASH:0:8}→${CURRENT_HASH:0:8}). Use /commit to re-run." >&2

        # Write diagnostic dump for hash mismatch debugging
        local _DIAG_DIR _DIAG_FILE _DIAG_BREADCRUMB
        _DIAG_DIR="${_ARTIFACTS_DIR:-$(get_artifacts_dir 2>/dev/null || echo "")}"
        if [[ -n "$_DIAG_DIR" ]]; then
            mkdir -p "$_DIAG_DIR" 2>/dev/null || true
            _DIAG_FILE="$_DIAG_DIR/mismatch-diagnostics-$(date -u +%Y%m%dT%H%M%SZ).log"
            if [[ -f "$_DIAG_DIR/commit-breadcrumbs.log" ]]; then
                _DIAG_BREADCRUMB=$(cat "$_DIAG_DIR/commit-breadcrumbs.log" 2>/dev/null || echo "READ ERROR")
            else
                _DIAG_BREADCRUMB="NOT FOUND"
            fi
            {
                printf 'recorded_hash=%s\n' "$RECORDED_HASH"
                printf 'current_hash=%s\n' "$CURRENT_HASH"
                printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
                printf 'review_timestamp=%s\n' "${REVIEW_TS:-unknown}"
                printf 'git_status=%s\n' "$(git status --short 2>/dev/null | tr '\n' ',' || echo "ERROR")"
                printf 'git_diff_names=%s\n' "$(git diff --name-only 2>/dev/null | tr '\n' ',' || echo "ERROR")"
                printf 'untracked_files=%s\n' "$(git ls-files --others --exclude-standard 2>/dev/null | tr '\n' ',' || echo "ERROR")"
                printf 'breadcrumb_log=%s\n' "$(echo "$_DIAG_BREADCRUMB" | tr '\n' ',')"
            } > "$_DIAG_FILE" 2>/dev/null || true
        fi

        # Debug: log hash mismatch details when hook timing is enabled
        if [[ -f "$HOME/.claude/hook-timing-enabled" ]]; then
            {
                printf '%s\treview-gate-mismatch\trecorded=%s\tcurrent=%s\tcwd=%s\n' \
                    "$(date +%H:%M:%S)" "$RECORDED_HASH" "$CURRENT_HASH" "$(pwd)"
            } >> /tmp/hook-timing.log 2>/dev/null
        fi
        trap - ERR; return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_worktree_bash_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: block Bash commands that cd into the main repo from a worktree.
hook_worktree_bash_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
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
           echo "$CMD_AFTER_CD" | grep -qE "lockpick-workflow/scripts/(validate|ci-status|orphaned-tasks)"; then
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
        echo "  • tk commands work from any directory — drop 'cd MAIN_REPO && tk ...' prefix." >&2
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
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
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
# hook_bug_close_guard
# ---------------------------------------------------------------------------
# PreToolUse hook: enforce --reason flag on bug ticket closes.
hook_bug_close_guard() {
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
    trap 'printf "{\"ts\":\"%s\",\"hook\":\"bug-close-guard\",\"line\":%s}\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LINENO" >> "$HOOK_ERROR_LOG" 2>/dev/null; return 0' ERR

    local COMMAND
    COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
    if [[ -z "$COMMAND" ]]; then
        return 0
    fi

    # Only act on `tk close` commands
    if ! [[ "$COMMAND" =~ tk[[:space:]]+close[[:space:]]+([^[:space:]]+) ]]; then
        return 0
    fi
    local TICKET_ID="${BASH_REMATCH[1]}"

    # Find ticket file
    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    local TICKET_FILE=""
    if [[ -f "$REPO_ROOT/.tickets/${TICKET_ID}.md" ]]; then
        TICKET_FILE="$REPO_ROOT/.tickets/${TICKET_ID}.md"
    else
        TICKET_FILE=$(find "$REPO_ROOT/.tickets" -maxdepth 1 -name "*${TICKET_ID}.md" ! -name "*${TICKET_ID}.*.*" 2>/dev/null | head -1)
    fi

    if [[ -z "$TICKET_FILE" ]] || [[ ! -f "$TICKET_FILE" ]]; then
        return 0
    fi

    # Read type from frontmatter
    local TICKET_TYPE
    TICKET_TYPE=$(head -10 "$TICKET_FILE" | grep -m1 '^type:' | sed 's/^type:[[:space:]]*//' | tr -d '[:space:]')

    # Non-bug tickets are always allowed
    if [[ "$TICKET_TYPE" != "bug" ]]; then
        return 0
    fi

    # Bug ticket — require --reason flag
    if [[ "$COMMAND" != *"--reason"* ]]; then
        echo "BLOCKED [bug-close-guard]: Bug tickets require --reason flag." >&2
        echo "Add --reason=\"Fixed: <description>\" or --reason=\"Escalated to user: <findings>\"" >&2
        trap - ERR; return 2
    fi

    # Check for investigation-only language without escalation
    local INVESTIGATION_PATTERN='(Investigated|investigated|code path|works correctly|no fix needed|correct behavior|feature works correctly|no code change)'
    local ESCALATION_PATTERN='([Ee]scalat|[Uu]ser confirmed|[Uu]ser decision|[Uu]ser approved|[Bb]y design|[Ww]orks as designed)'

    if [[ "$COMMAND" =~ $INVESTIGATION_PATTERN ]] && ! [[ "$COMMAND" =~ $ESCALATION_PATTERN ]]; then
        echo "WARNING [bug-close-guard]: Reason looks like investigation findings, not a fix." >&2
        echo "Consider using --reason=\"Escalated to user: <findings>\" instead." >&2
        return 0
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
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
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
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"
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
