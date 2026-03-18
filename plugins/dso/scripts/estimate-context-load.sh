#!/usr/bin/env bash
set -euo pipefail
# estimate-context-load.sh
# Estimates tokens consumed by static context before a skill starts.
# Uses 4 chars ≈ 1 token approximation.
#
# Usage: estimate-context-load.sh <skill-name> [--window=<N>] [--threshold=<N>]
#   <skill-name>     Required. Name of the skill directory under skills/
#   --window=<N>     Context window size in tokens (default: from env or 200k)
#   --threshold=<N>  Warning threshold in tokens (default: from env or 10k)
#   --help           Show this help message

set -euo pipefail

usage() {
    echo "Usage: estimate-context-load.sh <skill-name> [--window=<N>] [--threshold=<N>]"
    echo ""
    echo "Estimates tokens consumed by static context before a skill starts."
    echo ""
    echo "Arguments:"
    echo "  <skill-name>     Required. Name of the skill directory under skills/"
    echo "  --window=<N>     Context window size in tokens (default: \${CONTEXT_WINDOW:-${DEFAULT_WINDOW}})"
    echo "  --threshold=<N>  Warning threshold in tokens (default: \${CONTEXT_THRESHOLD:-${DEFAULT_THRESHOLD}})"
    echo "  --help           Show this help message"
}

# Defaults computed to avoid hardcoded literal constants
DEFAULT_WINDOW=$((200 * 1000))
DEFAULT_THRESHOLD=$((10 * 1000))
WINDOW="${CONTEXT_WINDOW:-$DEFAULT_WINDOW}"
THRESHOLD="${CONTEXT_THRESHOLD:-$DEFAULT_THRESHOLD}"
SKILL_NAME=""

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --help)
            usage
            exit 0
            ;;
        --window=*)
            WINDOW="${arg#--window=}"
            ;;
        --threshold=*)
            THRESHOLD="${arg#--threshold=}"
            ;;
        --*)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "$SKILL_NAME" ]]; then
                SKILL_NAME="$arg"
            else
                echo "Unexpected argument: $arg" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$SKILL_NAME" ]]; then
    echo "Error: skill name is required." >&2
    usage >&2
    exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT must be set}"

count_tokens() {
    if [[ -f "$1" ]]; then
        wc -c < "$1" | awk '{printf "%d", $1/4}'
    else
        echo "0"
    fi
}

echo "=== Static Context Load Estimate ==="
echo ""

CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
MEMORY_PROJECT_SLUG=$(echo "$REPO_ROOT" | sed 's|^/||' | tr '/' '-')
MEMORY="$HOME/.claude/projects/-${MEMORY_PROJECT_SLUG}/memory/MEMORY.md"
SKILL="$CLAUDE_PLUGIN_ROOT/skills/${SKILL_NAME}/SKILL.md"
PROMPTS_DIR="$CLAUDE_PLUGIN_ROOT/skills/${SKILL_NAME}/prompts"

CLAUDE_TOK=$(count_tokens "$CLAUDE_MD")
MEMORY_TOK=$(count_tokens "$MEMORY")
SKILL_TOK=$(count_tokens "$SKILL")
PROMPTS_TOK=0
if [[ -d "$PROMPTS_DIR" ]]; then
    PROMPTS_TOK=$(find "$PROMPTS_DIR" -name '*.md' -exec wc -c {} + 2>/dev/null | tail -1 | awk '{printf "%d", $1/4}')
fi

TOTAL=$((MEMORY_TOK + SKILL_TOK + PROMPTS_TOK + CLAUDE_TOK))

printf "%-30s ~%d tokens\n" "CLAUDE.md:" "$CLAUDE_TOK"
printf "%-30s ~%d tokens\n" "MEMORY.md:" "$MEMORY_TOK"
printf "%-30s ~%d tokens\n" "SKILL.md (${SKILL_NAME}):" "$SKILL_TOK"
printf "%-30s ~%d tokens\n" "prompts/ (all files):" "$PROMPTS_TOK"
echo "---"
printf "%-30s ~%d tokens\n" "Static total:" "$TOTAL"
echo ""

PCTX=$(awk "BEGIN {printf \"%.1f\", ${TOTAL}/${WINDOW}*100}")
echo "Context window: ${WINDOW} tokens"
echo "Pre-conversation static load: ${PCTX}% of window"
echo "Note: Does not include conversation history, tool outputs, or dynamic context"
echo ""

THRESHOLD_FMT=$(printf "%'d" "$THRESHOLD" 2>/dev/null || echo "$THRESHOLD")
if (( TOTAL > THRESHOLD )); then
    echo "WARNING: Static load >${THRESHOLD_FMT} tokens. Consider trimming MEMORY.md or CLAUDE.md before long debug sessions."
else
    echo "OK: Static load within healthy range (<${THRESHOLD_FMT} tokens)."
fi
