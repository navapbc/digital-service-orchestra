#!/usr/bin/env bash
# lockpick-workflow/hooks/lib/session-misc-functions.sh
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
#   hook_session_safety_check         — analyze hook error log and warn
#   hook_post_compact_review_check    — warn about review state after compaction
#   hook_review_stop_check            — warn about uncommitted unreviewed changes
#   hook_tool_logging_summary         — emit session tool usage summary on stop
#   hook_track_tool_errors            — track and categorize tool use errors
#   hook_plan_review_gate             — block ExitPlanMode without plan review
#   hook_worktree_isolation_guard     — block Agent calls with worktree isolation
#   hook_taskoutput_block_guard       — block TaskOutput calls with block=false
#
# Usage:
#   source lockpick-workflow/hooks/lib/session-misc-functions.sh
#   hook_inject_using_lockpick "$INPUT_JSON"

# Guard: only load once
[[ "${_SESSION_MISC_FUNCTIONS_LOADED:-}" == "1" ]] && return 0
_SESSION_MISC_FUNCTIONS_LOADED=1

# Source shared dependency library (idempotent via its own guard)
_SESSION_MISC_FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SESSION_MISC_FUNC_DIR/deps.sh"

# ---------------------------------------------------------------------------
# hook_inject_using_lockpick
# ---------------------------------------------------------------------------
# SessionStart hook: inject using-lockpick skill context into conversation
hook_inject_using_lockpick() {
    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    local PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$REPO_ROOT/lockpick-workflow}"
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
    local BUGS_DIR="$HOME/.claude/hook-error-bugs"

    if [[ ! -f "$HOOK_ERROR_LOG" ]]; then
        return 0
    fi

    check_tool jq || return 0

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
    COUNTS=$(jq -r --arg cutoff "$CUTOFF" '
        select(.ts != null and .ts >= $cutoff and .hook != null)
        | .hook
    ' "$HOOK_ERROR_LOG" 2>/dev/null | sort | uniq -c | sort -rn || echo "")

    if [[ -z "$COUNTS" ]]; then
        return 0
    fi

    mkdir -p "$BUGS_DIR" 2>/dev/null || return 0

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

            local MARKER="$BUGS_DIR/${HOOK_NAME}.bug"
            if [[ ! -f "$MARKER" ]]; then
                if command -v tk &>/dev/null; then
                    local BUG_ID
                    BUG_ID=$(tk create "Fix recurring hook errors: ${HOOK_NAME} (${COUNT} in 24h)" \
                        -t bug -p 2 \
                        -d "The hook '${HOOK_NAME}' has logged ${COUNT} errors in the last 24 hours (threshold: ${THRESHOLD}). Review ~/.claude/hook-error-log.jsonl for details. This bug was auto-created by session-safety-check." \
                        2>/dev/null || echo '')
                    if [[ -n "$BUG_ID" ]]; then
                        echo "$BUG_ID" > "$MARKER"
                    fi
                fi
            fi
        fi
    done <<< "$COUNTS"

    if [[ -n "$WARNINGS" ]]; then
        echo "# Hook Error Report"
        echo ""
        echo "The following hooks have exceeded the error threshold (${THRESHOLD}/24h):"
        echo -e "$WARNINGS"
        echo ""
        echo "Review: ~/.claude/hook-error-log.jsonl"
        echo "Bugs have been auto-created for investigation."
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
    ls $ARTIFACTS_GLOB 2>/dev/null | head -1 | grep -q . && REVIEW_DIFF_EXISTS=true

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
    local HOOK_DIR="$_SESSION_MISC_FUNC_DIR/.."

    local REPO_ROOT
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$REPO_ROOT" ]]; then
        return 0
    fi

    local CHANGED_FILES STAGED_FILES UNTRACKED_FILES
    CHANGED_FILES=$(git -C "$REPO_ROOT" diff --name-only HEAD 2>/dev/null | grep -v '^\.tickets/' || true)
    STAGED_FILES=$(git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | grep -v '^\.tickets/' || true)
    UNTRACKED_FILES=$(git -C "$REPO_ROOT" ls-files --others --exclude-standard 2>/dev/null | grep -v '^\.tickets/' || true)

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
            local _SNAPSHOT_ARGS=()
            local _ART_DIR
            _ART_DIR=$(get_artifacts_dir 2>/dev/null || echo "")
            if [[ -n "$_ART_DIR" && -f "$_ART_DIR/untracked-snapshot.txt" ]]; then
                _SNAPSHOT_ARGS=(--snapshot "$_ART_DIR/untracked-snapshot.txt")
            fi
            CURRENT_HASH=$("$HOOK_DIR/compute-diff-hash.sh" "${_SNAPSHOT_ARGS[@]}")
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
        } | sort -u | grep -v '^$' | wc -l | tr -d ' '
    )

    if [[ ! -f "$REVIEW_STATE_FILE" ]]; then
        echo "# REMINDER: Uncommitted changes not reviewed"
        echo ""
        echo "There are **${TOTAL_CHANGED} changed file(s)** that have not been code-reviewed."
        echo ""
        echo "Before completing this task, follow the Task Completion Workflow:"
        echo "  1. Run \`/review\` to review your changes"
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
        echo "Fix review issues, re-run \`/review\`, then commit."
        echo ""
        return 0
    fi

    echo "# REMINDER: Code changed since last review"
    echo ""
    echo "There are **${TOTAL_CHANGED} changed file(s)** modified after the last review."
    echo ""
    echo "Re-run \`/review\` before committing."
    echo ""
    return 0
}

