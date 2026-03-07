#!/usr/bin/env bash
# lockpick-workflow/scripts/lib/require-tk.sh
# Shared helper for tk CLI availability checking.
#
# Usage: source this file and call require_tk before using tk commands.
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/require-tk.sh"
#   require_tk
#
# Respects TK env var for custom tk path. Exits 1 with clear error if tk is not found.

require_tk() {
    local tk_cmd="${TK:-tk}"

    # Check if the specified tk command exists and is executable
    if command -v "$tk_cmd" >/dev/null 2>&1; then
        return 0
    fi

    # If TK is an absolute/relative path, check if the file exists and is executable
    if [[ "$tk_cmd" == */* ]] && [[ -x "$tk_cmd" ]]; then
        return 0
    fi

    # If TK was explicitly set but doesn't exist, report that
    if [[ -n "${TK:-}" ]]; then
        echo "lockpick-workflow: tk CLI is required but not found at '$TK'. Install tk or set TK= to its path." >&2
    else
        echo "lockpick-workflow: tk CLI is required but not found. Install tk or set TK= to its path." >&2
    fi
    exit 1
}
