#!/usr/bin/env bash
set -uo pipefail
# detect-enforcement-artifacts.sh
# Detects whether /dso:architect-foundation has already produced enforcement
# artifacts in this project. Emits JSON describing what exists so the skill
# can branch into re-run (append-only) mode instead of first-run mode.
#
# Usage: detect-enforcement-artifacts.sh [--project-dir <dir>]
#
# Exit codes: 0 always (detection, not validation)

PROJECT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --project-dir) PROJECT_DIR="${2:-}"; shift 2 ;;
        --project-dir=*) PROJECT_DIR="${1#--project-dir=}"; shift ;;
        -h|--help) echo "Usage: detect-enforcement-artifacts.sh [--project-dir <dir>]"; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PROJECT_DIR" ]]; then
    PROJECT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

_exists() { [[ -e "$1" ]] && echo "true" || echo "false"; }

ARCH_MD="$PROJECT_DIR/ARCH_ENFORCEMENT.md"
ADR_DIR="$PROJECT_DIR/docs/adr"
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"

CLAUDE_SECTION="false"
if [[ -f "$CLAUDE_MD" ]] && grep -q "^## Architectural Invariants" "$CLAUDE_MD" 2>/dev/null; then
    CLAUDE_SECTION="true"
fi

ADR_COUNT=0
if [[ -d "$ADR_DIR" ]]; then
    ADR_COUNT=$(find "$ADR_DIR" -maxdepth 1 -name "*.md" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

printf '{\n'
printf '  "project_dir": "%s",\n' "$PROJECT_DIR"
printf '  "arch_enforcement_md": %s,\n' "$(_exists "$ARCH_MD")"
printf '  "adr_dir": %s,\n' "$(_exists "$ADR_DIR")"
printf '  "adr_count": %s,\n' "$ADR_COUNT"
printf '  "claude_md_invariants_section": %s\n' "$CLAUDE_SECTION"
printf '}\n'