# ---------------------------------------------------------------------------
# hook_tool_logging_summary
# ---------------------------------------------------------------------------
# Stop hook: output a session summary of tool usage from the JSONL tool-use log.
hook_tool_logging_summary() {
    local HOOK_DIR="$_SESSION_MISC_FUNC_DIR/.."

    check_tool jq || return 0

    if ! test -f "$HOME/.claude/tool-logging-enabled"; then
        return 0
    fi

    local SESSION_ID
    SESSION_ID=$(cat "$HOME/.claude/current-session-id" 2>/dev/null || echo "")
    if [[ -z "$SESSION_ID" ]]; then
        return 0
    fi

    local LOG_FILE="$HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
    if [[ ! -f "$LOG_FILE" ]]; then
        return 0
    fi

    local SESSION_ENTRIES
    SESSION_ENTRIES=$(jq -c --arg sid "$SESSION_ID" \
        'select(.session_id == $sid)' "$LOG_FILE" 2>/dev/null || echo "")

    if [[ -z "$SESSION_ENTRIES" ]]; then
        return 0
    fi

    local POST_ENTRIES TOTAL_CALLS
    POST_ENTRIES=$(echo "$SESSION_ENTRIES" | jq -c 'select(.hook_type == "post")' 2>/dev/null || echo "")
    TOTAL_CALLS=$(echo "$POST_ENTRIES" | grep -c '"hook_type":"post"' 2>/dev/null || echo "0")

    if [[ "$TOTAL_CALLS" -lt 10 ]]; then
        find "$HOME/.claude/logs/" -name "*.jsonl" -mtime +7 -delete 2>/dev/null || true
        return 0
    fi

    local TOOL_COUNTS
    TOOL_COUNTS=$(echo "$POST_ENTRIES" | \
        jq -rs '[.[] | .tool_name] | group_by(.) | map({tool: .[0], count: length}) | sort_by(-.count)' \
        2>/dev/null || echo "[]")

    local ALL_EPOCHS FIRST_EPOCH LAST_EPOCH
    ALL_EPOCHS=$(echo "$SESSION_ENTRIES" | jq -r '.epoch_ms' 2>/dev/null | sort -n)
    FIRST_EPOCH=$(echo "$ALL_EPOCHS" | head -1)
    LAST_EPOCH=$(echo "$ALL_EPOCHS" | tail -1)

    local DURATION_SECS=0
    if [[ -n "$FIRST_EPOCH" && -n "$LAST_EPOCH" && "$FIRST_EPOCH" -gt 0 && "$LAST_EPOCH" -gt "$FIRST_EPOCH" ]]; then
        DURATION_SECS=$(( (LAST_EPOCH - FIRST_EPOCH) / 1000 ))
    fi

    local DURATION_MIN=$(( DURATION_SECS / 60 ))
    local DURATION_SEC=$(( DURATION_SECS % 60 ))

    local SLOW_CALLS
    SLOW_CALLS=$(echo "$SESSION_ENTRIES" | jq -rs '
        . as $all |
        [ $all[] | select(.hook_type == "pre") ]  as $pres |
        [ $all[] | select(.hook_type == "post") ] as $posts |
        [ $posts[] as $p |
          [ $pres[] | select(.tool_name == $p.tool_name and .epoch_ms <= $p.epoch_ms) ] |
          sort_by(.epoch_ms) | last |
          if . then
            { tool: $p.tool_name, delta_ms: ($p.epoch_ms - .epoch_ms) }
          else
            empty
          end
        ] |
        sort_by(-.delta_ms) | .[0:5] |
        map("  - \(.tool): \(.delta_ms / 1000 | floor)s")[]
    ' 2>/dev/null || echo "")

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
    echo "$TOOL_COUNTS" | jq -r '.[] | "  - \(.tool): \(.count)"' 2>/dev/null || true
    echo ""
    if [[ -n "$SLOW_CALLS" ]]; then
        echo "## Top 5 Slowest Calls (approx)"
        echo ""
        echo "$SLOW_CALLS"
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
    local INPUT="$1"
    local HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"

    check_tool jq || return 0

    local TOOL_NAME ERROR_MSG TOOL_INPUT SESSION_ID IS_INTERRUPT
    TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || echo "")
    ERROR_MSG=$(echo "$INPUT" | jq -r '.error // empty' 2>/dev/null || echo "")
    TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")
    SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
    IS_INTERRUPT=$(echo "$INPUT" | jq -r '.is_interrupt // false' 2>/dev/null || echo "false")

    if [[ "$IS_INTERRUPT" == "true" ]]; then
        return 0
    fi

    if [[ -z "$ERROR_MSG" ]]; then
        return 0
    fi

    local COUNTER_FILE="$HOME/.claude/tool-error-counter.json"
    local THRESHOLD=50

    if [[ ! -f "$COUNTER_FILE" ]]; then
        echo '{"index":{},"errors":[],"bugs_created":{}}' > "$COUNTER_FILE"
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

    INPUT_SUMMARY="$TOOL_NAME: $(echo "$TOOL_INPUT" | jq -r 'to_entries | map(.key + "=" + (.value | tostring | .[0:80])) | join(", ")' 2>/dev/null | head -c 120)"

    local TIMESTAMP
    TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local COUNTER_DATA
    COUNTER_DATA=$(cat "$COUNTER_FILE" 2>/dev/null || echo '{"index":{},"errors":[],"bugs_created":{}}')

    if ! echo "$COUNTER_DATA" | jq -e '.errors' >/dev/null 2>&1; then
        COUNTER_DATA='{"index":{},"errors":[],"bugs_created":{}}'
    fi

    local NEXT_ID
    NEXT_ID=$(echo "$COUNTER_DATA" | jq '.errors | length + 1' 2>/dev/null || echo 1)

    COUNTER_DATA=$(echo "$COUNTER_DATA" | jq \
        --arg cat "$CATEGORY" \
        --arg tool "$TOOL_NAME" \
        --arg summary "$INPUT_SUMMARY" \
        --arg error "$ERROR_MSG" \
        --arg session "$SESSION_ID" \
        --arg ts "$TIMESTAMP" \
        --argjson id "$NEXT_ID" \
        '.errors += [{
            "id": $id,
            "timestamp": $ts,
            "category": $cat,
            "tool_name": $tool,
            "input_summary": $summary,
            "error_message": $error,
            "session_id": $session
        }]')

    COUNTER_DATA=$(echo "$COUNTER_DATA" | jq \
        --arg cat "$CATEGORY" \
        '.index[$cat] = ((.index[$cat] // 0) + 1)')

    echo "$COUNTER_DATA" > "$COUNTER_FILE"

    local CURRENT_COUNT BUG_EXISTS
    CURRENT_COUNT=$(echo "$COUNTER_DATA" | jq --arg cat "$CATEGORY" '.index[$cat] // 0')
    BUG_EXISTS=$(echo "$COUNTER_DATA" | jq -r --arg cat "$CATEGORY" '.bugs_created[$cat] // "none"')

    local NOISE_CATEGORIES="file_not_found command_exit_nonzero"
    local IS_NOISE=false
    local nc
    for nc in $NOISE_CATEGORIES; do
        if [[ "$CATEGORY" == "$nc" ]]; then IS_NOISE=true; break; fi
    done

    if [[ "$IS_NOISE" == "true" ]]; then
        return 0
    fi

    if [[ "$CURRENT_COUNT" -ge "$THRESHOLD" && "$BUG_EXISTS" == "none" ]]; then
        local BUG_ID=""
        if command -v tk &>/dev/null; then
            BUG_ID=$(tk create "Investigate recurring tool error: $CATEGORY ($CURRENT_COUNT occurrences)" \
                -t bug -p 2 \
                -d "The '$CATEGORY' tool error has been observed $CURRENT_COUNT times across sessions. Recent example: $TOOL_NAME failed with: $ERROR_MSG. Review full log: $COUNTER_FILE" \
                2>/dev/null || echo '')
        fi

        if [[ -n "$BUG_ID" ]]; then
            COUNTER_DATA=$(cat "$COUNTER_FILE")
            COUNTER_DATA=$(echo "$COUNTER_DATA" | jq \
                --arg cat "$CATEGORY" \
                --arg bug "$BUG_ID" \
                '.bugs_created[$cat] = $bug')
            echo "$COUNTER_DATA" > "$COUNTER_FILE"
        fi

        echo "Recurring tool error detected: '$CATEGORY' has occurred $CURRENT_COUNT times (threshold: $THRESHOLD)."
        if [[ -n "$BUG_ID" ]]; then
            echo "Bug created: $BUG_ID — investigate root cause before continuing."
        else
            echo "Failed to create bug automatically. Create one manually:"
            echo "  tk create \"Investigate recurring tool error: $CATEGORY\" -t bug -p 2"
        fi
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
        echo "  Invoke \`/plan-review\` with the plan content." >&2
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
        echo "Address the review findings and re-run \`/plan-review\`." >&2
        echo "" >&2
        return 2
    fi

    return 0
}

