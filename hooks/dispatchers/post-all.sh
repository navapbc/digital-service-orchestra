#!/usr/bin/env bash
# lockpick-workflow/hooks/dispatchers/post-all.sh
# PostToolUse catch-all dispatcher: placeholder after tool-logging removal.
# No catch-all post-hooks remain. Kept for future hooks.
#
# PostToolUse hooks always exit 0 (non-blocking).
# Always emits at least '{}' on stdout per Claude Code bug #10463 workaround.

# DEFENSE-IN-DEPTH: Guarantee exit 0 and non-empty stdout on any unexpected failure.
_HOOK_HAS_OUTPUT=""
trap 'if [[ -z "$_HOOK_HAS_OUTPUT" ]]; then printf "{}"; fi; exit 0' EXIT
trap 'exit 0' ERR

# Resolve dispatcher directory (CLAUDE_PLUGIN_ROOT if set, else relative)
if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

HOOKS_LIB_DIR="$CLAUDE_PLUGIN_ROOT/hooks/lib"

# Cache REPO_ROOT once for all hooks (avoids redundant git rev-parse calls)
export REPO_ROOT
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# Source the dispatcher framework (provides run_hooks)
source "$HOOKS_LIB_DIR/dispatcher.sh"

_post_all_dispatch() {
    # Read hook input from stdin
    local INPUT
    INPUT=$(cat)

    # No catch-all post-hooks remain. Kept for future hooks.
}

# Only execute dispatch logic when run as a script (not sourced).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _post_all_dispatch
    exit 0
fi
