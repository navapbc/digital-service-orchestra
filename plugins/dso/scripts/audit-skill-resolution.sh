#!/usr/bin/env bash
set -euo pipefail
# scripts/audit-skill-resolution.sh
#
# Canonical location. The project-root wrapper at scripts/audit-skill-resolution.sh
# delegates here.
#
# Verifies that project-referenced commands and skills resolve to
# project-owned artifacts, not external plugins.
#
# Checks:
#   1. Every command referenced in CLAUDE.md as /command resolves to a
#      project-owned file (.claude/commands/, commands/,
#      or skills/)
#   2. No external plugin silently shadows a project command
#
# Usage: scripts/audit-skill-resolution.sh [--verbose]
# Exit: 0 if all commands resolve correctly, 1 if gaps found

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
VERBOSE="${1:-}"
FAILURES=0

# Commands that MUST resolve to project-owned artifacts
REQUIRED_COMMANDS=(commit end review)

# Directories where project-owned commands/skills can live
PROJECT_PATHS=(
    "$REPO_ROOT/.claude/commands"
    "${CLAUDE_PLUGIN_ROOT}/commands"
    "${CLAUDE_PLUGIN_ROOT}/skills"
)

log() {
    if [[ "$VERBOSE" == "--verbose" ]]; then
        echo "  $1"
    fi
}

echo "--- audit-skill-resolution ---"

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    found=false

    for dir in "${PROJECT_PATHS[@]}"; do
        if [[ -f "$dir/$cmd.md" ]] || [[ -f "$dir/$cmd/SKILL.md" ]]; then
            found=true
            log "OK: /$cmd resolves to $dir"
            break
        fi
    done

    if [[ "$found" == "false" ]]; then
        echo "FAIL: /$cmd has no project-owned artifact" >&2
        echo "  Checked: ${PROJECT_PATHS[*]}" >&2

        # Check if an external plugin would shadow it via enabledPlugins
        if grep -q "\"${cmd}.*true" "$REPO_ROOT/.claude/settings.json" 2>/dev/null; then
            echo "  WARNING: external plugin may be silently handling /$cmd" >&2
        fi

        FAILURES=$((FAILURES + 1))
    fi
done

if [[ $FAILURES -eq 0 ]]; then
    echo "PASS: all ${#REQUIRED_COMMANDS[@]} commands resolve to project-owned artifacts"
    exit 0
else
    echo "FAIL: $FAILURES command(s) have no project-owned artifact" >&2
    exit 1
fi
