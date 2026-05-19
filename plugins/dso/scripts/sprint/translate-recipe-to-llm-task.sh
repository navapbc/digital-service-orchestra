#!/usr/bin/env bash
# translate-recipe-to-llm-task.sh
# Converts a recipe task spec to a natural-language LLM sub-agent task description
# when the recipe engine is unavailable (missing-engine fallback).
#
# Usage:
#   translate-recipe-to-llm-task.sh --recipe=<name> [--intent=<description>]
#     [--param key=value ...] [--output-format=task-prompt]
#
# Environment:
#   RECIPE_REGISTRY_PATH — path to recipe-registry.yaml (injectable for test isolation)

set -uo pipefail

_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../..}"

# Default registry path (injectable via environment for test isolation)
: "${RECIPE_REGISTRY_PATH:="${_PLUGIN_ROOT}/recipes/recipe-registry.yaml"}"

# ── Argument parsing ───────────────────────────────────────────────────────────
RECIPE_NAME=""
INTENT=""
OUTPUT_FORMAT=""
PARAMS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recipe=*)
            RECIPE_NAME="${1#--recipe=}"
            shift
            ;;
        --intent=*)
            INTENT="${1#--intent=}"
            shift
            ;;
        --param)
            shift
            if [[ $# -gt 0 ]]; then
                PARAMS+=("$1")
                shift
            fi
            ;;
        --param=*)
            PARAMS+=("${1#--param=}")
            shift
            ;;
        --output-format=*)
            OUTPUT_FORMAT="${1#--output-format=}"
            shift
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Validate required arguments ────────────────────────────────────────────────
if [[ -z "$RECIPE_NAME" ]]; then
    echo "ERROR: --recipe is required" >&2
    exit 1
fi

# ── Look up capability_description from registry if --intent not provided ─────
if [[ -z "$INTENT" ]]; then
    if [[ -f "$RECIPE_REGISTRY_PATH" ]]; then
        # Use awk to parse YAML: find the recipe block by name, then extract capability_description
        # This handles simple single-level YAML list format (no python3 dependency)
        INTENT=$(awk -v recipe="$RECIPE_NAME" '
            BEGIN { in_target = 0; found = 0 }
            /^  - name:/ {
                name = $0
                sub(/^  - name: */, "", name)
                gsub(/^"|"$/, "", name)
                if (name == recipe) {
                    in_target = 1
                } else {
                    in_target = 0
                }
            }
            in_target && /^ *capability_description:/ {
                val = $0
                sub(/^ *capability_description: */, "", val)
                # Strip surrounding quotes if present
                gsub(/^"|"$/, "", val)
                gsub(/^'"'"'|'"'"'$/, "", val)
                print val
                found = 1
                exit
            }
        ' "$RECIPE_REGISTRY_PATH")
    fi

    # Fallback: recipe not found in registry
    if [[ -z "$INTENT" ]]; then
        INTENT="Perform the '${RECIPE_NAME}' transform manually"
    fi
fi

# ── Build parameters string ────────────────────────────────────────────────────
PARAMS_STR=""
if [[ ${#PARAMS[@]} -gt 0 ]]; then
    PARAMS_STR=$(printf '%s, ' "${PARAMS[@]}")
    PARAMS_STR="${PARAMS_STR%, }"
fi

# ── Build output ───────────────────────────────────────────────────────────────
if [[ "$OUTPUT_FORMAT" == "task-prompt" ]]; then
    # Structured task-prompt format with markdown sections
    echo "## What"
    echo "Implement the following mechanical transform manually: ${INTENT}"
    echo "Context: This task was planned as a recipe task (${RECIPE_NAME}) but the required engine is unavailable."
    echo ""
    echo "## Why"
    echo "The recipe engine for ${RECIPE_NAME} is not installed. Applying the transform via LLM generation."
    echo ""
    echo "## Acceptance Criteria"
    echo "- Apply the transform described above manually using LLM generation"
    if [[ -n "$PARAMS_STR" ]]; then
        echo "- Target parameters: ${PARAMS_STR}"
    fi
    echo ""
    echo "## Testing Mode"
    echo "GREEN"
else
    # Default output format
    echo "Implement the following mechanical transform manually: ${INTENT}"
    echo "Context: This task was planned as a recipe task (${RECIPE_NAME}) but the required engine is unavailable. Apply the transform using LLM generation."
    if [[ -n "$PARAMS_STR" ]]; then
        echo "Parameters: ${PARAMS_STR}"
    fi
fi