# ---------------------------------------------------------------------------
# hook_worktree_isolation_guard
# ---------------------------------------------------------------------------
# PreToolUse hook for Agent tool calls.
# Blocks any Agent dispatch that uses isolation: "worktree".
# NOTE: Uses python3 for JSON parsing (required for reliable nested JSON parsing
# of Agent tool input, which can contain complex structured data).
hook_worktree_isolation_guard() {
    local INPUT="$1"

    local TOOL_NAME
    TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || true
    if [[ "$TOOL_NAME" != "Agent" ]]; then
        return 0
    fi

    local HAS_ISOLATION
    HAS_ISOLATION=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
tool_input = data.get('tool_input', {})
isolation = tool_input.get('isolation', '')
print(isolation)
" 2>/dev/null) || true

    if [[ "$HAS_ISOLATION" == "worktree" ]]; then
        cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Worktree isolation is disabled for sub-agents. Sub-agents must share the orchestrator's working directory to access shared state (artifacts dir, review findings, diff hashes). Remove the isolation: \"worktree\" parameter and re-dispatch."
  }
}
EOF
        return 0
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
    if command -v jq &>/dev/null; then
        BLOCK_VALUE=$(echo "$INPUT" | jq -r 'if .tool_input.block == false then "false" elif .tool_input.block == true then "true" else "" end' 2>/dev/null) || BLOCK_VALUE=""
    else
        if echo "$INPUT" | grep -qE '"block"\s*:\s*false'; then
            BLOCK_VALUE="false"
        elif echo "$INPUT" | grep -qE '"block"\s*:\s*true'; then
            BLOCK_VALUE="true"
        fi
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
