#!/usr/bin/env bash
# merge-to-main.sh — dispatcher: routes to merge-to-main-{strategy}.sh
# Reads merge.strategy from .claude/dso-config.conf (default: direct).
# Valid values: direct | pr
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

# -- Read merge.strategy from config --
_config_file="$REPO_ROOT/.claude/dso-config.conf"
MERGE_STRATEGY="direct"  # default
if [[ -f "$_config_file" ]]; then
    _read="$(grep '^merge\.strategy=' "$_config_file" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]' || true)"
    if [[ -n "$_read" ]]; then
        MERGE_STRATEGY="$_read"
    else
        echo "NOTE: merge.strategy not set in dso-config.conf, defaulting to direct. Add merge.strategy=direct to suppress this message." >&2
    fi
fi

# -- Validate strategy value --
case "$MERGE_STRATEGY" in
    direct|pr)
        ;;
    *)
        echo "ERROR: Unknown merge.strategy '$MERGE_STRATEGY'. Valid values: direct, pr" >&2
        exit 1
        ;;
esac

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
            echo "ERROR: --resume cross-strategy mismatch: state file was written with merge.strategy='$_stored_strategy', but current config has merge.strategy='$MERGE_STRATEGY'. Delete the state file or switch to the matching strategy." >&2
            exit 1
        elif [[ -z "$_stored_strategy" ]] && [[ "$MERGE_STRATEGY" != "direct" ]]; then
            echo "ERROR: --resume cross-strategy mismatch: state file has no merge_strategy (was direct mode), but current config has merge.strategy='$MERGE_STRATEGY'. Delete the state file or set merge.strategy=direct." >&2
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
