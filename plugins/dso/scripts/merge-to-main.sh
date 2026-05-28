#!/usr/bin/env bash
# merge-to-main.sh — dispatcher: routes to merge-to-main-{strategy}.sh
# Reads dso.workflow from .claude/dso-config.conf to determine merge strategy.
# dso.workflow=ci-pr → MERGE_STRATEGY=pr; otherwise → MERGE_STRATEGY=direct
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# -- Help pass-through (before any validation) --
for _arg in "$@"; do
    case "$_arg" in
        --help|-h)
            exec "${_SCRIPT_DIR}/merge-to-main-direct.sh" --help
            ;;
    esac
done

# -- Resolve REPO_ROOT --
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"

# -- F-05: invalidate default-branch cache at the start of each merge-to-main run --
# resolve-default-branch.sh caches its resolved value in .git/dso-default-branch
# to avoid re-running the precedence chain inside a single merge run. The cache
# is invalidated here so each new merge-to-main invocation re-runs the resolver
# (default branch could be renamed upstream between runs).
_GIT_DIR_FOR_CACHE="$(git -C "$REPO_ROOT" rev-parse --git-dir 2>/dev/null || true)"
if [[ -n "$_GIT_DIR_FOR_CACHE" ]]; then
    # Use absolute path: rev-parse --git-dir may return a relative path
    case "$_GIT_DIR_FOR_CACHE" in
        /*) ;;
        *) _GIT_DIR_FOR_CACHE="$REPO_ROOT/$_GIT_DIR_FOR_CACHE" ;;
    esac
    rm -f "$_GIT_DIR_FOR_CACHE/dso-default-branch" 2>/dev/null || true
fi
unset _GIT_DIR_FOR_CACHE

# -- Validate CLAUDE_PLUGIN_ROOT --
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    _cfg="$REPO_ROOT/.claude/dso-config.conf"
    if [[ -f "$_cfg" ]]; then
        CLAUDE_PLUGIN_ROOT="$(grep '^dso\.plugin_root=' "$_cfg" 2>/dev/null | cut -d= -f2- || true)"
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/$CLAUDE_PLUGIN_ROOT"
    fi
fi
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]] || [[ ! -d "${CLAUDE_PLUGIN_ROOT}" ]]; then
    echo "ERROR: CLAUDE_PLUGIN_ROOT is not set or does not exist: '${CLAUDE_PLUGIN_ROOT:-}'" >&2
    exit 1
fi
# Export so the execed strategy script (which enforces ${CLAUDE_PLUGIN_ROOT:?...})
# inherits the value when we derived it from config rather than the environment.
export CLAUDE_PLUGIN_ROOT

# -- Read dso.workflow to determine merge strategy --
_WORKFLOW=$(WORKFLOW_CONFIG_FILE="$REPO_ROOT/.claude/dso-config.conf" \
    bash "$_SCRIPT_DIR/read-config.sh" dso.workflow 2>/dev/null || echo "local")
if [[ "$_WORKFLOW" == "ci-pr" ]]; then
    MERGE_STRATEGY="pr"
else
    MERGE_STRATEGY="direct"
fi

# -- --resume cross-strategy check --
_resume=false
for _arg in "$@"; do
    [[ "$_arg" == "--resume" ]] && _resume=true && break
done

if [[ "$_resume" == "true" ]]; then
    # Resolve current branch and target the per-branch state file directly.
    # Selecting by mtime across `/tmp/merge-to-main-state-*.json` would let a
    # neighboring worktree's state file (different branch, different strategy)
    # produce a false-positive cross-strategy rejection here.
    _branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)
    _branch_safe="${_branch//\//-}"
    _state_file=""
    if [[ -n "$_branch_safe" ]]; then
        _candidate="/tmp/merge-to-main-state-${_branch_safe}.json"
        [[ -f "$_candidate" ]] && _state_file="$_candidate"
    fi

    if [[ -n "$_state_file" ]]; then
        _stored_strategy="$(_DSO_SF="$_state_file" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['_DSO_SF']))
    print(d.get('merge_strategy', ''))
except Exception:
    print('')
" 2>/dev/null)"

        # Cross-strategy rejection logic:
        # - If stored strategy is present and differs from current → reject
        # - If stored strategy is absent (legacy file) and current is pr → reject (legacy = was direct)
        # - If stored strategy is absent and current is direct → proceed (same strategy)
        if [[ -n "$_stored_strategy" ]] && [[ "$_stored_strategy" != "$MERGE_STRATEGY" ]]; then
            echo "ERROR: --resume cross-strategy mismatch: state file was written with strategy='$_stored_strategy', but current config resolves to strategy='$MERGE_STRATEGY'. Delete the state file or update dso.workflow to match." >&2
            exit 1
        elif [[ -z "$_stored_strategy" ]] && [[ "$MERGE_STRATEGY" != "direct" ]]; then
            echo "ERROR: --resume cross-strategy mismatch: state file has no merge_strategy (was direct mode), but current config resolves to strategy='$MERGE_STRATEGY'. Delete the state file or set dso.workflow=local." >&2
            exit 1
        fi
    fi
fi

# -- Export MERGE_STRATEGY so strategy scripts and _state_init can read it --
export MERGE_STRATEGY

# -- Push session branch if running from a session worktree --
# CI's per-story review job fetches origin/${SPRINT_SESSION_ID}; if the
# session branch was never pushed (e.g., sprint resumed after compaction and
# the Pre-Dispatch push was skipped), CI fails with "couldn't find remote ref".
# This push is idempotent and non-fatal — it is a safety-net, not the sole push.
if [[ -f "$REPO_ROOT/.git" ]]; then
    _session_branch=$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)
    if [[ -n "$_session_branch" ]]; then
        git -C "$REPO_ROOT" push -u origin "$_session_branch" --quiet 2>/dev/null || true
    fi
fi

# -- Exec strategy script --
# Strategy script resolution order:
#   1. Any directory already on PATH (allows test stubs to shadow the real script)
#   2. _SCRIPT_DIR (production: sibling script in the same directory)
# Append _SCRIPT_DIR to PATH so it acts as a fallback, and use PATH-based exec.
export PATH="${PATH}:${_SCRIPT_DIR}"
exec "merge-to-main-${MERGE_STRATEGY}.sh" "$@"
