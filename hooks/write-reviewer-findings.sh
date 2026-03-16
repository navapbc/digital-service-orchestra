#!/usr/bin/env bash
# hooks/write-reviewer-findings.sh
#
# Compatibility shim — delegates to scripts/write-reviewer-findings.sh.
#
# This file exists because orchestrators occasionally resolve the path as hooks/ instead of
# scripts/ when constructing the write-reviewer-findings.sh path from context. Both paths
# now work identically.
#
# Canonical location: scripts/write-reviewer-findings.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${CLAUDE_PLUGIN_ROOT}" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
exec "$CLAUDE_PLUGIN_ROOT/scripts/write-reviewer-findings.sh" "$@"
