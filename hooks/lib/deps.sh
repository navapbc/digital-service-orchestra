#!/usr/bin/env bash
# .claude/hooks/lib/deps.sh
# Shared dependency library for hooks and scripts.
#
# Provides graceful fallbacks when tools like shasum or docker are missing.
# Source this file at the top of any hook or script that needs these utilities.
#
# Functions:
#   check_tool <name>           — silent availability check (returns 0/1)
#   parse_json_field <json> <field_expr> — pure bash JSON field extraction for Claude Code hook JSON
#   hash_stdin                  — cascading hash: shasum > sha256sum > md5 > md5sum > cksum
#   hash_file <path>            — hash a file using hash_stdin
#   try_start_docker            — start Docker Desktop (macOS) or systemd (Linux), wait ≤30s
#   try_find_python <version>   — search for Python matching <version> (e.g., "3.13")
#   get_artifacts_dir           — returns portable /tmp/workflow-plugin-<hash>/ state dir (with one-time migration from old lockpick path)
#   get_timeout_cmd             — returns 'gtimeout' (macOS coreutils) or 'timeout' (Linux), empty if neither

# Guard: only load once
[[ "${_DEPS_LOADED:-}" == "1" ]] && return 0
_DEPS_LOADED=1

# --- check_tool ---
# Usage: check_tool shasum && echo "shasum available"
#        check_tool docker || exit 0
check_tool() {
    command -v "$1" &>/dev/null
}

# --- parse_json_field ---
# Extract a field from JSON using pure bash string parsing for the known
# Claude Code hook JSON shape:
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

    # Handle the known Claude Code hook JSON shape
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
# --- get_artifacts_dir ---
# Returns the portable state directory path for this repo.
#
# New path: /tmp/workflow-plugin-<16-char-hash-of-REPO_ROOT>/
#
# Backward-compat: if old /tmp/lockpick-test-artifacts-<worktree>/ exists
# and the new path has no state files, performs a one-time atomic migration
# by copying files from the old directory to the new directory.
#
# The migration is guarded by an atomic mkdir lock to be safe under concurrent
# invocations. Old directories are left in place (OS temp cleanup handles them).
#
# Usage: ARTIFACTS_DIR=$(get_artifacts_dir)
get_artifacts_dir() {
    # Allow tests to override the artifacts directory for isolation
    if [[ -n "${WORKFLOW_PLUGIN_ARTIFACTS_DIR:-}" ]]; then
        mkdir -p "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"
        echo "$WORKFLOW_PLUGIN_ARTIFACTS_DIR"
        return 0
    fi

    local repo_root=${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}
    [[ -z "$repo_root" ]] && echo "/tmp/workflow-plugin-unknown" && return 0

    local hash_suffix
    hash_suffix=$(echo -n "$repo_root" | hash_stdin | head -c 16)
    local new_dir="/tmp/workflow-plugin-${hash_suffix}"
    mkdir -p "$new_dir"

    # One-time backward-compat migration from old lockpick path
    local worktree_name
    worktree_name=$(basename "$repo_root")
    local old_dir="/tmp/lockpick-test-artifacts-${worktree_name}"
    local lock_dir="/tmp/workflow-plugin-migration-${hash_suffix}.lock"

    if [[ -d "$old_dir" ]] && [[ -z "$(ls -A "$new_dir" 2>/dev/null)" ]]; then
        # Atomic lock using mkdir (atomic on Linux/macOS)
        if mkdir "$lock_dir" 2>/dev/null; then
            # We hold the lock — re-check new_dir is still empty before migrating
            if [[ -z "$(ls -A "$new_dir" 2>/dev/null)" ]]; then
                cp -r "$old_dir"/. "$new_dir"/ 2>/dev/null || true
            fi
            rmdir "$lock_dir" 2>/dev/null || true
        fi
        # If lock failed, another process is migrating — new_dir will be populated shortly
    fi

    echo "$new_dir"
}

