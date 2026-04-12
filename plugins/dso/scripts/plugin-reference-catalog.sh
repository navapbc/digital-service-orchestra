#!/usr/bin/env bash
set -uo pipefail
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
_PLUGIN_GIT_PATH="${_PLUGIN_ROOT#$(cd "$_PLUGIN_ROOT" && git rev-parse --show-toplevel)/}"
# scripts/plugin-reference-catalog.sh
# Scans  directories for references to 7 external plugins.
#
# Output: one line per reference found:
#   <file>:<line-number>:<plugin-name>:<context-snippet>
#
# Followed by a summary section with per-plugin counts.
#
# Usage: bash scripts/plugin-reference-catalog.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

# The 7 external plugins to catalog
PLUGINS=(
    commit-commands
    claude-md-management
    code-simplifier
    backend-api-security
    debugging-toolkit
    unit-testing
    error-debugging
)

# Directories to scan (relative to REPO_ROOT)
# Plugin files live under ${CLAUDE_PLUGIN_ROOT}/ after restructure
SCAN_DIRS=(
    "${_PLUGIN_GIT_PATH}/skills"
    "${_PLUGIN_GIT_PATH}/docs"
    "${_PLUGIN_GIT_PATH}/hooks"
    "${_PLUGIN_GIT_PATH}/scripts"
)

# Files to exclude (the catalog script itself and its test)
EXCLUDE_PATTERN="plugin-reference-catalog"

# Associative array for per-plugin counts
declare -A plugin_counts
for plugin in "${PLUGINS[@]}"; do
    plugin_counts[$plugin]=0
done

total_refs=0
declare -A files_seen

# Build the list of directories that actually exist
existing_dirs=()
for dir in "${SCAN_DIRS[@]}"; do
    full_path="$REPO_ROOT/$dir"
    if [ -d "$full_path" ]; then
        existing_dirs+=("$full_path")
    fi
done

if [ ${#existing_dirs[@]} -eq 0 ]; then
    echo "No scan directories found." >&2
    exit 1
fi

# Scan for each plugin
for plugin in "${PLUGINS[@]}"; do
    while IFS= read -r match; do
        [ -z "$match" ] && continue

        # Extract file path and line number
        # grep -rn output: /path/to/file:123:matched line content
        file_path="${match%%:*}"
        rest="${match#*:}"
        line_num="${rest%%:*}"
        context="${rest#*:}"

        # Skip self-references
        if echo "$file_path" | grep -q "$EXCLUDE_PATTERN"; then
            continue
        fi

        # Make path relative to REPO_ROOT
        rel_path="${file_path#"$REPO_ROOT"/}"

        # Trim context to reasonable length
        context="$(echo "$context" | sed 's/^[[:space:]]*//' | cut -c1-120)"

        echo "${rel_path}:${line_num}:${plugin}:${context}"

        plugin_counts[$plugin]=$(( ${plugin_counts[$plugin]} + 1 ))
        total_refs=$(( total_refs + 1 ))
        files_seen[$rel_path]=1
    done < <(grep -rn --include='*.md' --include='*.sh' --include='*.py' --include='*.yaml' --include='*.yml' --include='*.toml' --include='*.conf' "$plugin" "${existing_dirs[@]}" 2>/dev/null)
done

# Summary section
total_files=${#files_seen[@]}

echo ""
echo "--- Summary ---"
for plugin in "${PLUGINS[@]}"; do
    echo "${plugin}: ${plugin_counts[$plugin]} references"
done
echo "Total: ${total_refs} references across ${total_files} files"
