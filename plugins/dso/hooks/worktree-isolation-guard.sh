#!/usr/bin/env bash
# hooks/worktree-isolation-guard.sh
# PreToolUse hook for Agent tool calls.
# Blocks any Agent dispatch that uses isolation: "worktree".
#
# Worktree isolation breaks shared state (artifacts dir, review findings,
# diff hashes) because isolated sub-agents resolve to a different REPO_ROOT.
# This guard categorically prevents that failure mode.
#
# Uses JSON-based permissionDecision (not exit code 2) because exit code 2
# does not reliably block Agent tool calls (claude-code#26923).

set -euo pipefail

# Read hook input from stdin
INPUT=$(cat)

# Extract tool_name — exit early if not Agent
TOOL_NAME=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null) || true
if [[ "$TOOL_NAME" != "Agent" ]]; then
    exit 0
fi

# Check for isolation key in tool_input
HAS_ISOLATION=$(echo "$INPUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
tool_input = data.get('tool_input', {})
isolation = tool_input.get('isolation', '')
print(isolation)
" 2>/dev/null) || true

if [[ "$HAS_ISOLATION" == "worktree" ]]; then
    # When worktree.isolation_enabled is not explicitly true, allow all worktree
    # dispatches. The guard only enforces auth markers when orchestrator-managed
    # isolation is active. Main-session dispatches are always allowed in this mode.
    # Env var override: WORKTREE_ISOLATION_ENABLED (for testing and orchestrator use)
    _ISOLATION_ENABLED="${WORKTREE_ISOLATION_ENABLED:-}"
    if [[ -z "$_ISOLATION_ENABLED" ]]; then
        _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
        if [[ -n "$_REPO_ROOT" ]] && [[ -x "$_REPO_ROOT/.claude/scripts/dso" ]]; then
            _ISOLATION_ENABLED=$("$_REPO_ROOT/.claude/scripts/dso" read-config worktree.isolation_enabled 2>/dev/null || true)
        fi
    fi
    if [[ "$_ISOLATION_ENABLED" != "true" ]]; then
        # Isolation not enabled — allow all worktree dispatches (main session context)
        exit 0
    fi

    # Check for auth marker files before denying.
    # Format: /tmp/worktree-isolation-authorized-* containing a PID.
    _AUTHORIZED=0
    for _MARKER in /tmp/worktree-isolation-authorized-*; do
        # Skip glob literal when no files match
        [[ -f "$_MARKER" ]] || continue
        _MARKER_PID=$(cat "$_MARKER" 2>/dev/null) || continue
        if kill -0 "$_MARKER_PID" 2>/dev/null; then
            # PID is alive — this is a valid authorization
            _AUTHORIZED=1
        else
            # PID is dead — stale marker; clean it up
            rm -f "$_MARKER" 2>/dev/null || true
        fi
    done

    if [[ "$_AUTHORIZED" -eq 1 ]]; then
        # Valid auth marker present — allow
        exit 0
    fi

    cat <<'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Worktree isolation is disabled for sub-agents. Sub-agents must share the orchestrator's working directory to access shared state (artifacts dir, review findings, diff hashes). Remove the isolation: \"worktree\" parameter and re-dispatch."
  }
}
EOF
    exit 0
fi

# No isolation requested — allow
exit 0