# --- is_worktree ---
# Returns 0 (true) if the current working directory is inside a git worktree
# (i.e., the repo's .git entry is a FILE, not a directory). Returns 1 otherwise.
#
# In a normal repo:   $TOPLEVEL/.git is a directory  → returns 1
# In a git worktree: $TOPLEVEL/.git is a file        → returns 0
#
# Usage:
#   if is_worktree; then
#     echo "Running inside a worktree"
#   fi
is_worktree() {
    local toplevel
    toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    [[ -f "$toplevel/.git" ]]
}

# --- get_timeout_cmd ---
# Returns the GNU timeout command name for the current platform.
# macOS: gtimeout (from brew install coreutils)
# Linux: timeout (built-in)
# Returns empty string and exit 1 if neither is available.
#
# Usage:
#   TIMEOUT_CMD=$(get_timeout_cmd) || { echo "timeout not available"; exit 1; }
#   $TIMEOUT_CMD 180 make test-unit-only
get_timeout_cmd() {
    if command -v gtimeout &>/dev/null; then
        echo "gtimeout"
    elif command -v timeout &>/dev/null; then
        echo "timeout"
    else
        return 1
    fi
}

# --- parse_json_object ---
# Extract a JSON object value from a JSON string using brace-matching.
# Like jq -c '.key // {}' but in pure bash.
#
# Usage: OBJ=$(parse_json_object "$JSON" '.tool_input')
parse_json_object() {
    local json="$1"
    local expr="$2"
    local field="${expr#.}"

    # Find "field":{
    if [[ "$json" =~ \"${field}\"[[:space:]]*:[[:space:]]*\{ ]]; then
        # Get everything starting from the opening brace
        local after="${json#*\"${field}\"*:}"
        # Trim leading whitespace
        after="${after#"${after%%[![:space:]]*}"}"
        # Now balance braces, respecting strings
        local depth=0
        local i=0
        local len=${#after}
        local in_string=0
        local prev_ch=""
        while (( i < len )); do
            local ch="${after:$i:1}"
            if (( in_string )); then
                if [[ "$ch" == '"' && "$prev_ch" != "\\" ]]; then
                    in_string=0
                fi
            else
                if [[ "$ch" == '"' ]]; then
                    in_string=1
                elif [[ "$ch" == "{" ]]; then
                    (( depth++ ))
                elif [[ "$ch" == "}" ]]; then
                    (( depth-- ))
                    if (( depth == 0 )); then
                        echo "${after:0:$((i+1))}"
                        return 0
                    fi
                fi
            fi
            prev_ch="$ch"
            (( i++ ))
        done
    fi
    echo ""
}

# --- json_build ---
# Construct a compact JSON object from key=value pairs.
# Suffix :n on the key name indicates numeric (no quotes). Default is string (quoted).
#
# Usage: json_build ts="2026-01-01" count:n=42 name="Alice"
#        → {"ts":"2026-01-01","count":42,"name":"Alice"}
json_build() {
    local parts=()
    for arg in "$@"; do
        local key_part="${arg%%=*}"
        local val="${arg#*=}"
        if [[ "$key_part" == *":n" ]]; then
            # Numeric: strip :n suffix, no quotes on value
            local key="${key_part%:n}"
            parts+=("\"${key}\":${val}")
        else
            # String: escape special characters for valid JSON
            local key="$key_part"
            # Use python3 for reliable JSON string escaping
            local escaped_val
            escaped_val=$(python3 -c "import json,sys; print(json.dumps(sys.stdin.read()),end='')" <<< "$val"  2>/dev/null)
            if [[ $? -eq 0 && -n "$escaped_val" ]]; then
                # python3 wraps in quotes already, but we read with trailing newline from <<<
                # Use python to escape the exact value (without trailing newline from <<<)
                escaped_val=$(printf '%s' "$val" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()),end='')" 2>/dev/null)
                parts+=("\"${key}\":${escaped_val}")
            else
                # Fallback: basic escaping
                val="${val//\\/\\\\}"
                val="${val//\"/\\\"}"
                val="${val//$'\n'/\\n}"
                val="${val//$'\r'/\\r}"
                val="${val//$'\t'/\\t}"
                parts+=("\"${key}\":\"${val}\"")
            fi
        fi
    done
    # Join with commas
    local result="{"
    local first=1
    for part in "${parts[@]}"; do
        if (( first )); then
            result="${result}${part}"
            first=0
        else
            result="${result},${part}"
        fi
    done
    result="${result}}"
    echo "$result"
}

# --- json_mutate ---
# Run a python3 one-liner to mutate JSON data.
# The python snippet receives the parsed JSON as 'data' and should modify it in place.
#
# Usage (stdin):  echo '{"a":1}' | json_mutate 'data["b"]=2'
# Usage (file):   json_mutate 'data["b"]=2' /path/to/file.json
# Output: modified JSON on stdout
json_mutate() {
    local snippet="$1"
    local file="${2:-}"

    if ! check_tool python3; then
        echo "ERROR: json_mutate requires python3" >&2
        return 1
    fi

    local python_script
    python_script="import json,sys
data=json.load(sys.stdin)
${snippet}
print(json.dumps(data))"

    if [[ -n "$file" ]]; then
        python3 -c "$python_script" < "$file"
    else
        python3 -c "$python_script"
    fi
}

# --- json_filter_jsonl ---
# Filter lines of a JSONL file using a python3 filter expression.
# Each line is parsed as JSON and available as 'data' in the expression.
# Lines where the expression evaluates to True are output.
#
# Usage: json_filter_jsonl /path/to/file.jsonl 'data.get("age",0) > 28'
# Output: matching JSONL lines on stdout
json_filter_jsonl() {
    local file="$1"
    local filter_expr="$2"

    if ! check_tool python3; then
        echo "ERROR: json_filter_jsonl requires python3" >&2
        return 1
    fi

    # Handle empty files
    if [[ ! -s "$file" ]]; then
        return 0
    fi

    python3 -c "
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    data = json.loads(line)
    if ${filter_expr}:
        print(line)
" < "$file"
}

# --- json_summarize_input ---
# Summarize a JSON object's keys and values for logging.
# Values are truncated to 80 characters.
# Replaces: jq -r 'to_entries | map(.key + "=" + (.value | tostring | .[0:80])) | join(", ")'
#
# Usage: SUMMARY=$(json_summarize_input '{"command":"git status","file":"/tmp/x"}')
#        → command=git status, file=/tmp/x
json_summarize_input() {
    local json="$1"

    if check_tool python3; then
        python3 -c "
import json, sys
data = json.loads(sys.argv[1])
parts = []
for k, v in data.items():
    s = json.dumps(v) if v is None else str(v)
    s = s[:80]
    parts.append(k + '=' + s)
print(', '.join(parts))
" "$json" 2>/dev/null
        return
    fi

    # Bash fallback: extract key-value pairs using grep
    # This handles simple flat JSON objects
    local result=""
    local pairs
    pairs=$(echo "$json" | grep -oE '"[^"]+"\s*:\s*("[^"]*"|[0-9.]+|true|false|null)' || true)
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        local key val
        key=$(echo "$pair" | grep -oE '^"[^"]+"' | tr -d '"')
        val=$(echo "$pair" | sed 's/^"[^"]*"\s*:\s*//' | tr -d '"')
        val="${val:0:80}"
        if [[ -n "$result" ]]; then
            result="${result}, "
        fi
        result="${result}${key}=${val}"
    done <<< "$pairs"
    echo "$result"
}

# --- EXCLUDE_PATTERNS ---
# Array of path patterns that hooks should skip.
# Entries are substring patterns — a file path matching any entry is excluded.
#
# .tickets/ — ticket files managed by the tk CLI; hooks should not interfere.
#
# Usage:
#   for pat in "${EXCLUDE_PATTERNS[@]}"; do
#     if [[ "$file_path" == *"$pat"* ]]; then skip; fi
#   done
EXCLUDE_PATTERNS=(
    ".tickets/"
    ".git/"
)

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
