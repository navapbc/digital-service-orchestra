#!/usr/bin/env bash
# .claude/hooks/lib/deps.sh
# Shared dependency library for hooks and scripts.
#
# Provides graceful fallbacks when tools like jq, shasum, or docker are missing.
# Source this file at the top of any hook or script that needs these utilities.
#
# Functions:
#   check_tool <name>           — silent availability check (returns 0/1)
#   parse_json_field <json> <jq_expr> — jq with bash fallback for Claude Code hook JSON
#   hash_stdin                  — cascading hash: shasum > sha256sum > md5 > md5sum > cksum
#   hash_file <path>            — hash a file using hash_stdin
#   try_start_docker            — start Docker Desktop (macOS) or systemd (Linux), wait ≤30s
#   try_find_python <version>   — search for Python matching <version> (e.g., "3.13")

# Guard: only load once
[[ "${_DEPS_LOADED:-}" == "1" ]] && return 0
_DEPS_LOADED=1

# --- check_tool ---
# Usage: check_tool jq && echo "jq available"
#        check_tool jq || exit 0
check_tool() {
    command -v "$1" &>/dev/null
}

# --- parse_json_field ---
# Extract a field from JSON. Uses jq when available, falls back to bash string
# parsing for the known Claude Code hook JSON shape:
#   {"tool_name":"...","tool_input":{"command":"...","file_path":"..."}}
#
# Supports:
#   .tool_name              — top-level string field
#   .tool_input.command     — nested field under tool_input
#   .tool_input.file_path   — nested field under tool_input
#   .error                  — top-level string field
#   .session_id             — top-level string field
#   .is_interrupt           — top-level string field
#
# Returns empty string on failure (never errors out).
#
# Usage: TOOL_NAME=$(parse_json_field "$INPUT" '.tool_name')
#        COMMAND=$(parse_json_field "$INPUT" '.tool_input.command')
parse_json_field() {
    local json="$1"
    local expr="$2"

    # Try jq first
    if check_tool jq; then
        local result
        result=$(echo "$json" | jq -r "${expr} // empty" 2>/dev/null) || true
        echo "$result"
        return 0
    fi

    # Bash fallback: handle the known Claude Code hook JSON shape
    # Strip leading dot from expression
    local field="${expr#.}"

    if [[ "$field" == *"."* ]]; then
        # Nested field: e.g., "tool_input.command"
        local parent="${field%%.*}"
        local child="${field#*.}"

        # Extract the parent object's value (everything between the outermost braces
        # after the parent key). This is a simplified parser for the known JSON shape.
        local parent_val=""
        # Match "parent":{...} — find the opening brace after the key, then balance braces
        if [[ "$json" =~ \"${parent}\"[[:space:]]*:[[:space:]]*\{ ]]; then
            # Get everything after the match
            local after="${json#*\"${parent}\"*:\{}"
            # Now count braces to find the matching close
            local depth=1
            local i=0
            local len=${#after}
            while (( i < len && depth > 0 )); do
                local ch="${after:$i:1}"
                [[ "$ch" == "{" ]] && (( depth++ ))
                [[ "$ch" == "}" ]] && (( depth-- ))
                (( i++ ))
            done
            parent_val="{${after:0:$i}"
        fi

        if [[ -z "$parent_val" ]]; then
            echo ""
            return 0
        fi

        # Now extract the child field from the parent object
        _deps_extract_string_field "$parent_val" "$child"
    else
        # Top-level field
        _deps_extract_string_field "$json" "$field"
    fi
}

# Internal: extract a simple string field value from JSON
# Handles: "key":"value" and "key": "value" with possible escapes
_deps_extract_string_field() {
    local json="$1"
    local key="$2"

    # Match "key" : "value" — capture the value (handle escaped quotes)
    # Use a simple approach: find the key, then extract between the next pair of quotes
    if [[ "$json" =~ \"${key}\"[[:space:]]*:[[:space:]]*\" ]]; then
        local after="${json#*\"${key}\"*:*\"}"
        # Read until unescaped quote (handle \\" correctly — count consecutive backslashes)
        local result=""
        local i=0
        local len=${#after}
        while (( i < len )); do
            local ch="${after:$i:1}"
            if [[ "$ch" == '"' ]]; then
                # Count consecutive backslashes before this quote
                local bs_count=0
                local j=$((i - 1))
                while (( j >= 0 )) && [[ "${after:$j:1}" == "\\" ]]; do
                    (( bs_count++ ))
                    (( j-- ))
                done
                # Even number of backslashes = quote is NOT escaped (they escape each other)
                if (( bs_count % 2 == 0 )); then
                    break
                else
                    result="${result}${ch}"
                fi
            else
                result="${result}${ch}"
            fi
            (( i++ ))
        done
        echo "$result"
    elif [[ "$json" =~ \"${key}\"[[:space:]]*:[[:space:]]*([0-9.]+|true|false|null) ]]; then
        # Non-string value (number, boolean, null)
        local after="${json#*\"${key}\"*:}"
        after="${after#"${after%%[![:space:]]*}"}"  # trim leading whitespace
        # Read until comma, brace, or bracket
        local result=""
        local i=0
        local len=${#after}
        while (( i < len )); do
            local ch="${after:$i:1}"
            [[ "$ch" == "," || "$ch" == "}" || "$ch" == "]" ]] && break
            result="${result}${ch}"
            (( i++ ))
        done
        # Trim trailing whitespace
        result="${result%"${result##*[![:space:]]}"}"
        echo "$result"
    else
        echo ""
    fi
}

# --- hash_stdin ---
# Read stdin and produce a hex hash string. Uses the best available tool:
#   shasum -a 256 > sha256sum > md5 > md5sum > cksum
#
# Usage: echo "data" | hash_stdin
#        HASH=$(cat file | hash_stdin)
hash_stdin() {
    if check_tool shasum; then
        shasum -a 256 | awk '{print $1}'
    elif check_tool sha256sum; then
        sha256sum | awk '{print $1}'
    elif check_tool md5; then
        md5
    elif check_tool md5sum; then
        md5sum | awk '{print $1}'
    elif check_tool cksum; then
        cksum | awk '{print $1}'
    else
        # Last resort: just read and discard, output a placeholder
        cat >/dev/null
        echo "no-hash-tool-available"
    fi
}

# --- hash_file ---
# Hash a file's contents using hash_stdin.
#
# Usage: HASH=$(hash_file /path/to/file)
hash_file() {
    local filepath="$1"
    hash_stdin < "$filepath"
}

# --- try_start_docker ---
# Attempt to start Docker if the CLI exists but the daemon isn't running.
# macOS: opens Docker Desktop. Linux: tries systemctl.
# Waits up to 30 seconds for the daemon to respond.
#
# Returns: 0 if docker is responding, 1 if start failed or timed out.
try_start_docker() {
    # Already running?
    if docker info &>/dev/null 2>&1; then
        return 0
    fi

    # No docker CLI at all
    if ! check_tool docker; then
        return 1
    fi

    # Attempt to start
    if [[ "$(uname)" == "Darwin" ]]; then
        # macOS: open Docker Desktop
        open -a "Docker Desktop" 2>/dev/null || open -a "Docker" 2>/dev/null || return 1
    else
        # Linux: try systemd (use sudo -n to avoid blocking on password prompt)
        if check_tool systemctl; then
            sudo -n systemctl start docker 2>/dev/null || return 1
        else
            return 1
        fi
    fi

    # Wait up to 30 seconds
    local waited=0
    while (( waited < 30 )); do
        if docker info &>/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        (( waited += 2 ))
    done

    return 1
}

# --- try_find_python ---
# Search common locations for a Python binary matching the requested version.
# Returns the full path on stdout, or empty string if not found.
#
# Usage: PYTHON=$(try_find_python 3.13)
#        [[ -n "$PYTHON" ]] && echo "Found: $PYTHON"
try_find_python() {
    local version="$1"
    local major="${version%%.*}"
    local minor="${version#*.}"

    # Candidate paths to check (in priority order)
    local candidates=(
        "/opt/homebrew/opt/python@${version}/bin/python${version}"
        "/opt/homebrew/opt/python@${version}/bin/python${major}"
        "/opt/homebrew/bin/python${version}"
        "/usr/local/opt/python@${version}/bin/python${version}"
        "/usr/local/bin/python${version}"
    )

    # pyenv versions
    if check_tool pyenv; then
        local pyenv_root
        pyenv_root=$(pyenv root 2>/dev/null || echo "$HOME/.pyenv")
        # Find installed versions matching the requested version
        local pyenv_versions
        pyenv_versions=$(ls -d "${pyenv_root}/versions/${version}"* 2>/dev/null || true)
        for pv in $pyenv_versions; do
            candidates+=("${pv}/bin/python${major}")
            candidates+=("${pv}/bin/python${version}")
        done
    fi

    # System paths
    candidates+=(
        "/usr/bin/python${version}"
        "/usr/bin/python${major}"
    )

    # Check each candidate
    for candidate in "${candidates[@]}"; do
        if [[ -x "$candidate" ]]; then
            # Verify version actually matches
            local actual_version
            actual_version=$("$candidate" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
            if [[ "$actual_version" == "${major}.${minor}" ]]; then
                echo "$candidate"
                return 0
            fi
        fi
    done

    # Fallback: check PATH for python3.X or pythonX.Y
    local path_python
    path_python=$(command -v "python${version}" 2>/dev/null || true)
    if [[ -n "$path_python" ]]; then
        local actual_version
        actual_version=$("$path_python" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [[ "$actual_version" == "${major}.${minor}" ]]; then
            echo "$path_python"
            return 0
        fi
    fi

    echo ""
    return 1
}
